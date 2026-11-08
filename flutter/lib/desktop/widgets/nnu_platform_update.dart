import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'nnu_action_button.dart';
import 'nnu_update_footer.dart';
import 'nnu_platform_update_service.dart';
import 'nnu_update_service.dart' show nnuClientBuild, nnuClientVersion;

const _formats = {
  'android-universal': '通用 APK',
  'linux-deb': 'DEB（Debian / Ubuntu）',
  'linux-rpm': 'RPM（Fedora / RHEL）',
  'linux-appimage': 'AppImage',
  'linux-tar': 'tar.gz'
};

class NnuPlatformUpdateButton extends StatefulWidget {
  const NnuPlatformUpdateButton({super.key});

  @override
  State<NnuPlatformUpdateButton> createState() =>
      _NnuPlatformUpdateButtonState();
}

class _NnuPlatformUpdateButtonState extends State<NnuPlatformUpdateButton> {
  final _service = NnuPlatformUpdateService();
  NnuPlatformRelease? _release;
  File? _package;
  String? _status;
  double? _progress;
  bool _busy = false;

  @override
  void dispose() {
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

  Future<void> _check() async {
    if (_busy) return;
    _busy = true;
    _show('正在检查更新');
    try {
      final release = await _service.check('linux');
      if (!mounted) return;
      _release = release.build > nnuClientBuild ? release : null;
      _show(_release == null ? '已是最新版本' : null);
    } catch (error) {
      debugPrint('Unable to check the Linux update: $error');
      _show('检查失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(NnuPlatformArtifact artifact) async {
    if (_busy) return;
    _busy = true;
    _show('正在下载', 0);
    try {
      final file = await _service.download(artifact, (value) {
        if (_progress == null || value - _progress! >= .01 || value == 1) {
          _show('正在下载', value);
        }
      }, onVerifying: () => _show('正在校验安装包'));
      if (!mounted) return;
      _package = file;
      _show(null);
    } catch (error) {
      debugPrint('Unable to download the Linux update: $error');
      _show('更新失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    final file = _package;
    if (file == null || _busy) return;
    _busy = true;
    _show('正在打开文件位置');
    try {
      final result = await Process.run('xdg-open', [file.parent.path]);
      if (result.exitCode != 0) throw StateError('xdg-open failed');
      _show(null);
    } catch (error) {
      debugPrint('Unable to open the Linux update: $error');
      _show('无法打开文件位置');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
        menuChildren: [
          if (_release != null)
            for (final entry in _release!.artifacts.entries)
              if (_formats.containsKey(entry.key))
                MenuItemButton(
                  onPressed: () => _download(entry.value),
                  child: Text(_formats[entry.key]!),
                ),
        ],
        builder: (context, menu, child) => NnuUpdateFooter(
          status: _status,
          progress: _progress,
          working: _busy,
          label: _package != null
              ? '打开文件位置'
              : _release != null
                  ? '选择安装包'
                  : '检查更新',
          onPressed: _busy
              ? null
              : _package != null
                  ? _open
                  : _release != null
                      ? () => menu.isOpen ? menu.close() : menu.open()
                      : _check,
        ),
      );
}

Future<void> showNnuPlatformUpdate(BuildContext context) async {
  if (!Platform.isAndroid && !Platform.isLinux) return;
  await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PlatformUpdateDialog());
}

class _PlatformUpdateDialog extends StatefulWidget {
  const _PlatformUpdateDialog();
  @override
  State<_PlatformUpdateDialog> createState() => _PlatformUpdateDialogState();
}

class _PlatformUpdateDialogState extends State<_PlatformUpdateDialog> {
  final service = NnuPlatformUpdateService();
  NnuPlatformRelease? release;
  File? file;
  bool busy = true;
  double? progress;
  String message = '',
      kind = Platform.isAndroid ? 'android-universal' : 'linux-deb';
  @override
  void initState() {
    super.initState();
    check();
  }

  @override
  void dispose() {
    service.close();
    super.dispose();
  }

  Future<void> check() async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final found =
          await service.check(Platform.isAndroid ? 'android' : 'linux');
      if (!found.artifacts.containsKey(kind))
        throw const FormatException('此版本未提供适用安装包');
      if (mounted)
        setState(() {
          release = found.build > nnuClientBuild ? found : null;
          message = release == null ? '已是最新版本' : '';
        });
    } catch (error) {
      if (mounted) setState(() => message = '检查失败：$error');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> download() async {
    setState(() {
      busy = true;
      progress = 0;
      message = '';
    });
    try {
      final downloaded =
          await service.download(release!.artifacts[kind]!, (value) {
        if (mounted &&
            (progress == null || value - progress! >= .02 || value == 1))
          setState(() => progress = value);
      });
      if (mounted)
        setState(() {
          file = downloaded;
          message = '文件已通过 SHA-256 校验';
        });
    } catch (error) {
      if (mounted) setState(() => message = '下载失败：$error');
    } finally {
      if (mounted)
        setState(() {
          busy = false;
          progress = null;
        });
    }
  }

  Future<void> open() async {
    try {
      if (Platform.isAndroid) {
        final result = await const MethodChannel('cn.nnu.rustdesk/update')
            .invokeMethod<String>('install', file!.path);
        if (mounted && result == 'permission')
          setState(() => message = '请在系统设置允许此应用安装更新，返回后再次点击“安装更新”。');
      } else {
        final result = await Process.run('xdg-open', [file!.parent.path]);
        if (result.exitCode != 0) throw StateError('无法打开目录，请复制下方文件路径');
      }
    } catch (error) {
      if (mounted) setState(() => message = '无法打开：$error');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: Text(release == null ? '检查更新' : '发现新版本 ${release!.version}'),
        content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('当前版本：$nnuClientVersion'),
                  if (release != null) ...[
                    const SizedBox(height: 12),
                    Text(release!.notes),
                    const SizedBox(height: 12),
                    Text(Platform.isAndroid
                        ? '下载并校验通用 APK，安装由系统确认。请先结束远程支持并保存工作。'
                        : '下载与你的系统匹配的安装包，结束远程支持后自行安装。'),
                    if (Platform.isLinux && file == null)
                      DropdownButton<String>(
                          value: kind,
                          isExpanded: true,
                          items: _formats.entries
                              .where((e) => e.key.startsWith('linux-'))
                              .map((e) => DropdownMenuItem(
                                  value: e.key, child: Text(e.value)))
                              .toList(),
                          onChanged: busy
                              ? null
                              : (value) => setState(() => kind = value!)),
                  ],
                  if (busy) ...[
                    const SizedBox(height: 16),
                    LinearProgressIndicator(value: progress)
                  ],
                  if (message.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(message)
                  ],
                  if (file != null) ...[
                    const SizedBox(height: 12),
                    SelectableText(file!.path)
                  ],
                ]))),
        actions: [
          NnuActionButton(
              label: '关闭',
              onPressed: busy ? null : () => Navigator.pop(context)),
          if (!busy && release == null)
            NnuActionButton(label: '重试检查', onPressed: check),
          if (release != null)
            NnuActionButton(
                primary: true,
                label: file == null
                    ? '下载并校验'
                    : Platform.isAndroid
                        ? '安装更新'
                        : '打开文件位置',
                onPressed: busy
                    ? null
                    : file == null
                        ? download
                        : open),
        ],
      ));
}
