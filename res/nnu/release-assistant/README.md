# RUSTDESK版本发布助手

这是管理员本机使用的 Windows 图形化工具。普通远控用户继续使用客户端的“检查更新”，不用安装此助手或配置编译环境。

## 本地多平台构建

主界面勾选需要的平台，再填写更新说明并点击“开始构建”。可单选或多选；默认保留 Windows，避免每次只更新 Windows 时重复构建其它平台。

| 平台 | 产物 |
| --- | --- |
| Windows x64 | 便携 EXE、安装 EXE、MSI、ZIP，以及单独的签名升级发布包 |
| Android | ARM64、ARMv7、x86_64 独立 APK，通用 APK，以及用于应用分发的 AAB |
| Linux x64 | DEB、RPM、AppImage、tar.gz |

Android 和 Linux 在本机专用 WSL `NNU-SecureBuild` 中编译，不调用远程构建服务。首次会在这个隔离环境中补全官方 Flutter、Rust、JDK、Android SDK/NDK、vcpkg 和系统依赖，校验下载摘要；以后复用缓存。不会安装或重启本机正在使用的 RustDesk。若专用 WSL 不可用，工具会明确报错，不修改其它发行版或自动重启 Windows。

当前配置：Flutter 3.24.5、跨平台 Rust 1.88.0、Android SDK 36 / NDK r28c / JDK 17，vcpkg 固定提交。跨平台副本单独升级 OpenSSL 0.10.81、Tokio 1.54.1、Rustls 0.23.46 和 libsodium 1.0.22，不改变 Windows 旧编译器配置。Linux 包要求 glibc 2.35 或更新版本；DEB 适合 Ubuntu 22.04+、Debian 12+ 同级环境，RPM/AppImage 仍需相应桌面图形和音频环境。未覆盖 Linux ARM64、Windows ARM64、macOS、iOS。后两者需要另备 Mac/Xcode 和相应签名环境。

Android 应用名为 `RustDesk VIP支持专业版`，包名 `cn.nnu.rustdesk`，与应用商店官方应用并存。普通安卓手机优先安装 `android-universal.apk`；ARM64 APK 体积更小。AAB 不能直接点击安装。Android 密钥由助手生成并用当前 Windows 账户加密保存，也写入专用 WSL 的仅管理员可读目录；后续一直复用同一签名，才能覆盖升级。设置中的“备份密钥”会同时导出 Windows 更新签名和 Android 发布签名的密码加密备份，换电脑时一并恢复。私钥、密码和 `key.properties` 不进入源码和发布包。

多平台产物按 `安装包/Windows`、`安装包/Android`、`安装包/Linux` 分类，并附 SHA256 校验和、匹配的跨平台源码和多平台安装包合集。多平台合集用于网盘分发；另生成根密钥签名的“多平台发布包.zip”。点击“定位多平台发布包”，在后台“多平台更新”中导入、预览、发布；含 Windows 时会同时发布 Windows 更新。后台可查看各平台版本、下载包及发布包。仅构建 Windows 时仍保留原 Windows 升级包流程。UI20 起 Android 的“设置 → 关于 → 检查更新”和 Linux 主窗口的“检查更新”可校验清单、下载并验证文件，安装由用户确认；AAB 仅作分发。

已有脚本调用方式仍默认 Windows。命令行可用 `--check --platforms android linux` 检查本地跨平台环境，或在原 `--build --version ... --notes ...` 参数后加 `--platforms windows android linux`。图形界面的勾选项与这些参数对应。

## 平时怎么用

1. 双击桌面“RUSTDESK版本发布助手”。当前电脑的源码、工具、产物目录和签名密钥路径已配置。
2. 需要跟进上游时先点“拉取官方新版”；无新版会直接提示，有新版则下载官方稳定版源码并套用 NNU 配方。确认版本名称，填写更新说明，点击“开始构建”。内部 build 自动递增。
3. 完成后点击“定位升级包”，再“打开发布后台”。在后台登录，导入这个升级发布包 ZIP，预览后明确点击发布。

助手自动生成：便携版 EXE、安装版 EXE、MSI 安装包、ZIP 文件夹版，以及一个带有效 Ed25519 签名、可导入后台的“升级发布包.zip”。另附源码 ZIP、摘要和构建信息。后台升级包是四个完整安装包的签名集合，不是差分补丁；不能仅改版本号、替换文件或编辑签名后说明。

点击“打开安装包”可找到适合首次安装和分发的各个文件；“定位升级包”选中唯一需要上传后台的 ZIP。后台保留最终发布确认；助手不会自动上线、自动登录或保存后台密码。

## 谁负责新版本内容

“拉取官方新版”从 rustdesk/rustdesk 官方稳定版 API 查询 tag，解析不可变提交，下载该提交及官方 hbb_common 源码，套用 NNU 的样式、服务器、支持信息、自建升级和会话保护配方，在独立目录执行补丁兼容检查、配置检查和现有 Flutter 回归。必要时尝试本地生成 Flutter/Rust 桥接。成功后切换助手的源码目录，原源码继续保留；再点击开始构建生成安装包。

官方若改变了配方涉及的代码、桥接工具或构建要求，工具将停止并报告兼容问题，保留原源码及线上版本。不能保证未来所有官方版本无需维护即可定制。首次发行验证覆盖官方 1.5.0：它仍是 2026-10-31 查询到的最新稳定版。其他新增业务功能仍需先修改源码；填写说明本身不会自动开发新功能。

源码改动影响原生核心时，助手自动完整重编译。仅 Flutter 界面变化时，只有源文件指纹与已验证核心摘要均相符才复用缓存。首次配置或完整构建需要在设置中填写与现有发行配置一致的便携版预设密码；该值只在当前进程内存和子进程环境中使用，不写入设置/日志。该预设密码会按照原客户端规则编入核心，并不影响已安装设备自己的密码。

当前机器已经配置 Flutter 3.24.5、Rust 1.75.0、VS2022 与 vcpkg。助手自带 Python UI 运行环境、LLVM libclang、NuGet、必要驱动、窗口辅助组件、源码快照和 DIY 配方。设置中“检查并补全”会保留已有组件，缺少时从官方地址下载 Flutter/Rust/vcpkg，或通过 Microsoft winget 安装 Python、Git 和 Visual Studio C++ 构建工具；个别系统安装可能要求管理员授权或重开助手。下载 SDK 依据官方摘要校验。首次补全和原生库编译可能下载数 GB，并不宣称在全新电脑上离线一键构建。

签名密钥已内置：单文件 EXE 内携带 DPAPI 加密密钥，并在当前 Windows 账户的本机加密库保存副本，日常无需选择文件。原始 PEM 保留在本机私人目录，未上传或删除；工具不能将明文密钥导出到源码、普通安装包或服务器。DPAPI 密钥与当前 Windows 账户/电脑关联，复制此 EXE 到另一台电脑不等于复制可用签名权限。请在设置里“导出密钥备份”，自己设置备份密码，保存 `.nnu-key` 到另一处；新电脑用“恢复密钥”输入该备份密码。恢复时会核对客户端公钥，拒绝不匹配密钥。助手 EXE 本身仅给发布管理员保存，不作为普通客户端安装包公开分发。

## 产物

默认位于源码同级 `dist/NNU-<build>-<时间>/`：

```text
安装包/
  RustDesk-NNU-1.5.0-x64-Portable.exe
  RustDesk-NNU-1.5.0-x64-Install.exe
  RustDesk-NNU-1.5.0-x64.msi
  RustDesk-NNU-1.5.0-x64.zip
  RustDesk-NNU-1.5.0-Source.zip
  BUILD-INFO.json
  SHA256SUMS.txt
NNU-<build>-升级发布包.zip
signed/stable.json
signed/releases/<build>/...
构建日志.log
构建结果.json
```

编译前运行现有 Flutter/Rust 回归测试；打包后逐个解压便携嵌入文件，与 Release 目录、ZIP 内容逐字节核对；签名后按生产公钥验签和校验四个安装包。所有命令在独立英文构建副本执行，源代码仅更新当前 build 和展示版本；失败则还原本次版本文件。不触发 GitHub Actions，不安装或停止正在运行的 RustDesk。

产物为完整包。Windows 安装版在启用自动更新时校验后静默安装；手动检查也可交给原生更新器，不再重复打开安装向导。更新等待远程会话结束，自动检查还等待本机空闲，系统提权提示仍需确认。关闭自动更新及便携版保留手动流程。Android/Linux 支持在线检查、校验下载，安装由用户确认。清单签名不等于 Windows Authenticode 代码签名；当前产物沿用现有未签 Authenticode 状态。

## 已有安装包

设置 →“从已有安装包生成”，选择同一构建导出的完整目录（含四包、BUILD-INFO.json、更新说明.txt）。助手保持该目录 build 和版本名称，重新生成升级发布包，不伪装成新的 build。缺包或签名公钥不匹配会拒绝。完整重编译请用主界面的“开始构建”。

## 构建助手本身

Python 安装 requirements.txt 后运行 package-assistant.ps1，输出单文件 `RUSTDESK版本发布助手.exe`，包含 Python 界面运行库、构建辅助组件、源码快照、DIY 配方和 DPAPI 加密密钥。不需要旁边的 `_internal` 目录，移动或备份时只需复制这个 EXE。程序、窗口和快捷方式使用 NNU 蓝色发布图标。

每次启动会先在 Windows 临时目录展开运行组件，退出后由打包运行器清理；首次启动可能稍慢。设置、密钥库副本及构建缓存继续保存在原有本机目录，更换 EXE 不会重置它们。编译用 Flutter、Rust、Visual Studio 等大型工具仍按需补全，不会全部塞进助手 EXE。原目录版保留用于回退。

设置文件：`%LOCALAPPDATA%/NNU/ReleaseAssistant/settings.json`，仅保存路径和内置密钥标志；DPAPI 密钥副本位于同目录 signing-key.dpapi。核心缓存记录位于工具根目录的 release-assistant/。不修改客户端账号密码、不调用服务器发布 API、不持有 SSH 或后台凭据。
