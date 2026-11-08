# 保留旧访问密钥的服务端签名

当前完整服务端与 API 同步扩展在 [CNB 仓库](https://cnb.cool/nnu/rustdesk-server) 维护，验证在本地执行，容器在 CNB 构建。该仓库的部署说明及镜像摘要为当前依据。custom-id.patch 是针对 upstream.json 固定上游的完整合并补丁，包含旧版签名、公钥别名、签名改号及持久化 API 通知队列，不应叠加另外两个历史补丁。API 接收端源码见 CNB 的 services/rustdesk-api。下文为早期独立签名补丁的历史说明。

生产旧配置把访问口令放在 `-k` 中，没有 Ed25519 签名密钥，客户端因此正确显示非安全连接。本补丁保留原访问口令、ID 数据库、端口和中继，只为 hbbs 增加独立的设备身份签名。

只有显式设置 `NNU_SIGN_PEERS_WITH_LEGACY_KEY=Y` 才启用补丁。新客户端使用 `src/nnu.rs` 中固定的服务器公钥验证身份；它仍用原口令连接旧服务。旧客户端继续走原兼容路径，旧客户端自身的安全提示不会被强行隐藏。

## 构建

`upstream.json` 固定了生产 1.1.16 对应的服务端和 hbb_common 提交。检出对应版本、应用 `legacy-key-signing.patch`，用 Rust 1.88.0 和 `x86_64-unknown-linux-musl` 编译 hbbs。使用 Rust 自带 `rust-lld` 链接器，避免 musl-gcc 生成需要外部 ELF 解释器的可执行文件。`readelf -l hbbs` 应没有 INTERP，`readelf -d hbbs` 应没有 NEEDED。

将二进制放入 Dockerfile 同目录后构建；基础镜像固定为已运行生产镜像的仓库摘要。此次验证二进制 SHA256：`31b9011f76f60fd622aff715ced088b9db0570313ffdea5517df5688f971c0dc`。

## 生产切换与回退

服务器已准备 `/opt/nnu-rustdesk-signing/compose.signing.yml` 和 `compose.rollback.yml`。切换前须确认维护窗口。使用原 compose 文件叠加对应覆盖文件，仅执行 `up -d --no-deps --pull never hbbs`，不要执行整个项目重启，不要重启 hbbr。

生产数据库已使用 SQLite 在线备份；原 compose、容器配置、签名密钥也保存到服务器该目录下的受保护备份目录，原镜像另有回退标签。私钥文件为 `/opt/nnu-rustdesk-signing/id_ed25519`，权限 0600，父目录 0700，只读挂载进 hbbs。私钥不能放入公开客户端、发布包或源码，恢复服务器时必须保留同一密钥。

## 已验证范围

`test_protocol.py` 强制限制到测试端口 32176/32186/32177。已验证关闭补丁保持原响应；1.2.3/1.5.0 注册和打洞消息；原访问口令；错误口令与签名根拒绝；原中继双向数据；设备签名、旧 X25519 密钥交换及 SecretBox 加密往返。测试在独立容器和数据库中运行，未使用生产设备 ID。

这是协议与密码学联调，不代替真实老设备的桌面、文件传输和长期连接验收。对照官方 1.2.3/1.2.6 客户端源码，无可信签名根时仍发送原兼容握手，不会因新增签名阻止旧设备连接。
