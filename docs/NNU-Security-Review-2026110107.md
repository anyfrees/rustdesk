# UI13 构建依赖安全复核

复核版本：1.5.0 NNU UI13，内部版本 2026110107。此记录覆盖本次客户端 Rust 锁文件、平台选择和所改管理功能，不等于完整操作系统或所有第三方二进制的安全认证。

## 本次已升级

Windows 与跨平台源码：OpenSSL 0.10.81、Rustls 0.23.46、rustls-webpki 0.103.16、crossbeam-channel 0.5.15、rand 0.8.6/0.9.3、URL 2.5.4 与 IDNA 1.0.3。Windows 保留 Rust 1.75 工具链，IDNA 的 Unicode 依赖锁定为兼容版本。Linux/Android 另使用 Rust 1.88、Tokio 1.54.1、time 0.3.47 和 libsodium 1.0.22。

相关上游公告：[Crossbeam](https://rustsec.org/advisories/RUSTSEC-2025-0024.html)、[IDNA](https://rustsec.org/advisories/RUSTSEC-2024-0421.html)、[Rustls](https://github.com/rustls/rustls/security/advisories/GHSA-2mjx-qc3c-rqvc)、[WebPKI](https://github.com/rustls/webpki/security/advisories/GHSA-82j2-j2ch-gfr8)。

## 锁文件仍报告的项目

| 依赖 | 当前范围与处理 |
|---|---|
| git2 0.16.1 / libgit2-sys 0.14.2 | keepawake → shadow-rs 的构建依赖；未进入 Windows 普通运行时依赖图。高危告警仍保留在原始扫描记录，不当作已升级。 |
| glib 0.18.5 | Linux GTK3 依赖。修复版 0.20 不兼容当前 GTK3 依赖约束。受影响的是 VariantStrIter；本次未发现应用源码使用 array_iter_str/VariantStrIter，但仍保留上游告警，未进行 GTK 栈迁移。 |
| time 0.3.36 | Windows 保留以兼容原工具链；受影响的是恶意 RFC2822 输入解析。本次检查应用及 ASN.1/X509/rcgen 调用路径未发现该解析；发现的 RFC2822 用途为格式化输出。Linux/Android 已升级 0.3.47。Windows 残留告警不隐瞒。 |
| time 0.1.45 | fruitbasket 的 macOS 平台依赖，本机未生成 macOS 安装包。 |
| rpassword 2.1.0 | 锁文件条目；本次普通依赖图未发现选入 Windows 运行路径，未假称已升级。 |

上游范围：[GLib 公告](https://rustsec.org/advisories/RUSTSEC-2024-0429.html)、[time 公告](https://rustsec.org/advisories/RUSTSEC-2026-0009.html)。没有把“未发现调用”当作已修复，也没有声称全部依赖零漏洞。

## 管理功能与发布核验

覆盖安装复用的清理脚本生成函数不再执行 PIN 校验；明确的 EXE 卸载仍校验。MSI 独立卸载在破坏性动作前验证，MajorUpgrade 排除该验证。PIN 窗口直接复用 Flutter 现有对话框和输入组件；原生层验证，专用成功退出码授权，取消/关闭/启动失败均不授权。PIN 不放入进程参数或日志。管理保护和恢复默认关闭。

已运行 13 项界面回归、2 项 PIN 校验测试、1 项连接窗口策略测试、6 项启动及历史迁移检查；安装包另检查版本、摘要、升级清单签名、MSI 动作条件。PIN 窗口已单独启动目视检查，未安装或重启当前远控客户端。尚未在隔离 Windows 虚拟机联合实测受保护设备的升级、卸载及崩溃恢复；Android 和 Linux 也仍需真实设备远控验收。
