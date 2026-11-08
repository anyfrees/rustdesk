import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nnu_settings_row.dart';
import '../../common.dart' show isWindows;

const _voiceHost = MethodChannel('org.rustdesk.rustdesk/host');
enum NnuVoiceTone { quiet, incoming, outgoing }

class NnuVoiceSound extends StatefulWidget {
  const NnuVoiceSound({super.key, required this.tone, required this.builder});
  final NnuVoiceTone tone;
  final Widget Function(bool enabled, VoidCallback toggle, VoidCallback stop) builder;

  @override
  State<NnuVoiceSound> createState() => _NnuVoiceSoundState();
}

class _NnuVoiceSoundState extends State<NnuVoiceSound> {
  Timer? _repeat;
  bool _enabled = true;

  @override
  void initState() { super.initState(); _sync(); }

  @override
  void didUpdateWidget(covariant NnuVoiceSound oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tone != widget.tone) _sync();
  }

  void _sync() {
    _repeat?.cancel();
    if (!isWindows) return;
    if (widget.tone == NnuVoiceTone.quiet) { _stop(); return; }
    unawaited(_play());
    _repeat = Timer.periodic(const Duration(seconds: 4), (_) => _play());
  }

  Future<void> _play() async {
    try {
      final enabled = await _voiceHost.invokeMethod<bool>('playVoiceCallTone', widget.tone.index);
      if (mounted && enabled != null && _enabled != enabled) setState(() => _enabled = enabled);
    } catch (e) { debugPrint('Voice reminder unavailable: $e'); }
  }

  void _stop() {
    _repeat?.cancel();
    if (!isWindows) return;
    unawaited(_voiceHost.invokeMethod<bool>('playVoiceCallTone', 0).then<void>((_) {})
        .catchError((Object e) { debugPrint('Could not stop voice reminder: $e'); }));
  }

  Future<void> _toggle() async {
    final enabled = !_enabled;
    setState(() => _enabled = enabled);
    try {
      await _voiceHost.invokeMethod<void>('setVoiceCallSoundEnabled', enabled);
      if (!mounted) return;
      if (enabled && widget.tone != NnuVoiceTone.quiet) { await _play(); }
      else { await _voiceHost.invokeMethod<bool>('playVoiceCallTone', 0); }
    } catch (e) {
      if (mounted) setState(() => _enabled = !enabled);
      debugPrint('Could not save voice reminder preference: $e');
    }
  }

  @override
  void dispose() { _stop(); super.dispose(); }

  @override
  Widget build(BuildContext context) => widget.builder(_enabled, _toggle, _stop);
}

class NnuVoiceSoundSetting extends StatefulWidget {
  const NnuVoiceSoundSetting({super.key});
  @override
  State<NnuVoiceSoundSetting> createState() => _NnuVoiceSoundSettingState();
}

class _NnuVoiceSoundSettingState extends State<NnuVoiceSoundSetting> {
  bool? _enabled;
  @override
  void initState() {
    super.initState();
    _voiceHost.invokeMethod<bool>('getVoiceCallSoundEnabled').then((value) {
      if (mounted) setState(() => _enabled = value ?? true);
    }).catchError((Object e) { debugPrint('Could not read voice reminder preference: $e'); });
  }

  Future<void> _change(bool value) async {
    final old = _enabled;
    setState(() => _enabled = value);
    try { await _voiceHost.invokeMethod<void>('setVoiceCallSoundEnabled', value); }
    catch (e) {
      if (mounted) setState(() => _enabled = old);
      debugPrint('Could not save voice reminder preference: $e');
    }
  }

  @override
  Widget build(BuildContext context) => NnuSettingsRow(
    label: '播放来电铃声和呼叫等待提示音', value: _enabled ?? true,
    onChanged: _enabled == null ? null : _change,
    hint: '关闭后静音提醒，不影响接通后的通话声音');
}
