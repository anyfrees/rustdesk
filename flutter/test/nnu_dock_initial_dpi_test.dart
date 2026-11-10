import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/desktop/widgets/nnu_connected_dock_window.dart';
import 'package:flutter_test/flutter_test.dart';

class _Binding extends Fake implements RustdeskImpl {
  @override
  String getLocalFlutterOption({required String k, dynamic hint}) => '';
}

void main() {
  testWidgets('initial avatar uses native DPI before Flutter catches up', (tester) async {
    platformFFI.setBindingForTesting(_Binding());
    addTearDown(tester.view.resetDevicePixelRatio);
    const sizeChannel = MethodChannel('flutter/windowsize');
    const managerChannel = MethodChannel('window_manager');
    const hostChannel = MethodChannel('org.rustdesk.rustdesk/host');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var nativeDpi = 1.75;
    Rect? actual;
    Map<String, Object> screen() => {
      'frame': <double>[0, 0, 3072, 1920],
      'visibleFrame': <double>[0, 0, 3072, 1836], 'scaleFactor': nativeDpi,
    };
    messenger.setMockMethodCallHandler(sizeChannel, (call) async =>
        call.method == 'getScreenList' ? [screen()] : {
          'frame': <double>[100, 100, 440, 600],
          'scaleFactor': nativeDpi, 'screen': screen(),
        });
    messenger.setMockMethodCallHandler(hostChannel, (_) async => null);
    messenger.setMockMethodCallHandler(managerChannel, (call) async {
      final a = Map<String, dynamic>.from(call.arguments as Map);
      final ratio = a['devicePixelRatio'] as double;
      if (call.method == 'getBounds') {
        return {'x': 100 / ratio, 'y': 100 / ratio, 'width': 440 / ratio, 'height': 600 / ratio};
      }
      if (call.method == 'setBounds') {
        actual = Rect.fromLTWH(a['x'] * ratio, a['y'] * ratio,
            a['width'] * ratio, a['height'] * ratio);
      }
      return null;
    });
    addTearDown(() {
      for (final channel in [sizeChannel, managerChannel, hostChannel]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });
    for (final dpi in [.75, 1.0, 1.25, 1.75, 2.0, 3.0]) {
      nativeDpi = dpi;
      tester.view.devicePixelRatio = dpi == 1 ? 2 : 1;
      await NnuConnectedDockWindow().enter();
      expect(actual!.right, closeTo(3072 - 4 * dpi, .001));
      expect(actual!.width, closeTo(86 * dpi, .001));
      expect(actual!.center.dy, closeTo(1836 * .48, .001));
    }
  }, skip: !Platform.isWindows);
}
