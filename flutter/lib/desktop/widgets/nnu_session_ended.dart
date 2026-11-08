import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import '../../models/server_model.dart';
import '../../common/widgets/nnu_official_support_badge.dart';
import '../../common/widgets/nnu_official_support_identity_row.dart';

const nnuSessionEndedSize = Size(360, 274);

Client? nnuTrustedEndedClient(List<Client> clients,
    {Client? previousDock, bool showWindow = true}) {
  if (!showWindow || clients.any((client) => !client.disconnected)) return null;
  final client = previousDock ?? (clients.length == 1 ? clients.single : null);
  if (client == null) return null;
  return (client.disconnected || !clients.contains(client)) &&
      client.authorized && client.officialSupport != null &&
      !client.nnuVoiceOnly && !client.fromSwitch && !client.isFileTransfer && !client.isViewCamera &&
      !client.isTerminal && client.portForward.isEmpty ? client : null;
}

class NnuSessionEndTransition extends StatefulWidget {
  const NnuSessionEndTransition({super.key, required this.identity,
    required this.revealed, required this.child});
  final NnuOfficialSupportIdentity identity;
  final ValueNotifier<bool> revealed;
  final Widget child;

  @override
  State<NnuSessionEndTransition> createState() => _NnuSessionEndTransitionState();
}

class _NnuSessionEndTransitionState extends State<NnuSessionEndTransition>
    with SingleTickerProviderStateMixin {
  late final _open = AnimationController(vsync: this,
    duration: const Duration(milliseconds: 360));

  @override
  void initState() {
    super.initState();
    widget.revealed.addListener(_reveal);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reveal();
  }

  void _reveal() {
    if (!widget.revealed.value) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _open.value = 1;
    } else {
      _open.forward();
    }
  }

  @override
  void dispose() {
    widget.revealed.removeListener(_reveal);
    _open.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(animation: _open,
    child: widget.child, builder: (context, card) {
      final progress = Curves.easeOutCubic.transform(_open.value);
      final name = widget.identity.accountName.isEmpty
          ? widget.identity.displayName : widget.identity.accountName;
      return Stack(fit: StackFit.expand, alignment: Alignment.center, children: [
        if (progress > 0)
          IgnorePointer(ignoring: progress < 1, child: Opacity(opacity: progress,
            child: Transform.scale(scale: .3 + .7 * progress, child: card))),
        if (progress < 1)
          Center(child: Opacity(opacity: (1 - progress * 2).clamp(0, 1),
            child: Transform.scale(scale: 1 + .12 * progress,
              child: TweenAnimationBuilder<double>(tween: Tween(begin: 0, end: 1),
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero : const Duration(milliseconds: 380),
                builder: (context, wave, avatar) => SizedBox(width: 86, height: 86,
                  child: Stack(alignment: Alignment.center, children: [
                    Transform.scale(scale: .62 + .38 * wave,
                      child: Container(decoration: BoxDecoration(shape: BoxShape.circle,
                        border: Border.all(width: 1.5,
                          color: const Color(0xff52d890).withOpacity(.55 * (1 - wave)))))),
                    avatar!,
                  ])),
              child: Container(padding: const EdgeInsets.all(1),
                decoration: BoxDecoration(shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xff52d890))),
                child: NnuOfficialSupportAvatar(name: name.isEmpty ? '?' : name,
                  jpeg: widget.identity.avatarJpeg)))))),
      ]);
    });
}

class NnuSessionEnded extends StatelessWidget {
  const NnuSessionEnded({super.key, required this.identity,
    required this.peerId, required this.onClose});
  final NnuOfficialSupportIdentity identity;
  final String peerId;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xffe2efff) : const Color(0xff203e61);
    final muted = dark ? const Color(0xffa9bdd4) : const Color(0xff58758b);
    final name = identity.accountName.isEmpty ? identity.displayName : identity.accountName;
    final radius = BorderRadius.circular(24);
    return Padding(padding: const EdgeInsets.all(16),
      child: ClipRRect(borderRadius: radius,
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: DecoratedBox(decoration: BoxDecoration(
            color: dark ? const Color(0xf2233c50) : const Color(0xf2edf5fc),
            borderRadius: radius, border: Border.all(
              color: dark ? const Color(0xff4a6378) : const Color(0xffd6e4ef))),
            child: LayoutBuilder(builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 40).clamp(0, double.infinity)),
                child: Column(mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Container(width: 32, height: 32,
                        decoration: BoxDecoration(shape: BoxShape.circle,
                          color: dark ? const Color(0xff365363) : const Color(0xffdcece9)),
                        child: Icon(Icons.link_off_rounded, size: 19, color: muted)),
                      const SizedBox(width: 10),
                      Expanded(child: Text('远程协助已结束', style: nnuOfficialSupportTypography.copyWith(
                        color: ink, fontSize: 19, height: 1.3))),
                    ]),
                    const SizedBox(height: 18),
                    Row(children: [
                      NnuOfficialSupportAvatar(name: name.isEmpty ? '?' : name, jpeg: identity.avatarJpeg),
                      const SizedBox(width: 12),
                      Expanded(child: NnuOfficialSupportNameLine(identity,
                        verifiedLabel: '已通过官方认证', nameColor: ink, fontSize: 16)),
                    ]),
                    const SizedBox(height: 10),
                    Text('ID  $peerId', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 12)),
                    const SizedBox(height: 18),
                    FilledButton(onPressed: onClose, style: FilledButton.styleFrom(
                      enabledMouseCursor: SystemMouseCursors.click,
                      backgroundColor: const Color(0xff285fb5), foregroundColor: Colors.white,
                      minimumSize: const Size(0, 40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11))),
                      child: const Text('关闭')),
                  ]),
              ),
            )),
          ),
        ),
      ),
    );
  }
}
