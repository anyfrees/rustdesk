# NNU 软件下载首页

`https://rd.nnu.cn/` 展示真实发布的 Windows、Android、Linux 下载选项、版本和大小，并保留原 `/_admin/#/login?redirect=/` 用户登录入口。版本发布后台仍在 `/update-admin/`，用户账户、API、WebSocket、中继和 ID 服务不迁移。

网页下载由 update-admin 中独立的 `download_portal.py` 处理。默认 2 个名额、单次 512 KB/s、最多 40 人排队，可在后台“下载首页与安全验证”调整为 1–4 个名额、128–2048 KB/s、5–100 人排队。后台保存配置需当前密码；Turnstile 服务端密钥只存于私有 `state/download-portal.json`（0600），GET 接口只返回是否已配置，不回传密钥。正式站拒绝官方测试密钥。未配置或验证失败时网页下载关闭。

Turnstile 站点应允许 `rd.nnu.cn`。浏览器小组件使用 `software_download` 操作名称；服务端向固定 Cloudflare HTTPS Siteverify 验证接口校验成功标志、主机名和 action，禁止重定向，不提供验证绕过。Cloudflare 的 token 有效期与单次使用由其服务端检查。

可复用用户已授权的水印相机 Turnstile 配置，但必须给现有组件添加 `rd.nnu.cn`，保留 `shuiyin.nnu.cn`。仅保存密钥不表示域名已获授权；客户端 `110200` 错误表示需要在 Cloudflare Hostname Management 添加域名。服务器验证密钥不能管理 Cloudflare 组件白名单。

下载凭证为 256 位随机值，同时绑定 HttpOnly / Secure / SameSite Cookie 和 IP 的 HMAC 摘要。服务端事务控制 FIFO、并发和单次消费，不能靠前端改数字获得名额。同一 IP 同时只能占一个名额，以减少多窗口刷队列；共享出口网络的用户可能因此需要等待。

排队 45 秒没有心跳会过期；轮到后 30 秒内开始，否则释放。下载最多占位 20 分钟。服务端发送前再次校验文件 SHA-256，流式发送并限速，结束或断开时释放名额。重启或异常退出遗留的名额会在期限后释放。网页下载不支持 Range 分片与断点续传，连接中断需要重新验证。下载凭证 URL 单独泄漏不能脱离原 Cookie/IP 使用。

新增反向代理处理 rd.nnu.cn 的根页面、`/downloads/` 和后台密码登录接口。网页请求在 OpenResty 上按 IP 和全站限制频率与连接数，并限制请求体和空闲发送时间。网页文件禁用代理缓冲，避免服务端提前读完文件就错误释放并发名额。原站点 `/_admin/`、`/api/`、`/ws/`、`/client-updates/` 和更新清单代理保持原样。

## 自动更新与防刷边界

按用户最终要求，**客户端自动更新不限速、不排队，既有安装包直链保持兼容**。因此机器人仍可直接访问兼容链接；网页验证码和排队只保护网页入口，不能宣称全站安装包访问都必须经过验证码，也不能保证阻断分布式流量攻击。需要彻底封闭直链时，必须另行升级客户端的下载授权协议或在 CDN/WAF 层设流量政策；本次不改变该协议、不添加隐藏的客户端限速规则。

## 验收与回归范围

- 新模块和 `portal-static/` 独立保存公开下载逻辑；`app.py` 仅注册模块并允许页面使用独立 CSP，后台登录页单独允许 Turnstile，其他后台页面保留原 CSP。
- Dockerfile 复制新文件，单进程线程数从 4 增为 8，为网页下载流保留外部验证和后台请求处理能力；无需重启远控、API、中继或原下载容器。
- 后台新增独立配置面板及加载钩子，复用原会话、Origin、CSRF 和密码复验。
- 不改客户端二进制、既有签名、用户登录、公告内容或版本保留规则。
- 28 项后台测试包括：验证失败关闭、设置不回传密钥、hostname/action 校验、CSRF、FIFO 与并发、凭证单次消费、Cookie/IP 绑定、Range 拒绝、断开释放、过期与取消。

上线前需对实际 CNB 镜像做本地只读非 root 容器验收、网页桌面与窄屏检查及代理配置测试；上线后核对首页、登录入口、版本清单签名、静态包和原容器 ID。没有生产 Turnstile 凭据时，不可把网页下载验收标成已启用。

## 后台登录防暴力破解与弹窗稳定性

`login_guard.py` 独立记录 15 分钟失败窗口：同 IP 3 次失败或全站 20 次失败后要求 Turnstile，操作名称为 `admin_login`，不能使用下载页令牌替代。成功清理当前 IP 的失败计数，不清理全站防分布式攻击计数。原每 IP 10 次 / 15 分钟限制、Origin、CSRF、安全 Cookie、通用账号密码错误和 Passkey 验证路径保留；达到硬限制返回 429 和 Retry-After。未配置验证时失败后的密码登录关闭，Passkey 可用。OpenResty 额外对密码登录按 IP 1 次/秒和全站 2 次/秒限流，允许少量突发。无永久账户锁定。

回归面：accounts.py 仅密码登录增加独立保护钩子；app.py 注册模块；Dockerfile 复制模块；static/index.html、app.js、新 login-protection.js 增加按需验证；代理仅为密码接口增加精确规则。用户登录及 Passkey 不改，自动更新不限流。新增测试验证失败升级、正确密码不能绕过验证、验证后恢复、分布式阈值与 Passkey 入口。

portal-static/portal.css 的全屏 backdrop blur 改为稳定遮罩；portal.js 仅在内容或状态变化时更新 DOM，并在验证成功后移除验证 iframe，减少轮询重绘。下载状态机和名额释放规则保持原样。

按用户要求，下载区和弹窗不展示内部安装包文件名、SHA-256、并发/速率参数；后端验证与真实文件名不变。源码访问收纳在页脚“开源许可”，不占用主下载区域。

验证组件的失败重试、过期刷新和交互超时刷新改为手动，并显示重试入口。关闭下载弹窗即移除组件，避免关闭后继续验证或自动刷新；晚到的成功回调不能在已关闭窗口后加入队列。使用 Cloudflare 官方 retry / refresh 配置（https://developers.cloudflare.com/turnstile/get-started/client-side-rendering/widget-configurations/）。

首页最终精简为产品名称、用户登录、平台、格式、版本、大小、下载按钮。删除介绍示意图、身份提醒、安装说明、重复标签和下载政策说明。页脚保留发布后台和折叠开源许可。产品图标均为内嵌 SVG；下拉箭头、许可箭头、关闭及下载图标也使用 SVG。

## 手机端快速导入与平台切换

用户控制台 `/_admin/#/` 首页增加“手机端快速导入”，支持点击配置码或 SVG 复制按钮复制。`mobile_import.py` 从私有 STATE/mobile-import.txt 读取，使用 api-token 调用固定同源 `/api/admin/user/current` 在线验证账户与撤销状态；拒绝未登录、失效、禁用账户、跨 Origin 或验证服务不可达，响应 private/no-store。私有配置不进入 Git、镜像、客户端源码 ZIP 或公开静态文件。

通过 OpenResty 对 `/_admin/` HTML 添加独立脚本与样式，保留现有 API、控制台 JS 和登录路由，不重新构建或重启 RustDesk API。脚本只在已有账户首页挂载，离开、退出或更换 token 时清除。复制失败时提供原生文本选择。

下载首页品牌改为“远程帮助”；iPhone/iPad 使用用户指定的 App Store 链接，不伪造自建 iOS 安装包、版本和大小。平台切换使用190ms opacity/transform过渡，重复点击不重播，快速切换取消前一动画；键盘切换与 prefers-reduced-motion 跳过动效。所有图标为 SVG，页面保持精简。

本次回归面：app.py/Dockerfile 注册并包含独立 mobile_import 模块；portal-locations.conf 只为控制台 HTML 加载增强资源；新 mobile-import JS/CSS 不改变现有登录与账户操作；portal-static/index.html/portal.js/portal.css 必须变更以实现品牌、iPhone入口和切换反馈；ops/deploy_portal.py 验收新品牌及脚本注入。新增2项测试覆盖未登录/撤销拒绝、登录后读取、跨域拒绝、故障关闭、隐私缓存与实时身份验证。原下载协议、签名、公告和客户端二进制不变。
