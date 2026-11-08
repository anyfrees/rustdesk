import 'package:flutter/services.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_update_window_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'),
            (call) async {
      calls.add(call.method);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('window_manager'), null));

  test('background update restart never shows or focuses the main window',
      () async {
    for (final state in ['hidden', 'minimized']) {
      calls.clear();
      expect(
          await nnuRestoreUpdateWindow(['--nnu-update-window=$state']), isTrue);
      expect(calls, [state == 'hidden' ? 'hide' : 'minimize']);
      expect(calls, isNot(contains('show')));
      expect(calls, isNot(contains('focus')));
    }
  });

  test(
      'ordinary launch keeps its existing show path and maximized state restores first',
      () async {
    expect(await nnuRestoreUpdateWindow([]), isFalse);
    expect(calls, isEmpty);
    expect(await nnuRestoreUpdateWindow(['--nnu-update-window=normal']), isFalse);
    expect(calls, ['restore']);
    calls.clear();
    expect(await nnuRestoreUpdateWindow(['--nnu-update-window=maximized']),
        isFalse);
    expect(calls, ['maximize']);
  });
}
