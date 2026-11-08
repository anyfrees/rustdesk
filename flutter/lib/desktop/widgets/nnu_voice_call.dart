import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../common.dart' show kUseCompatibleUiMode;
import '../../common/widgets/audio_input.dart';
import '../../common/widgets/nnu_official_support_badge.dart';
import '../../common/widgets/nnu_official_support_identity_row.dart';
import '../../models/server_model.dart';

const nnuVoiceCallWindowSize = Size(402, 144);

bool nnuOnlyVoiceChannels(List<Client> clients) {
  final active = clients.where((c) => !c.disconnected);
  return active.isNotEmpty && active.every((c) => c.nnuVoiceOnly);
}

Client? nnuDesktopVoiceClient(List<Client> clients) {
  final eligible = clients.where((c) => c.authorized && !c.disconnected &&
      !c.fromSwitch && !c.isFileTransfer && !c.isViewCamera &&
      !c.isTerminal && c.portForward.isEmpty);
  for (final client in eligible) {
    if (client.incomingVoiceCall) return client;
  }
  for (final client in eligible) {
    if (client.inVoiceCall) return client;
  }
  return null;
}

Future<void> nnuChooseVoiceMicrophone(BuildContext context, {bool isCm = true}) async {
  final info = await AudioInput.getDevicesInfo(true, isCm);
  if (!context.mounted) return;
  final devices = info['devices'] as List<String>;
  if (devices.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('未检测到麦克风')));
    return;
  }
  final selected = await showMenu<String>(context: context,
    position: const RelativeRect.fromLTRB(80, 24, 80, 24),
    constraints: const BoxConstraints(maxWidth: 220, maxHeight: 92),
    items: devices.map((device) => PopupMenuItem(value: device, height: 36,
      child: Text(device, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12,
          fontWeight: device == info['current'] ? FontWeight.w700 : FontWeight.w400))))
        .toList());
  if (selected != null) await AudioInput.setDevice(selected, true, isCm);
}

class NnuVoiceCall extends StatefulWidget {
  const NnuVoiceCall({super.key, required this.name, required this.avatarJpeg,
    this.outgoing = false, required this.incoming, required this.arrived, required this.onAccept,
    required this.onReject, required this.onHangUp, required this.onMicrophone,
    this.soundEnabled = true, this.onToggleSound});
  final String name;
  final String avatarJpeg;
  final bool incoming;
  final bool outgoing;
  final ValueNotifier<bool> arrived;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onHangUp;
  final VoidCallback onMicrophone;
  final bool soundEnabled;
  final VoidCallback? onToggleSound;

  @override
  State<NnuVoiceCall> createState() => _NnuVoiceCallState();
}

class _NnuVoiceCallState extends State<NnuVoiceCall>
    with TickerProviderStateMixin {
  late final _open = AnimationController(vsync: this,
      duration: const Duration(milliseconds: 320));
  late final _pulse = AnimationController(vsync: this,
      duration: const Duration(milliseconds: 1800));
  final _elapsed = Stopwatch();
  Timer? _clock;
  bool _answered = false;

  @override
  void initState() {
    super.initState();
    widget.arrived.addListener(_arrive);
    _syncClock();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
    } else {
      _pulse.repeat(period: Duration(milliseconds: widget.incoming ? 1800 : 2800));
    }
    _arrive();
  }

  @override
  void didUpdateWidget(covariant NnuVoiceCall oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.incoming != widget.incoming || oldWidget.outgoing != widget.outgoing) {
      _answered = false;
      _syncClock();
      if (!MediaQuery.disableAnimationsOf(context)) {
        _pulse.repeat(period: Duration(milliseconds: widget.incoming ? 1800 : 2800));
      }
    }
  }

  void _syncClock() {
    _clock?.cancel();
    if (widget.incoming || widget.outgoing) {
      _elapsed.reset();
      _elapsed.stop();
    } else {
      _elapsed.start();
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  void _arrive() {
    if (!widget.arrived.value) return;
    if (MediaQuery.disableAnimationsOf(context) || kUseCompatibleUiMode) {
      _open.value = 1;
    } else {
      _open.forward();
    }
  }

  void _answer(bool accept) {
    if (_answered) return;
    setState(() => _answered = true);
    (accept ? widget.onAccept : widget.onReject)();
  }

  @override
  void dispose() {
    widget.arrived.removeListener(_arrive);
    _clock?.cancel();
    _open.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xffdfedff) : const Color(0xff244566);
    final accent = widget.incoming || widget.outgoing
        ? const Color(0xff5c9de6) : const Color(0xff4bc28a);
    final reduce = MediaQuery.disableAnimationsOf(context);
    final seconds = _elapsed.elapsed.inSeconds;
    final time = '${(seconds ~/ 60).toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
    return Semantics(liveRegion: widget.incoming,
      label: widget.incoming ? '${widget.name} 邀请语音通话' : widget.outgoing ? '正在呼叫 ${widget.name}' : '语音通话已接通',
      child: AnimatedBuilder(animation: Listenable.merge([_open, _pulse]),
        builder: (context, _) {
          final progress = Curves.easeOutCubic.transform(_open.value);
          final wave = reduce ? .5 : (math.sin(_pulse.value * math.pi * 2) + 1) / 2;
          final lift = widget.incoming && progress == 1 && !reduce
              ? (-2 * math.pow(math.sin(_pulse.value * math.pi), 2)).toDouble() : 0.0;
          return Stack(fit: StackFit.expand, alignment: Alignment.center, children: [
              if (progress > 0)
                Padding(padding: const EdgeInsets.all(22),
                  child: Opacity(opacity: progress,
                    child: Transform.scale(scaleX: .18 + .82 * progress,
                      scaleY: .86 + .14 * progress,
                      child: ClipRRect(borderRadius: BorderRadius.circular(60),
                        child: DecoratedBox(decoration: BoxDecoration(
                            color: dark ? const Color(0xff243d51) : const Color(0xffedf6fe),
                            borderRadius: BorderRadius.circular(60),
                            border: Border.all(color: dark
                                ? const Color(0xff526e83) : const Color(0xffccdfef))),
                            child: Row(children: [
                              Expanded(child: Center(child: widget.incoming
                                  ? _answerButton(false)
                                  : Column(mainAxisSize: MainAxisSize.min, children: [
                                      Text(widget.outgoing ? '呼叫中' : '通话中', style: TextStyle(color: accent, fontSize: 12)),
                                      const SizedBox(height: 3),
                                      FittedBox(fit: BoxFit.scaleDown,
                                        child: Text(widget.outgoing ? '等待接听' : time, style: TextStyle(color: ink, fontSize: 14,
                                          fontFeatures: const [FontFeature.tabularFigures()]))),
                                    ]))),
                              const SizedBox(width: 80),
                              Expanded(child: Center(child: widget.incoming
                                  ? _answerButton(true)
                                  : Row(mainAxisSize: MainAxisSize.min, children: [
                                      if (!widget.outgoing) IconButton(tooltip: '选择麦克风', onPressed: widget.onMicrophone,
                                        color: ink, icon: const Icon(Icons.mic_none_rounded, size: 20)),
                                      IconButton(tooltip: '挂断语音通话', onPressed: widget.onHangUp,
                                        color: const Color(0xffd70015),
                                        icon: const Icon(Icons.call_end_rounded, size: 22)),
                                    ]))),
                            ])),
                        )))),
              Positioned(left: 0, right: 0,
                child: Transform.translate(offset: Offset(0, lift),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(width: 86, height: progress == 0 ? 86 : 72,
                    child: Stack(alignment: Alignment.center, children: [
                      if (!reduce)
                        SizedBox(width: 60 + 12 * wave, height: 60 + 12 * wave,
                          child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle,
                            border: Border.all(color: accent.withOpacity(.18 + .2 * (1 - wave)), width: 1.5)))),
                      Container(padding: const EdgeInsets.all(1),
                        decoration: BoxDecoration(shape: BoxShape.circle,
                          border: Border.all(color: accent, width: 1.5)),
                        child: NnuOfficialSupportAvatar(name: widget.name.isEmpty ? '?' : widget.name,
                          jpeg: widget.avatarJpeg)),
                    ])),
                  if (progress > .8)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      ConstrainedBox(constraints: const BoxConstraints(maxWidth: 96),
                        child: Text(widget.name, textAlign: TextAlign.center,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: nnuOfficialSupportTypography.copyWith(color: ink, fontSize: 11))),
                      if ((widget.incoming || widget.outgoing) && widget.onToggleSound != null)
                        SizedBox(width: 28, height: 24, child: IconButton(
                          padding: EdgeInsets.zero, iconSize: 15, color: ink,
                          tooltip: widget.soundEnabled ? '静音提醒' : '开启提示音',
                          onPressed: widget.onToggleSound,
                          icon: Icon(widget.soundEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded))),
                    ]),
                ]))),
            ]);
        }));
  }

  Widget _answerButton(bool accept) => FittedBox(
    fit: BoxFit.scaleDown, child: FilledButton.icon(
    onPressed: _answered ? null : () => _answer(accept),
    style: FilledButton.styleFrom(
      enabledMouseCursor: SystemMouseCursors.click,
      backgroundColor: accept ? const Color(0xff248a3d) : const Color(0xffd70015),
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      textStyle: nnuOfficialSupportTypography.copyWith(fontSize: 13),
      shape: const StadiumBorder()),
    icon: Icon(accept ? Icons.call_rounded : Icons.call_end_rounded, size: 18),
    label: Text(accept ? '接听' : '拒绝')));
}
