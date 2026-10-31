import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'nnu_update_service.dart';

class NnuUpdateButton extends StatefulWidget {
  final bool installed;
  final bool Function() hasActiveSession;
  const NnuUpdateButton(
      {super.key, required this.installed, required this.hasActiveSession});

  @override
  State<NnuUpdateButton> createState() => _NnuUpdateButtonState();
}

class _NnuUpdateButtonState extends State<NnuUpdateButton> {
  final _service = NnuUpdateService();
  Timer? _timer;
  bool _checking = false;
  NnuRelease? _release;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 8), () => _check(false));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _service.close();
    super.dispose();
  }

  Future<void> _check(bool manual) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final release = await _service.check();
      if (!mounted) return;
      setState(
          () => _release = release.build > nnuClientBuild ? release : null);
      if (manual) {
        if (_release != null) {
          await _showUpdate();
        } else {
          _message('已是最新版本：$nnuClientVersion');
        }
      }
    } catch (error) {
      if (manual && mounted) _message('检查更新失败，请稍后重试或联系 admin@nnu.cn。\n$error');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _message(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  Future<void> _showUpdate() async {
    final release = _release;
    if (release == null) return;
    File? downloaded;
    var downloading = false;
    var progress = 0.0;
    var error = '';
    final artifact = release.artifacts[widget.installed ? 'msi' : 'portable']!;
    await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return StatefulBuilder(
              builder: (dialogContext, update) => PopScope(
                  canPop: !downloading,
                  child: AlertDialog(
                    title: Text(downloaded == null
                        ? '发现新版本 ${release.version}'
                        : '更新包已校验'),
                    content: SizedBox(
                        width: 440,
                        child: SingleChildScrollView(
                            child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('当前版本：$nnuClientVersion'),
                            const SizedBox(height: 12),
                            Text(release.notes),
                            const SizedBox(height: 12),
                            Text(widget.installed
                                ? '安装更新会中断远程连接，请在结束支持后进行。'
                                : '便携版：下载后退出旧版本，再运行新的便携程序。'),
                            if (downloading) ...[
                              const SizedBox(height: 12),
                              LinearProgressIndicator(value: progress)
                            ],
                            if (downloaded != null) ...[
                              const SizedBox(height: 12),
                              SelectableText(downloaded!.path)
                            ],
                            if (error.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Text(error,
                                  style: TextStyle(
                                      color:
                                          Theme.of(context).colorScheme.error))
                            ],
                          ],
                        ))),
                    actions: [
                      TextButton(
                          onPressed: downloading
                              ? null
                              : () => Navigator.pop(dialogContext),
                          child: const Text('稍后')),
                      if (downloaded == null)
                        TextButton(
                            onPressed: downloading
                                ? null
                                : () async {
                                    update(() {
                                      downloading = true;
                                      error = '';
                                    });
                                    try {
                                      final file = await _service
                                          .download(artifact, (value) {
                                        if (dialogContext.mounted &&
                                            ((value - progress) >= 0.02 ||
                                                value == 1))
                                          update(() => progress = value);
                                      });
                                      if (dialogContext.mounted)
                                        update(() => downloaded = file);
                                    } catch (exception) {
                                      if (dialogContext.mounted)
                                        update(
                                            () => error = '下载或校验失败：$exception');
                                    } finally {
                                      if (dialogContext.mounted)
                                        update(() => downloading = false);
                                    }
                                  },
                            child: const Text('下载并校验'))
                      else
                        TextButton(
                            onPressed: () async {
                              if (widget.installed &&
                                  widget.hasActiveSession()) {
                                update(() => error = '当前仍有远程会话，请结束后安装更新。');
                                return;
                              }
                              try {
                                if (widget.installed) {
                                  await Process.start(
                                      'msiexec.exe', ['/i', downloaded!.path],
                                      mode: ProcessStartMode.detached);
                                } else {
                                  await Process.start('explorer.exe',
                                      ['/select,', downloaded!.path],
                                      mode: ProcessStartMode.detached);
                                }
                                if (dialogContext.mounted)
                                  Navigator.pop(dialogContext);
                              } catch (exception) {
                                update(() => error = '无法打开更新包：$exception');
                              }
                            },
                            child: Text(widget.installed ? '打开安装包' : '打开文件位置')),
                    ],
                  )));
        });
  }

  @override
  Widget build(BuildContext context) => Tooltip(
        message: '$nnuClientVersion · 自建更新服务',
        child: TextButton(
          onPressed: _checking
              ? null
              : () => _release == null ? _check(true) : _showUpdate(),
          child: Text(
              _checking ? '检查中…' : (_release == null ? '检查更新' : '发现新版本'),
              style: const TextStyle(fontSize: 12)),
        ),
      );
}
