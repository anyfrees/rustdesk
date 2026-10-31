# RustDesk NNU 1.5.0 Windows x64

基于 RustDesk 官方 1.5.0 稳定版。适用于你有权管理、且使用者知情的设备。

## 文件选择

- `RustDesk-NNU-1.5.0-x64-Portable.exe`：单文件便携版，双击运行，把界面上的 ID 发给 IT。
- `RustDesk-NNU-1.5.0-x64-Install.exe`：EXE 安装入口，由用户选择安装。
- `RustDesk-NNU-1.5.0-x64.msi`：标准 Windows Installer 安装包。
- `RustDesk-NNU-1.5.0-x64.zip`：完整文件夹版，解压后运行 `rustdesk.exe`。

## 内置服务器

ID：`rd.nnu.cn:21116`；中继：`rd.nnu.cn:22222`；API：`https://rd.nnu.cn`。
连接 key：`137858006`。WebSocket 端口保留 21118 / 21119。
默认使用原生 UDP/TCP，保留局域网直连。当前官方 OSS 服务端的 WSS 入口面向网页客户端，不默认用于桌面端注册。
现有数字 key 是旧式服务端配置，客户端只针对 `rd.nnu.cn` / `rd.0vk.com` 的该配置做兼容：API 登录令牌保留在 HTTPS API 请求中，不转发给不支持其认证、也不提供标准签名公钥的旧版 ID 服务。换用标准公钥或其他 ID 服务时保留上游行为。
支持网站：https://nnu.cn 。账号登录、地址簿、分组使用现有 lejianwen/rustdesk-api。
UI2：主窗口顶部显示“IT技术支持专用版本，请勿共享给他人使用。”；首页底部首次显示可收起的使用提示，后续启动只保留可点击的网站支持链接。首次提示记录保存在本机用户配置中。
UI3：未就绪时在底部增加技术支持邮箱 admin@nnu.cn，可点击打开默认邮件程序；状态恢复后隐藏。
电脑已安装 RustDesk 服务时，请使用同一安装目录内的客户端。新版进程通信会校验程序路径，从其他路径启动便携版可能无法读取已安装后台服务的状态，并显示“未就绪”；这不等同于服务器离线。建议安装本定制 MSI 后，从开始菜单启动，避免混用两个目录。
同事作为被控端提供 ID 时无需登录 API 账号。主控端可通过客户端登录自己的账号。
这些是默认配置，设置中仍可修改。保留 RustDesk 原作者版权和 AGPL 许可证。

## 便携版密码

便携版在没有安装 RustDesk、没有现有永久密码，且没有初始化记录的设备上，首次正常启动会写入管理员指定的固定密码。
固定密码通过仓库 Secret `NNU_PORTABLE_PASSWORD` 编译注入，不写入公开源码。
密码通过 RustDesk 原生加盐哈希存储，并保留连接管理窗口和托盘提示。
用户可在“设置 → 安全”中修改或清除密码；以后启动不会恢复管理员初始密码。
已安装 RustDesk 的电脑沿用原有认证设置。安装版不为全机服务自动设置共享固定密码。
密码模式下，知道该密码的 IT 在获得 ID 后可以连接，无需同事再次点击接受。
退出托盘中的 RustDesk 可结束便携版支持。

## 更新与验证

默认关闭上游自动更新与更新检查，避免 DIY 包被官方客户端替换；后续更新请重新构建此定制分支。
本包未配置商业代码签名证书。请通过附带的 SHA256SUMS.txt 核对下载文件。
安装版需要管理员权限；便携版控制 UAC / 管理员窗口时可能需要用户主动提权。

可复现源码：anyfrees/rustdesk 的 `nnu/windows-1.5.0` 分支，以及 anyfrees/hbb_common 同名分支。
当前采用本机编译，不再消耗 GitHub Actions 额度。保留的工作流仅供今后自行启用。
本机构建使用 Rust 1.75.0、Flutter 3.24.5、LLVM 15.0.6 和 Visual Studio 2022 Build Tools。
Flutter 构建目录应使用英文路径；本机准备好的目录位于 `%USERPROFILE%\.codex\tools\nnu-build\source`。
