# macOS 与 iOS 构建

打开 GitHub 仓库的 **Actions → NNU Apple Build → Run workflow**，选择 `master`，平台选择 `all`、`macos` 或 `ios`。流程由用户手动触发，不依赖 Windows 便携版密码，也不修改线上更新渠道。

macOS 分别使用 Intel 和 Apple 芯片的原生 runner，生成 DMG 与保留应用结构的 ZIP。Intel 版使用 Flutter 3.24.5；Apple 芯片版沿用上游 Flutter 3.44 适配及 ScreenCaptureKit，最低 macOS 12.3。macOS 包仅作临时签名，未进行 Developer ID 签名或苹果公证。

iOS 构建 ARM64 真机版本，最低 iOS 15，应用标识为 `cn.nnu.rustdesk`。按已选择的方案导出 **未签名 IPA**；安装前需要使用有效的 Apple 身份与描述文件自行签名。流程不上传 App Store Connect 或 TestFlight。

成功任务的 Artifacts 中可下载安装包、`BUILD-INFO.json` 与 `SHA256SUMS.txt`，保留 30 天。构建信息记录源码提交、NNU 版本和签名状态。固定使用仓库中的已验证 FFI 桥接文件；Flutter 3.44 任务只重新生成匹配依赖的 Dart 模型。

仓库内的 `res/nnu/official-support-public-keys.txt` 仅包含认证公钥。Apple 入口加载自建服务器默认配置，并启用现有认证根与账号历史/收藏同步模块；不会上传私钥、令牌或本机设置。

Apple 相关改动限于新的工作流与打包脚本、`src/lib.rs` 模块条件，以及 `core_main.rs`、`flutter_ffi.rs`、`client.rs`、`ui_interface.rs` 中已有 NNU 入口的 Apple 条件。Windows/Linux/Android 的运行路径保持原有实现。实际 Apple 编译结果应以对应 Actions 任务为准。
