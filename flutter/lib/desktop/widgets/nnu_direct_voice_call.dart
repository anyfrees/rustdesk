import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import 'nnu_voice_call.dart';
import 'nnu_voice_sound.dart';
import 'nnu_connected_dock_window.dart';

Future<void> nnuStartDirectVoiceCall(
    BuildContext context, String id, String alias) async {
  try {
    await Process.start(Platform.resolvedExecutable,
        ['--nnu-voice-call', id, alias.isEmpty ? id : alias],
        mode: ProcessStartMode.detached);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('无法发起语音呼叫，请重试')));
    }
    debugPrint('Voice call launch failed: $e');
  }
}

Future<void> runNnuDirectVoiceCall(String id, String name) async {
  await windowManager.ensureInitialized();
  runApp(GetMaterialApp(
    debugShowCheckedModeBanner: false,
    theme: MyTheme.lightTheme,
    darkTheme: MyTheme.darkTheme,
    themeMode: MyTheme.currentThemeMode(),
    home: _DirectVoiceCall(id: id, name: name),
  ));
  await windowManager.waitUntilReadyToShow(WindowOptions(
    size: nnuVoiceCallWindowSize, center: true, skipTaskbar: true,
    alwaysOnTop: true, titleBarStyle: TitleBarStyle.hidden,
    backgroundColor: Colors.transparent, title: '语音呼叫',
  ), () async {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(false);
    await windowManager.setHasShadow(false);
    await const MethodChannel('org.rustdesk.rustdesk/host')
        .invokeMethod<void>('setTrustedRequestFrame', true);
    await nnuConnectedDockWindow.centerRequest(nnuVoiceCallWindowSize);
    await const MethodChannel('org.rustdesk.rustdesk/host')
        .invokeMethod<void>('setTrustedWindowShape', 6);
    await windowManager.setOpacity(1);
    await windowManager.show();
    await windowManager.focus();
  });
}

class _DirectVoiceCall extends StatefulWidget {
  const _DirectVoiceCall({required this.id, required this.name});
  final String id;
  final String name;
  @override
  State<_DirectVoiceCall> createState() => _DirectVoiceCallState();
}

class _DirectVoiceCallState extends State<_DirectVoiceCall> {
  final arrived = ValueNotifier(true);
  StreamSubscription<EventToUI>? _events;
  Timer? _timeout;
  bool _connected = false;
  bool _finished = false;
  bool _closing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final error = bind.sessionAddSync(sessionId: gFFI.sessionId, id: widget.id,
        isFileTransfer: false, isViewCamera: false, isPortForward: false,
        isRdp: false, isTerminal: false, switchUuid: '', forceRelay: false,
        password: '', isSharedPassword: false, connToken: null, loginMethod: '');
      if (error.isNotEmpty) {
        await _fail(error);
        return;
      }
      _events = bind.sessionStart(sessionId: gFFI.sessionId, id: widget.id)
          .listen(_event, onError: (Object e) => _fail('连接失败，请重试'),
            onDone: () { if (!_finished) _fail('通话已结束'); });
      _timeout = Timer(const Duration(seconds: 60), () => _fail('对方暂未接听'));
    } catch (e) {
      debugPrint('Direct voice call failed: $e');
      await _fail('无法发起语音呼叫，请重试');
    }
  }

  void _event(EventToUI event) {
    if (_finished || event is! EventToUI_Event) return;
    if (event.field0 == 'close') { _fail('通话已结束'); return; }
    final Map<String, dynamic> value;
    try { value = jsonDecode(event.field0); } catch (_) { return; }
    switch (value['name']) {
      case 'on_voice_call_started':
        _timeout?.cancel();
        if (mounted) setState(() => _connected = true);
        break;
      case 'on_voice_call_closed':
        if (_connected) { _close(); } else { _fail('对方已拒绝或结束通话'); }
        break;
      case 'msgbox':
        if (value['type'] == 'error' || value['type'] == 'restarting' ||
            value['type'] == 'error_no_retry') {
          _fail(translate(value['text']?.toString() ?? '连接失败'));
        }
        break;
    }
  }

  Future<void> _fail(String message) async {
    if (_finished) return;
    _finished = true;
    _timeout?.cancel();
    if (mounted) setState(() => _error = message);
    await bind.sessionClose(sessionId: gFFI.sessionId);
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    final closeSession = !_finished;
    _finished = true;
    _timeout?.cancel();
    if (mounted) setState(() {});
    await windowManager.hide();
    if (closeSession) {
      unawaited(bind.sessionClose(sessionId: gFFI.sessionId)
          .catchError((Object e) { debugPrint('Voice channel cleanup: $e'); }));
    }
    await windowManager.destroy();
  }

  @override
  void dispose() {
    _events?.cancel();
    _timeout?.cancel();
    arrived.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: _closing ? const SizedBox.shrink() : DragToMoveArea(child: _error != null
      ? Padding(padding: const EdgeInsets.all(22), child: Material(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xff243d51) : const Color(0xffedf6fe),
          shape: const StadiumBorder(), child: Row(children: [
            const SizedBox(width: 24),
            const Icon(Icons.info_outline_rounded, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(_error!, maxLines: 3,
              style: const TextStyle(fontSize: 13))),
            IconButton(tooltip: '关闭', onPressed: _close,
                icon: const Icon(Icons.close_rounded)),
            const SizedBox(width: 10),
          ])))
      : NnuVoiceSound(tone: _connected ? NnuVoiceTone.quiet : NnuVoiceTone.outgoing,
          builder: (enabled, toggle, stop) => NnuVoiceCall(
            name: widget.name, avatarJpeg: '', incoming: false,
            soundEnabled: enabled, onToggleSound: toggle,
            outgoing: !_connected, arrived: arrived, onAccept: () {},
            onReject: () { stop(); _close(); }, onHangUp: () { stop(); _close(); },
            onMicrophone: () => nnuChooseVoiceMicrophone(context, isCm: false)))),
  );
}
