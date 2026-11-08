import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'nnu_update_footer.dart';
import 'nnu_update_service.dart';

class NnuUpdateButton extends StatefulWidget {
  const NnuUpdateButton({
    super.key,
    required this.installed,
    required this.installedPackageName,
    required this.hasActiveSession,
    this.requestAutomaticUpdate,
    this.readAutomaticProgress,
  });

  final bool installed;
  final String Function() installedPackageName;
  final bool Function() hasActiveSession;
  final Future<String> Function()? requestAutomaticUpdate;
  final Future<String> Function()? readAutomaticProgress;

  @override
  State<NnuUpdateButton> createState() => _NnuUpdateButtonState();
}

class _NnuUpdateButtonState extends State<NnuUpdateButton> {
  final _service = NnuUpdateService();
  bool _busy = false;
  String? _status;
  double? _progress;
  File? _package;
  Timer? _clearStatus;

  @override
  void dispose() {
    _clearStatus?.cancel();
    _service.close();
    super.dispose();
  }

  void _show(String? status, [double? progress]) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _progress = progress;
    });
  }

  void _latest() {
    _show('已是最新版本');
    if (!mounted) return;
    _clearStatus = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _status = null);
    });
  }

  void _nativeProgress(String value) {
    if (value.startsWith('downloading:')) {
      final percent = int.tryParse(value.substring(12));
      if (percent != null && percent >= 0 && percent <= 100) {
        _show('正在下载', percent / 100);
      }
      return;
    }
    switch (value) {
      case 'checking':
        _show('正在检查更新');
        break;
      case 'verifying':
        _show('正在校验安装包');
        break;
      case 'installing':
        _show('正在安装更新');
        break;
    }
  }

  Future<String> _automaticUpdate() async {
    final request = widget.requestAutomaticUpdate;
    if (!widget.installed || request == null) return 'manual';
    final read = widget.readAutomaticProgress;
    var requesting = true;
    Future<String> readProgress() async {
      if (read == null) return '';
      try {
        return await read();
      } catch (error) {
        debugPrint('Unable to read update progress: $error');
        return '';
      }
    }

    Future<void> followRequest() async {
      while (mounted && requesting && read != null) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted || !requesting) break;
        final value = await readProgress();
        if (requesting) _nativeProgress(value);
      }
    }

    unawaited(followRequest());
    try {
      final result = await request();
      if (result != 'busy') return result;
    } finally {
      requesting = false;
    }

    while (mounted && read != null) {
      final value = await readProgress();
      if (const {'latest', 'waiting', 'handoff', 'failed'}.contains(value)) {
        return value;
      }
      if (value.isEmpty) return 'failed';
      _nativeProgress(value);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return 'failed';
  }

  Future<void> _check() async {
    if (_busy) return;
    _clearStatus?.cancel();
    _busy = true;
    _show('正在检查更新');
    try {
      final release = await _service.check();
      if (!mounted) return;
      if (release.build <= nnuClientBuild) {
        _latest();
        return;
      }
      final outcome = await _automaticUpdate();
      if (!mounted) return;
      switch (outcome) {
        case 'latest':
          _latest();
          return;
        case 'handoff':
          _show('安装程序已启动');
          return;
        case 'waiting':
          _show(widget.hasActiveSession() ? '远程会话结束后可更新' : '更新暂缓，请重试');
          return;
        case 'manual':
          break;
        default:
          _show('更新失败，请重试');
          return;
      }

      final packageName = widget.installed ? widget.installedPackageName() : '';
      final kind = !widget.installed
          ? 'portable'
          : packageName.endsWith('.msi')
              ? 'msi'
              : packageName.endsWith('.exe')
                  ? 'install'
                  : '';
      final artifact = release.artifacts[kind];
      if (artifact == null) {
        _show('未找到适用的更新包');
        return;
      }
      _show('正在下载', 0);
      final file = await _service.download(
        artifact,
        (value) {
          if (_progress == null ||
              (value - _progress!).abs() >= .01 ||
              value == 1) {
            _show('正在下载', value);
          }
        },
        onVerifying: () => _show('正在校验安装包'),
      );
      if (!mounted) return;
      _package = file;
      _show(null);
    } catch (error) {
      debugPrint('NNU update failed: $error');
      _show('更新失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPackage() async {
    final file = _package;
    if (file == null || _busy) return;
    if (widget.installed && widget.hasActiveSession()) {
      _show('远程会话结束后可安装');
      return;
    }
    _busy = true;
    _show(widget.installed ? '正在启动安装程序' : '正在打开文件位置');
    try {
      if (widget.installed && file.path.endsWith('.msi')) {
        await Process.start('msiexec.exe', ['/i', file.path],
            mode: ProcessStartMode.detached);
      } else if (widget.installed) {
        await Process.start(file.path, [], mode: ProcessStartMode.detached);
      } else {
        await Process.start('explorer.exe', ['/select,', file.path],
            mode: ProcessStartMode.detached);
      }
      if (!mounted) return;
      _package = null;
      _show(widget.installed ? '安装程序已启动' : '已打开文件位置');
    } catch (error) {
      debugPrint('Unable to open NNU update package: $error');
      _show('无法打开更新包，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => NnuUpdateFooter(
        status: _status,
        progress: _progress,
        working: _busy,
        label: _package == null
            ? '检查更新'
            : widget.installed
                ? '安装更新'
                : '打开文件位置',
        onPressed: _busy
            ? null
            : _package == null
                ? _check
                : _openPackage,
      );
}
