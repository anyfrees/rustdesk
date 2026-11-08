import 'package:flutter/material.dart';
import 'nnu_settings_row.dart';

class NnuManagementOptions extends StatelessWidget {
  final bool protected;
  final bool recovery;
  final bool enabled;
  final bool busy;
  final String? error;
  final ValueChanged<String> onAction;

  const NnuManagementOptions(
      {super.key,
      required this.protected,
      required this.recovery,
      required this.enabled,
      required this.busy,
      required this.onAction,
      this.error});

  @override
  Widget build(BuildContext context) {
    final active = enabled && !busy;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      NnuSettingsRow(
        value: protected,
        onChanged: active && error == null
            ? (value) => onAction(value == true ? 'enable' : 'disable')
            : null,
        label: '退出和卸载时验证 PIN',
        hint: !enabled ? '请先解锁安全设置。' : '沿用上方解锁设置的 PIN；修改后同步生效，自动更新不受影响。',
      ),
      const SizedBox(height: 4),
      NnuSettingsRow(
        value: recovery,
        onChanged: active
            ? (value) =>
                onAction(value == true ? 'recovery-enable' : 'recovery-disable')
            : null,
        label: '意外退出后自动恢复',
        hint: !enabled ? '请先解锁安全设置。' : '正常退出和更新期间不重启；界面恢复从下次启动生效。',
      ),
      if (error != null)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ]);
  }
}
