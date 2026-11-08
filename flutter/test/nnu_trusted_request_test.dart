import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_connected_dock_window.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS controllers do not offer an unsupported reverse file connection', () {
    final client = Client(7, true, false, false, 'Peer', '123', true, true, true)
      ..file = true;
    for (final platform in ['iOS', 'Windows', 'Linux', 'Mac OS', 'Android']) {
      client.officialSupport = NnuOfficialSupportIdentity.fromJson({
        'display_name': 'Support',
        'introduction': 'Remote help',
        'peer_platform': platform,
      });
      expect(client.canReverseFileTransfer, platform != 'iOS');
      expect(NnuOfficialSupportIdentity.fromJson(
          client.officialSupport!.toJson())!.peerPlatform, platform);
    }
    client.file = false;
    expect(client.canReverseFileTransfer, isFalse);
  });

  test('connected dock waits for signed desktop authorization', () {
    final client =
        Client(7, true, false, false, 'Peer', '123', false, false, false);
    client.officialSupport =
        const NnuOfficialSupportIdentity('Support', 'Remote help', 'blue');
    expect(client.isTrustedDesktopConnected, isFalse);
    client.trustedConnectedAt = DateTime.now();
    expect(client.isTrustedDesktopConnected, isTrue);
    client.isFileTransfer = true;
    expect(client.isTrustedDesktopConnected, isFalse);
    client.isFileTransfer = false;
    client.disconnected = true;
    expect(client.isTrustedDesktopConnected, isFalse);
  });

  test('dock stays within the working area and expands from its avatar', () {
    const screen = Rect.fromLTWH(-1280, 30, 1280, 670);
    final placement = NnuDockPlacement(screen, .99);
    expect(placement.compact.right, screen.right - 4);
    expect(placement.compact.bottom, screen.bottom);
    expect(placement.expanded.right, placement.compact.right);
    expect(placement.expanded.bottom, screen.bottom);
    expect(placement.expanded.topLeft + placement.avatarInExpanded,
        placement.compact.center);
  });

  test('Windows scaling keeps the avatar inside the visible desktop', () {
    for (final pixels in [
      const Size(640, 480), const Size(1366, 768), const Size(1920, 1080),
      const Size(2560, 1440), const Size(3840, 2160), const Size(7680, 4320),
    ]) {
      for (final scale in [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]) {
        for (final origin in [Offset.zero, Offset(-pixels.width, -pixels.height)]) {
          final logical = NnuDockPlacement.logicalWorkArea(origin & pixels, scale);
          for (final height in [0.0, .48, 1.0]) {
            final dock = NnuDockPlacement(logical, height);
            expect(dock.compact.intersect(logical), dock.compact);
            expect(dock.expanded.intersect(logical), dock.expanded);
            expect(dock.expanded.topLeft + dock.avatarInExpanded,
                dock.compact.center);
          }
        }
      }
    }
  });

  test('signed avatar and account name survive the connection model', () {
    final identity = NnuOfficialSupportIdentity.fromJson({
      'display_name': '远程支持',
      'introduction': '协助排查远程连接。',
      'badge_color': 'blue',
      'account_name': '陈嘉',
      'avatar_jpeg': '/9j/',
      'click_prompt': true,
      'full_control_on_accept': true,
    })!;
    expect(identity.accountName, '陈嘉');
    expect(identity.avatarJpeg, '/9j/');
    expect(NnuOfficialSupportIdentity.fromJson(identity.toJson())!.avatarJpeg,
        '/9j/');
  });

  test('only pending verified desktop requests can grant full control', () {
    final client =
        Client(7, false, false, false, 'Peer', '123', false, false, false);
    expect(client.isTrustedDesktopRequest, isFalse);
    client.officialSupport =
        const NnuOfficialSupportIdentity('Support', 'Remote help', 'blue');
    expect(client.isTrustedDesktopRequest, isFalse);
    client.officialSupport = const NnuOfficialSupportIdentity(
        'Support', 'Remote help', 'blue',
        clickPrompt: true);
    expect(client.isTrustedDesktopRequest, isTrue);
    expect(client.canAcceptFullControl, isFalse);
    client.officialSupport = const NnuOfficialSupportIdentity(
        'Support', 'Remote help', 'blue',
        clickPrompt: true, fullControlOnAccept: true);
    expect(client.canAcceptFullControl, isTrue);
    client.isTerminal = true;
    expect(client.canAcceptFullControl, isFalse);
    client.isTerminal = false;
    client.authorized = true;
    expect(client.canAcceptFullControl, isFalse);
  });
}
