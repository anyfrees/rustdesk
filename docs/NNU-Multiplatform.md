# NNU 本地多平台安装包

日常操作与安装选择见 [发布助手说明](../res/nnu/release-assistant/README.md)。在助手主界面勾选 Windows、Android、Linux，填写更新说明后开始构建。产物均在本地生成，构建成功不会自动发布到生产服务。

## 当前覆盖

- Windows x64：沿用已验证的 EXE、MSI、ZIP 与 Windows 签名升级包流程。
- Android：ARMv7、ARM64、x86_64 独立 APK、通用 APK、AAB；最低 Android 5.1，包名 `cn.nnu.rustdesk`，显示名 `RustDesk VIP支持专业版`。
- Linux x64：DEB、RPM、AppImage、tar.gz；当前二进制最低 glibc 2.35。

macOS、iOS 需要 Mac/Xcode 和相应签名环境，本机没有生成这些安装包。Linux ARM64、Windows ARM64 尚未覆盖。

## 构建配置与签名

Windows 继续使用原编译器与原发布路径。Linux/Android 使用专用本地 WSL `NNU-SecureBuild`，源代码与缓存均在隔离构建目录。Flutter 3.24.5、Rust 1.88.0、JDK 17、Android SDK 36、NDK r28c、固定提交的 vcpkg 按需准备；各平台有独立的原生依赖安装前缀，避免相互清理。

跨平台源码副本使用 OpenSSL 0.10.81、Tokio 1.54.1、Rustls 0.23.46 和 libsodium 1.0.22。最终跨平台源码 ZIP 含实际使用的依赖锁和公开 native wrapper；Windows 源码另附。所用版本经过本次编译验证，不能据此宣称所有上游依赖均不存在漏洞。

Android 使用独立长期发布密钥，保存在 Windows DPAPI 库和 WSL 私有目录。导出密钥备份时会同时备份 Windows 更新签名与 Android 发布签名；备份采用密码加密，旧 Windows PEM 备份仍可恢复。新 EXE 中仅内置当前 Windows 账户的加密密文。私钥、密码、临时 `key.properties` 不进入源码包。首次使用 Android 签名后，应重新导出一次备份，旧的 Windows 单密钥备份不含 Android 密钥。

独立 APK 逐个按目标架构构建，保持与通用 APK 相同的 `versionCode`，避免 Flutter 默认 ABI 偏移妨碍以后覆盖升级。AAB 和所有 APK 使用同一证书。跨平台副本补齐 Cupertino 图标和手势字体名称，不改动 Windows 已发行二进制。

## 既有代码的变更范围

- `src/lib.rs`：将 NNU 默认配置、自定义 ID 和历史 ID 同步模块的条件编译范围扩展到 Linux/Android，Windows 模块仍启用。
- `src/core_main.rs`：Linux 启动时加载 NNU 默认服务器配置。
- `src/flutter_ffi.rs`：Android 初始化时加载默认配置；Linux/Android 状态轮询触发已有历史 ID 同步。
- `src/nnu.rs`：按平台选择新客户端公钥配置；Windows 保留既有兼容口令。主机判断抽到该功能模块，保持两个 NNU 域名的原判断规则。
- `src/nnu_id.rs`、`src/ui_interface.rs`：Linux 使用桌面已登记身份签名，Android 使用本机设备身份签名，沿用已有服务端校验协议。
- `src/nnu_history.rs`：Linux/Android 复用历史迁移逻辑；Android HTTPS 使用平台证书验证器，不放宽证书检查。
- 发布助手 `app.py`：增加平台选项和结果说明；只选 Windows 时仍调用原 Windows Builder。
- `engine.py`：源码导出额外排除 Android 签名文件，Windows 安装包构建流程保留。
- `signing_vault.py`、`prepare_resources.py`：加入 Android 加密密钥与联合备份，保留旧备份恢复能力。

其它构建逻辑集中在新的 `multiplatform.py`、`cross_worker.py`、`android_packages.py`、`linux_packages.py` 与 Android 密钥模块中。没有安装或重启当前 Windows 远控客户端，也没有修改生产服务配置。

## 验证与边界

本次已完成 Linux 原生核心和 Flutter UI、Android 三种架构核心及签名安装包构建。检查 APK 签名证书、包名、版本号、ABI、ZIP 对齐和 64 位 ELF 16KB 页支持；检查 AAB 签名和架构集合。Linux 检查动态依赖、DEB/RPM 元数据和内容，并在隔离网络与临时配置中运行 CLI/AppImage 启动检查。助手单文件 EXE 已实际启动检查布局，密钥备份/恢复与源码私密文件排除纳入回归测试。

这些检查不等于真实安卓设备远控验收，也不等于逐个 Linux 桌面发行版验收。Android 的屏幕共享、无障碍、麦克风等权限需设备用户自行授权。安装 Linux 系统服务可能替代已安装的 RustDesk，正式设备应安排维护窗口。UI20 起 Android/Linux 接入独立的根密钥签名更新清单，支持客户端内检查、下载和 SHA-256 校验，安装由用户确认；Android 打开系统安装界面，Linux 打开下载目录。Windows 安装版保留原生静默更新和会话保护。后台“多平台更新”导入助手生成的独立“多平台发布包.zip”，统一管理和发布；普通安装包合集仍用于网盘分发。

## UI20 更新入口及回归范围

新增客户端逻辑集中在 `nnu_platform_update_service.dart` 和 `nnu_platform_update.dart`。桌面主页只增加 Linux 按钮及 Windows 原生更新回调，移动设置页只增加 Android 检查入口。`flutter_ffi.rs` 增加 Windows 特定手动更新队列入口，不接收可执行文件路径。Android MainActivity 注册独立安装通道；Manifest 增加安装请求权限及仅限私有更新缓存的 FileProvider，用户仍须完成系统授权和安装。

服务端保留原 Windows 导入/发布/清单路径，新增 `platforms.py`、`platform_release.py` 处理平台签名包、历史和公共清单。共用发布锁改为可重入锁，以调用原 Windows 发布函数；含 Windows 的发布先校验全部文件，Windows 与原生清单分步切换，失败可重试，不承诺跨平台同时切换。暂停推送同时影响各平台清单，已有下载保持可用。仅支持固定发布域名、签名路径及完整平台包组；不接受任意外链或未签名文件。

UI20.1 发布后，各平台保留当前正式版及一个历史版，物理清理更早的服务器安装包、私有发布 ZIP 和版本记录，保留审计日志；仍被其它平台或外链清单引用的目录受保护。新增清理逻辑集中在服务端 `retention.py`，Windows 和多平台发布成功后仅调用一个清理钩子。客户端 Windows 原生更新队列入口仅对 NNU 域名启用，其它服务器配置沿用既有手动下载路径。
