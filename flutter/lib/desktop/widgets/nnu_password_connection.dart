import 'package:flutter/material.dart';

import '../../common/widgets/nnu_official_support_badge.dart';
import '../../common/widgets/nnu_official_support_identity_row.dart';
import '../../models/server_model.dart';

Client? nnuPasswordConnectionDock(List<Client> clients,
    {required String approveMode, required bool hidden}) {
  if (approveMode != 'password' || hidden) return null;
  final active = clients.where((c) => !c.disconnected);
  if (active.length != 1) return null;
  final client = active.single;
  return !client.nnuVoiceOnly && !client.fromSwitch && !client.isFileTransfer &&
      !client.isViewCamera && !client.isTerminal && client.portForward.isEmpty
      ? client : null;
}

Client? nnuCancelledPasswordDock(Client? previous, List<Client> clients,
    {required bool wasDock, required bool visiblePasswordMode}) {
  if (!wasDock || !visiblePasswordMode || previous == null ||
      previous.authorized || clients.any((c) => !c.disconnected)) return null;
  return previous;
}

Future<bool> nnuFadeCancelledPasswordDock({required bool reducedMotion,
    required bool Function() stillCurrent,
    required Future<void> Function(double) setOpacity,
    required Future<void> Function() hide}) async {
  final frames = reducedMotion ? 1 : 12;
  for (var frame = 1; frame <= frames; frame++) {
    if (!stillCurrent()) return false;
    await setOpacity(1 - Curves.easeInCubic.transform(frame / frames));
    if (frame < frames) await Future<void>.delayed(const Duration(milliseconds: 15));
  }
  if (!stillCurrent()) return false;
  await hide();
  return true;
}

class NnuPasswordConnectionCard extends StatelessWidget {
  const NnuPasswordConnectionCard({super.key, required this.client,
    required this.name, required this.onDisconnect, this.exiting = false, this.connectionsButton,
    this.hasOrbit = false});
  final Client client;
  final String name;
  final VoidCallback onDisconnect;
  final bool exiting;
  final Widget? connectionsButton;
  final bool hasOrbit;

  @override
  Widget build(BuildContext context) {
    final pending = !client.authorized;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xffe2efff) : const Color(0xff203e61);
    final muted = dark ? const Color(0xffa9bdd4) : const Color(0xff486781);
    final identity = client.officialSupport;
    return Padding(padding: const EdgeInsets.all(4), child: DecoratedBox(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(21),
        color: dark ? const Color(0xff243d51) : const Color(0xffedf5fd),
        border: Border.all(color: muted.withOpacity(.25))),
      child: Padding(padding: const EdgeInsets.all(17), child: Visibility(
        visible: !exiting, maintainSize: true, maintainState: true, maintainAnimation: true,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: EdgeInsetsDirectional.only(start: hasOrbit ? 74 : 65),
            child: SizedBox(height: 50, child: identity != null
              ? NnuOfficialSupportNameLine(identity, verifiedLabel: '', nameColor: ink, fontSize: 19)
              : Align(alignment: AlignmentDirectional.centerStart,
                  child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: nnuOfficialSupportTypography.copyWith(fontSize: 19, color: ink))))),
          SizedBox(height: hasOrbit ? 23 : 11),
          Expanded(child: SingleChildScrollView(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('ID  ${client.peerId}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: muted)),
              const SizedBox(height: 8),
              Row(children: [
                Icon(Icons.circle, size: 7,
                  color: pending ? const Color(0xffea6572) : const Color(0xff3caa73)),
                const SizedBox(width: 7),
                Expanded(child: AnimatedSwitcher(duration: const Duration(milliseconds: 180),
                  child: Align(key: ValueKey(pending), alignment: AlignmentDirectional.centerStart,
                    child: Text(pending ? '等待密码验证' : '已连接',
                      style: TextStyle(color: ink, fontWeight: FontWeight.w600))))),
              ]),
              if (pending) ...[
                const SizedBox(height: 6),
                Text('密码验证通过后才能访问设备', style: TextStyle(fontSize: 12, color: muted)),
              ],
            ]))),
          const SizedBox(height: 8),
          Row(children: [if (connectionsButton != null) connectionsButton!,
          Expanded(child: OutlinedButton.icon(onPressed: onDisconnect,
            icon: Icon(pending ? Icons.close_rounded : Icons.link_off_rounded, size: 16),
            label: Text(pending ? '拒绝连接' : '断开连接'),
            style: OutlinedButton.styleFrom(
              enabledMouseCursor: SystemMouseCursors.click,
              minimumSize: const Size(0, 39),
              foregroundColor: dark ? const Color(0xffffaab4) : const Color(0xff983540),
              backgroundColor: dark ? const Color(0xff3d3449) : const Color(0xfffff5f7),
              side: BorderSide(color: muted.withOpacity(.25)),
              textStyle: nnuOfficialSupportTypography.copyWith(fontSize: 13),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))))),
          ]),
        ]))),
    ));
  }
}
