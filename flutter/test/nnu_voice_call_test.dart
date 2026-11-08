import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' show windowsBuildNumber;
import 'package:flutter_hbb/desktop/widgets/nnu_voice_call.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/common/widgets/nnu_official_support_identity_row.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop voice prompts accept ordinary authorized peers and prioritize incoming calls', () {
    final active = Client(1, true, false, false, 'A', '123', true, true, true)
      ..inVoiceCall = true;
    final incoming = Client(2, true, false, false, 'B', '456', true, true, true)
      ..incomingVoiceCall = true;
    expect(nnuDesktopVoiceClient([active, incoming]), same(incoming));
    incoming.nnuVoiceOnly = true;
    expect(nnuDesktopVoiceClient([incoming]), same(incoming));
    expect(incoming.isTrustedDesktopConnected, false);
    incoming.authorized = false;
    expect(nnuDesktopVoiceClient([incoming]), isNull);
    incoming.authorized = true;
    incoming.disconnected = true;
    expect(nnuDesktopVoiceClient([incoming]), isNull);
    expect(nnuDesktopVoiceClient([active]), same(active));
    active.nnuVoiceOnly = true;
    expect(nnuOnlyVoiceChannels([active, incoming]), true);
    active.nnuVoiceOnly = false;
    expect(nnuOnlyVoiceChannels([active, incoming]), false);
    expect(nnuOnlyVoiceChannels([incoming]), false);
  });

  testWidgets('arrival unfolds explicit accept and reject without automatically answering', (tester) async {
    windowsBuildNumber = 22631;
    final arrived = ValueNotifier(false);
    var accepts = 0;
    var rejects = 0;
    await tester.binding.setSurfaceSize(nnuVoiceCallWindowSize);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: NnuVoiceCall(
      name: 'IT_SERVER', avatarJpeg: '', incoming: true, arrived: arrived,
      onAccept: () => accepts++, onReject: () => rejects++,
      onHangUp: () {}, onMicrophone: () {}))));
    expect(find.text('接听'), findsNothing);
    arrived.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final button = tester.getRect(find.text('接听'));
    final avatar = tester.getRect(find.byType(NnuOfficialSupportAvatar));
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.getRect(find.text('接听')), button);
    expect(tester.getRect(find.byType(NnuOfficialSupportAvatar)), isNot(avatar));
    expect(accepts, 0);
    expect(rejects, 0);
    expect(find.text('拒绝').hitTestable(), findsOneWidget);
    await tester.tap(find.text('接听'));
    await tester.pump();
    expect(accepts, 1);
    await tester.tap(find.text('拒绝'));
    expect(rejects, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    arrived.dispose();
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('connected capsule shows real elapsed time and separate microphone and hangup actions', (tester) async {
    var hangs = 0;
    var microphones = 0;
    for (final size in [nnuVoiceCallWindowSize, const Size(320, 132)]) {
      for (final scale in [1.0, 2.0]) {
        final arrived = ValueNotifier(true);
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale), disableAnimations: true),
          child: NnuVoiceCall(name: 'IT_SERVER', avatarJpeg: '', incoming: false,
            arrived: arrived, onAccept: () {}, onReject: () {},
            onHangUp: () => hangs++, onMicrophone: () => microphones++)))));
        await tester.pump(const Duration(seconds: 3));
        expect(find.text('通话中'), findsOneWidget);
        expect(find.text('接听'), findsNothing);
        expect(microphones, hangs);
        await tester.tap(find.byTooltip('选择麦克风'));
        await tester.tap(find.byTooltip('挂断语音通话'));
        await tester.pumpAndSettle();
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale), disableAnimations: true),
          child: NnuVoiceCall(name: 'IT_SERVER', avatarJpeg: '', incoming: true,
            arrived: arrived, onAccept: () {}, onReject: () {},
            onHangUp: () {}, onMicrophone: () {})))));
        expect(find.text('接听').hitTestable(), findsOneWidget);
        expect(find.text('拒绝').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        arrived.dispose();
      }
    }
    expect(hangs, 4);
    expect(microphones, 4);
    final arrived = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: NnuVoiceCall(name: '设备 A', avatarJpeg: '', incoming: false,
        outgoing: true, arrived: arrived, onAccept: () {}, onReject: () {},
        onHangUp: () {}, onMicrophone: () {})))));
    expect(find.text('呼叫中'), findsOneWidget);
    expect(find.byTooltip('选择麦克风'), findsNothing);
    expect(find.text('接听'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    arrived.dispose();
    await tester.binding.setSurfaceSize(null);
  });
}
