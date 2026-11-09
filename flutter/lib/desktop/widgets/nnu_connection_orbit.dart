import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/widgets/nnu_official_support_badge.dart';
import '../../common/widgets/nnu_official_support_identity_row.dart';
import '../../models/server_model.dart';
import 'nnu_dock_participants.dart';

List<Client> nnuMultipleDockClients(List<Client> clients,
    {required String approveMode, required bool hidden}) {
  if (hidden) return const [];
  final active = clients.where((c) => !c.disconnected).toList();
  if (active.length < 2) return const [];
  bool desktop(Client c) =>
      !c.nnuVoiceOnly &&
      !c.fromSwitch &&
      !c.isFileTransfer &&
      !c.isViewCamera &&
      !c.isTerminal &&
      c.portForward.isEmpty;
  final desktops = active.where(desktop).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  if (desktops.isEmpty) return const [];
  if (approveMode != 'password' &&
      (desktops.any((c) => !c.isTrustedDesktopConnected) ||
          active.any((c) => !desktop(c) && !c.authorized && !c.nnuVoiceOnly))) {
    return const [];
  }
  return desktops;
}

Client nnuChooseDockClient(List<Client> clients,
        {int? viewed, int? operating}) =>
    clients.firstWhere((c) => c.id == viewed,
        orElse: () => clients.firstWhere((c) => c.id == operating,
            orElse: () => clients.first));

String nnuDockClientName(Client client) {
  final identity = client.officialSupport;
  if (identity != null) {
    return identity.accountName.isNotEmpty
        ? identity.accountName
        : identity.displayName;
  }
  return client.name.isNotEmpty ? client.name : client.peerId;
}

Offset nnuOrbitOffset(int index, int count) {
  final angle = count == 1
      ? -math.pi * .75
      : count == 2
          ? -math.pi * .75 + index * math.pi * 1.5
          : -math.pi / 2 + index * math.pi * 2 / count;
  return Offset(math.cos(angle), math.sin(angle)) * 30;
}

class NnuConnectionOrbit extends StatelessWidget {
  const NnuConnectionOrbit(
      {super.key,
      required this.clients,
      required this.selectedId,
      required this.primary,
      required this.onSelect,
      required this.onShowAll,
      this.colorFor,
      this.wave,
      this.messageSenderId});
  final List<Client> clients;
  final int selectedId;
  final Widget primary;
  final ValueChanged<int> onSelect;
  final VoidCallback onShowAll;
  final Color Function(int)? colorFor;
  final Animation<double>? wave;
  final int? messageSenderId;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = Duration(milliseconds: reduced ? 0 : 200);
    final others = clients.where((c) => c.id != selectedId).toList();
    final sender = others.indexWhere((c) => c.id == messageSenderId);
    if (sender >= 5) others.insert(0, others.removeAt(sender));
    final overflow = others.length > 6;
    final visible = others.take(overflow ? 5 : 6).toList();
    final slots = visible.length + (overflow ? 1 : 0);
    Widget place(Object key, Offset offset, double scale, Widget child) =>
        Positioned.fill(
            key: ValueKey(key),
            child: AnimatedSlide(
                offset: offset / 86,
                duration: duration,
                curve: Curves.easeOutCubic,
                child: Center(
                    child: SizedBox.square(
                        dimension: 52,
                        child: AnimatedScale(
                            scale: scale,
                            duration: duration,
                            curve: Curves.easeOutCubic,
                            child: child)))));
    Color color(Client client) => !client.authorized
        ? const Color(0xffed6b79)
        : colorFor?.call(client.id) ?? const Color(0xff52d890);
    Widget small(Client client) => Semantics(
        button: true,
        label:
            '${nnuDockClientName(client)} · ID ${client.peerId} · #${client.id}',
        child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
                customBorder: const CircleBorder(),
                mouseCursor: SystemMouseCursors.click,
                onTap: () => onSelect(client.id),
                child: Stack(children: [
                  if (wave != null && !reduced)
                    Positioned.fill(
                        child: IgnorePointer(
                            child: CustomPaint(
                                painter: NnuParticipantWave(
                                    wave!, color(client),
                                    phase: client.id * .17)))),
                  Center(
                      child: SizedBox.square(
                          dimension: 44,
                          child: DecoratedBox(
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle, color: color(client)),
                              child: Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: Obx(() => Stack(children: [
                                        Positioned.fill(
                                            child: NnuOfficialSupportAvatar(
                                                name: nnuDockClientName(client),
                                                jpeg: client.officialSupport
                                                        ?.avatarJpeg ??
                                                    '')),
                                        if (client
                                                .unreadChatMessageCount.value >
                                            0)
                                          Positioned(
                                              top: 6,
                                              right: 6,
                                              child: Container(
                                                  width: 10,
                                                  height: 10,
                                                  decoration:
                                                      const BoxDecoration(
                                                          shape:
                                                              BoxShape.circle,
                                                          color: Color(
                                                              0xffeb6676))))
                                      ])))))),
                ]))));
    return SizedBox(
        width: 86,
        height: 86,
        child: Stack(clipBehavior: Clip.none, children: [
          for (var i = 0; i < visible.length; i++)
            place(
                visible[i].id,
                nnuOrbitOffset(i, slots),
                (visible[i].id == messageSenderId ? 26 : 24) / 52,
                small(visible[i])),
          if (overflow)
            place(
                'more',
                nnuOrbitOffset(slots - 1, slots),
                24 / 52,
                Material(
                    color: const Color(0xffe7f0fb),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                        mouseCursor: SystemMouseCursors.click,
                        customBorder: const CircleBorder(),
                        onTap: onShowAll,
                        child: Center(
                            child: Text('+${others.length - 5}',
                                style: const TextStyle(
                                    fontSize: 24,
                                    color: Color(0xff203e61))))))),
          place(selectedId, Offset.zero, 44 / 52, ClipOval(child: primary)),
        ]));
  }
}

class NnuDockConnectionsCard extends StatelessWidget {
  const NnuDockConnectionsCard(
      {super.key,
      required this.clients,
      required this.selectedId,
      required this.onSelect,
      required this.onBack});
  final List<Client> clients;
  final int selectedId;
  final ValueChanged<int> onSelect;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(4),
      child: ClipRRect(
          borderRadius: BorderRadius.circular(21),
          child: Material(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xff243d51)
                  : const Color(0xffedf5fd),
              child: Column(children: [
                Row(children: [
                  IconButton(
                      tooltip: '返回',
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back_rounded, size: 19)),
                  Text('远程连接 · ${clients.length}',
                      style: nnuOfficialSupportTypography)
                ]),
                Expanded(
                    child: ListView.builder(
                        itemCount: clients.length,
                        itemBuilder: (context, index) {
                          final client = clients[index];
                          return ListTile(
                              dense: true,
                              selected: client.id == selectedId,
                              leading: SizedBox.square(
                                  dimension: 30,
                                  child: NnuOfficialSupportAvatar(
                                      name: nnuDockClientName(client),
                                      jpeg:
                                          client.officialSupport?.avatarJpeg ??
                                              '')),
                              title: Text(nnuDockClientName(client),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  'ID ${client.peerId} · #${client.id}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              trailing: Icon(Icons.circle,
                                  size: 8,
                                  color: client.authorized
                                      ? const Color(0xff3caa73)
                                      : const Color(0xffea6572)),
                              onTap: () => onSelect(client.id));
                        })),
              ]))));
}
