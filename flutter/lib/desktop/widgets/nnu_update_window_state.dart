import 'package:window_manager/window_manager.dart';

Future<bool> nnuRestoreUpdateWindow(List<String> arguments) async {
  if (arguments.contains('--nnu-update-window=normal')) {
    await windowManager.restore();
  }
  if (arguments.contains('--nnu-update-window=hidden')) {
    await windowManager.hide();
    return true;
  }
  if (arguments.contains('--nnu-update-window=minimized')) {
    await windowManager.minimize();
    return true;
  }
  if (arguments.contains('--nnu-update-window=maximized')) {
    await windowManager.maximize();
  }
  return false;
}
