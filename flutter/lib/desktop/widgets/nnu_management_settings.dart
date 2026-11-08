import 'package:flutter/material.dart';
import '../../models/platform_model.dart';
import 'nnu_management_options.dart';

class NnuManagementSettings extends StatefulWidget {
  final bool enabled;
  const NnuManagementSettings({super.key, required this.enabled});

  @override
  State<NnuManagementSettings> createState() => _NnuManagementSettingsState();
}

class _NnuManagementSettingsState extends State<NnuManagementSettings> {
  bool protected = false;
  bool recovery = false;
  bool busy = true;
  String? error;

  @override
  void initState() {
    super.initState();
    perform('refresh');
  }

  Future<void> perform(String action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (action != 'refresh') {
        await bind.mainSetCommon(key: 'nnu-teaching-protection', value: action);
      }
      final status = await bind.mainGetCommon(key: 'nnu-teaching-protection');
      final recoveryStatus =
          await bind.mainGetCommon(key: 'nnu-crash-recovery');
      if (!mounted) return;
      setState(() {
        protected = status == 'enabled';
        recovery = recoveryStatus == 'true';
        error = ['enabled', 'disabled'].contains(status)
            ? null
            : '无法读取管理保护配置，请联系系统管理员恢复。';
      });
    } catch (_) {
      if (mounted) setState(() => error = '读取或修改设置失败，请刷新后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => NnuManagementOptions(
        protected: protected,
        recovery: recovery,
        busy: busy,
        error: error,
        enabled: widget.enabled,
        onAction: perform,
      );
}
