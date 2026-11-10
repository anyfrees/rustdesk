import 'dart:io';
import 'package:flutter/foundation.dart';

Future<void> ensureNnuLinuxDesktopShortcut() async {
  if (!Platform.isLinux) return;
  final executable = File(Platform.resolvedExecutable);
  final helper = File('${executable.parent.path}/nnu_desktop_shortcut.py');
  if (!await helper.exists()) return;
  try {
    final result = await Process.run('/usr/bin/python3', [
      helper.path, '--executable', executable.path,
    ]);
    if (result.exitCode != 0) {
      debugPrint('Desktop shortcut: ${result.stderr}');
    }
  } on ProcessException catch (error) {
    debugPrint('Desktop shortcut: $error');
  }
}
