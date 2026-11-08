import 'package:flutter/material.dart';
import 'nnu_settings_row.dart';

class NnuConnectionWindowOption extends StatelessWidget {
  final bool showWindow;
  final bool enabled;
  final bool passwordOnly;
  final ValueChanged<bool> onChanged;

  const NnuConnectionWindowOption({
    super.key,
    required this.showWindow,
    required this.enabled,
    required this.passwordOnly,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return NnuSettingsRow(
      value: passwordOnly ? showWindow : true,
      onChanged: enabled && passwordOnly ? onChanged : null,
      label: '连接时显示连接管理窗口',
      hint: !enabled
          ? '请先解锁安全设置。'
          : passwordOnly
              ? null
              : '连接批准方式设为“仅密码”后可关闭；需要人工同意时保留窗口。',
    );
  }
}
