import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_voice_sound.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('waiting reminders can be muted and stop when answered or dismissed', (tester) async {
    const channel = MethodChannel('org.rustdesk.rustdesk/host');
    var enabled = true;
    final played = <int>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'playVoiceCallTone': played.add(call.arguments as int); return enabled;
        case 'getVoiceCallSoundEnabled': return enabled;
        case 'setVoiceCallSoundEnabled': enabled = call.arguments as bool; return null;
      }
      throw MissingPluginException(call.method);
    });
    Future<void> show(NnuVoiceTone tone) => tester.pumpWidget(MaterialApp(home:
      NnuVoiceSound(tone: tone, builder: (enabled, toggle, stop) => TextButton(
        onPressed: toggle, child: Text(enabled ? '有声' : '静音')))));
    await show(NnuVoiceTone.outgoing);
    await tester.pump();
    expect(played.last, 2);
    await tester.pump(const Duration(seconds: 4));
    expect(played.where((mode) => mode == 2), hasLength(2));
    await tester.tap(find.text('有声'));
    await tester.pump();
    expect(enabled, false);
    expect(played.last, 0);
    expect(find.text('静音'), findsOneWidget);
    await show(NnuVoiceTone.quiet);
    await tester.pump();
    final count = played.length;
    await tester.pump(const Duration(seconds: 8));
    expect(played.length, count);
    await show(NnuVoiceTone.incoming);
    await tester.pump();
    expect(played.last, 1);
    expect(find.text('静音'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(played.last, 0);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isWindows);
}
