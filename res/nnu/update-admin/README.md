# NNU 版本管理后台

地址：`https://rd.nnu.cn/update-admin/`。独立容器 `nnu-rustdesk-admin`，服务器 `/opt/nnu-rustdesk-admin`，监听 `127.0.0.1:32171`。原更新容器、API、hbbs/hbbr 不重建、不重启。

## 发布

1. 继续使用 `../update-server/publish.py` 在本机生成已签名发布目录。build 必须递增，更新说明属于签名内容，修改后必须在本机重新签名。
2. 将该目录导出为单个 ZIP：

```powershell
py res/nnu/update-admin/bundle.py --source <已签名发布目录> --output <发布包.zip>
```

3. 登录，点击“导入发布包”，选择 ZIP。上传后服务器验证生产公钥签名及全部四个安装包的大小、SHA-256。
4. 预览版本、说明与安装包，点击“发布此版本”并确认。也可稍后从版本记录发布。

同一构建号不可覆盖。已经发布的旧版本保留下载。最多保留三个待发布版本，可在列表点击“删除待发布包”。此操作删除服务器暂存安装文件和待发布记录，不进回收站；操作日志保留，不影响你本机原文件及已发布下载。原始上传 ZIP 在校验后已经删除。允许导入现有 UI4 包来验证流程，重复导入只显示原版本，不重复发布。

暂停推送仅使 stable.json 返回 HTTP 204，原清单保持不变；现有客户端手动检查将提示更新服务暂不可用。不会回退已安装版本，已有安装包下载不受影响。恢复后返回原有有效签名清单。暂停期间发布仍保持暂停。

## 认证与持久化

管理员在首次部署时初始化，密码随机生成。credentials.json 此后只作为初始账户种子和会话签名密钥来源，不再覆盖数据库中的账户。明文初始登录资料仅保存本机非公开文件，文件不会在你修改密码后自动更新；请自行妥善保存新密码。签名私钥始终留在本机，后台无需也不接受它。

会话有效期 12 小时；Secure、HttpOnly、SameSite=Strict Cookie。所有变更要求 CSRF token，并检查 Origin。退出会撤销服务器会话；同一来源 15 分钟最多尝试十次登录。生产环境只通过现有 HTTPS 反向代理访问。应用校验请求主机名；NNU_HOST_ALIASES 仅列出确实由该站点代理的旧域名，不能使用通配符。CSRF 请求头只接受 ASCII token，异常字符直接返回 403。

`state/admin.sqlite` 保存管理员密码哈希、Passkey 公钥及计数、版本清单、操作记录、会话和下载统计。数据库及状态目录限制为服务账户访问。`state/paused` 保存推送开关。`public/.admin-staging` 保存待发布文件，位于同一下载卷以实现目录原子移动，下载服务器不会对外提供该路径。stable.json 通过临时文件 fsync + 原子替换切换，历史安装包不可覆盖。

备份 `state/`、`credentials.json`、`/opt/nnu-rustdesk-updates/public/`。SQLite 在线备份请使用 Python sqlite3 backup API 或停管理容器后拷贝；不要直接只拷贝活跃数据库主文件。管理容器停机不会停止已存在的安装包下载；stable 清单代理届时返回网关错误。紧急回退见下文。

### 修改账户

右上角点击当前用户名进入“账户设置”。填写新用户名和/或新密码（12–128 字符），验证当前密码后保存。新密码留空即保留原密码。成功后当前页面保持登录，其他会话全部失效；用户名修改不会影响已添加的 Passkey。

### Passkey

在“账户设置”中填写当前密码及 Passkey 名称，点击“添加 Passkey”，由本人完成 Windows Hello、手机或安全密钥的系统验证。下次在登录页点击“使用 Passkey 登录”，无需填写用户名或密码。支持查看、撤销多个 Passkey；撤销后相关登录会话失效，密码登录始终保留。

仅在 `https://rd.nnu.cn` 使用正式 Passkey（RP ID 为 rd.nnu.cn），不能在其他域名或 IP 地址之间通用。浏览器不支持时可继续用密码登录。验证用户存在和用户验证标志，检查完整 origin/RP ID/挑战/签名及计数器；挑战绑定当前浏览器、三分钟过期且只能使用一次。服务器只保存公钥，不接收 Passkey 私钥或生物识别数据。

### 应急恢复

拥有可信服务器终端权限时可交互重设账户（命令不携带明文密码，不输出新密码）：

```sh
docker exec -it nnu-rustdesk-admin python reset_account.py --username admin
```

按提示输入并确认新密码。恢复操作会撤销全部会话；需要一并撤销已有 Passkey 时显式加 `--revoke-passkeys`。不要通过改 credentials.json 重置账户，它只用于第一次初始化。账号变更保存在数据库中，正常重建/重启容器不会恢复初始账号密码。


## 统计

只读挂载现有 OpenResty access.log，按日志 inode/字节偏移增量聚合到 SQLite。只计安装包路径的 GET 200/206 请求和实际返回字节，不记录 IP、不推算安装人数。包含测试、重试和分段请求。界面显示上海时区最近七天已采集日志；首次读取回填当前日志，已经轮转的旧日志不回填。后台每 30 秒自动采集，首次积压分批处理，每批最多读取 32 MiB。停机期间日志轮转可能造成未采集区间，故不作为完整审计或计费数据。

## 部署与回退

先在本机运行 `download-deps.ps1` 从官方 PyPI 下载 Linux Python 3.12 wheels，将源码与 wheels 一起传到服务器，再运行 `docker compose build && docker compose up -d`。容器构建离线安装依赖，避免服务器外网下载缓慢。UID/GID 10001 需要写 state、public 根目录和 releases 目录；原安装包保持 nginx 可读。容器无 Docker socket、无 SSH 凭据、无签名私钥。依赖安装完成后从运行镜像移除 pip；后续更新依赖通过重新构建镜像完成。

现有 OpenResty server 添加以下位置，修改前备份，`nginx -t` 后平滑 reload：

```nginx
location = /update-admin { return 302 /update-admin/; }
location ^~ /update-admin/ {
    client_max_body_size 2100m;
    client_body_timeout 1800s;
    proxy_pass http://127.0.0.1:32171;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_request_buffering off;
    proxy_read_timeout 1800s;
    proxy_send_timeout 1800s;
}
location = /client-updates/stable.json {
    proxy_pass http://127.0.0.1:32171/feed;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_buffering off;
}
```

保留原 `location ^~ /client-updates/`。HTTP 80 下后台、清单及安装包入口应跳转 HTTPS；站点 TLS 配置仅启用 TLSv1.2 TLSv1.3。

回退管理服务：删除以上新增位置，或恢复对应 `.nnu-admin-backup-*` 配置，测试后 reload。原 `/client-updates/stable.json` 将直接由既有 nginx 更新容器提供，继续使用最后一次发布清单；暂停开关此时不再生效。然后可停止管理容器。安装包地址与原 API 不变。

## 验证

安装 requirements.txt（Windows 本地测试无需 gunicorn），运行 `py -m unittest -v test_admin.py`，以及 `node test_passkey_encoding.cjs`。测试生成一次性测试签名密钥和模拟 WebAuthn 验证器的真实椭圆曲线签名，仅写临时目录，不使用生产私钥，不创建真实新版本。覆盖账户变更/会话撤销、Passkey 完整注册与登录、错误 origin/RP/签名/用户验证、挑战过期/跨浏览器/重放及 Passkey 撤销。浏览器布局验收不能代替本人 Windows Hello/手机的首次注册验证。

本改动全部为新目录，不改客户端、原发布脚本和原更新 nginx 配置。线上唯一新增分发路径是 stable.json 经管理服务读取原文件，以提供暂停语义；四种安装包仍由原 nginx 容器传输。


## 客户端公告

版本页中的“客户端公告”支持保存草稿、发布与撤下。标题最多 80 字、正文最多 2000 字，按纯文本显示。保存草稿不更改当前发布的公告；发布替换现有公告；撤下保留草稿，客户端下次同步时收起消息栏。约每 5 分钟同步一次，不影响远控认证与版本推送。多人或多标签页修改使用 revision 冲突检查。

公开 GET `/update-admin/notices.json` 只返回已发布快照（没有公告时 announcement 为 null），不返回草稿或账户信息；管理 API 位于既有 `/update-admin/api/announcement` 下，沿用账号/Passkey 会话、Origin 与 CSRF 防护。数据存入既有 admin.sqlite，操作记入审计记录。无 HTML、脚本或远程资源渲染。

仅公告改动可在 CNB 对 main 触发 `api_trigger_admin`，构建测试目标与发布镜像，仅生成 update-admin 镜像。部署前在 NNU-SecureBuild 本地验证 CNB 镜像，生产只更新该镜像，不在服务器构建，不重建 hbbs/hbbr/API/下载容器。

## 多平台版本管理（UI20）

助手构建 Android/Linux 时同时生成独立的 `NNU-<build>-多平台发布包.zip`。在“多平台更新”导入后先校验根密钥 Ed25519 签名、所有文件的大小及 SHA-256，再预览发布。含 Windows 时复用既有 Windows 签名包及发布路径；单独构建一个平台时保留其它平台当前版本。普通安装包合集仅用于分发。

清单在 `/update-admin/platforms/android/stable.json`、`/update-admin/platforms/linux/stable.json`，安装包沿用固定 HTTPS 下载域名。客户端 UI20 起可检查和下载，Android/Linux 安装需用户确认。APK、AAB、DEB、RPM、AppImage、tar.gz 均可查看下载；AAB 不能直接安装。

相同构建号不能覆盖、平台通道不能回退。最多 3 个待发布多平台包；移除只删除待发布记录及其自有暂存文件。已发布的原始多平台 ZIP 保存在私有 `state/platform-bundles` 供已登录管理员下载，应计入备份和磁盘容量规划。含 Windows 的发布为分步切换；全部文件先预检，Windows 发布后再切换 Android/Linux 清单，后续失败时可重试。旧 Windows 导入、外链与 stable.json 协议保持兼容。

## 文件保留规则

每个平台保留当前正式版本与一个已发布历史版本。成功发布后物理删除更早的安装文件、私有多平台 ZIP 和后台版本记录，保留操作审计。待发布包、各平台当前清单以及外链清单仍引用的本地安装文件受保护；不同平台版本不同时，保留其所需目录的并集。清理失败会写入操作记录，并在发布结果中返回失败构建号，不能把清理失败当作已删除。
