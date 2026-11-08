import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

Future<void> runNnuPinDialog(String action) async {
  await windowManager.ensureInitialized();
  await platformFFI.init('nnu-pin-dialog');
  runApp(GetMaterialApp(
    debugShowCheckedModeBanner: false,
    theme: MyTheme.lightTheme,
    darkTheme: MyTheme.darkTheme,
    themeMode: MyTheme.currentThemeMode(),
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: supportedLocales,
    home: Scaffold(
      backgroundColor: kUseCompatibleUiMode ? null : Colors.transparent,
      body: NnuPinDialog(
        action: action,
        verify: (pin) =>
            bind.mainGetCommon(key: 'nnu-confirm-management-pin:$pin'),
        onCancel: () => exit(1602),
      ),
    ),
  ));
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: const Size(440, 310),
      center: true,
      alwaysOnTop: true,
      backgroundColor: kUseCompatibleUiMode ? null : Colors.transparent,
      titleBarStyle:
          kUseCompatibleUiMode ? TitleBarStyle.normal : TitleBarStyle.hidden,
      title: '验证 PIN',
    ),
    () async {
      await windowManager.setResizable(false);
      if (!kUseCompatibleUiMode) await windowManager.setAsFrameless();
      await windowManager.show();
      await windowManager.focus();
      await windowManager.setOpacity(1);
    },
  );
}

class NnuPinDialog extends StatefulWidget {
  const NnuPinDialog({
    super.key,
    required this.action,
    required this.verify,
    required this.onCancel,
  });

  final String action;
  final Future<String> Function(String pin) verify;
  final VoidCallback onCancel;

  @override
  State<NnuPinDialog> createState() => _NnuPinDialogState();
}

class _NnuPinDialogState extends State<NnuPinDialog> {
  final controller = TextEditingController();
  bool busy = false;
  int attempts = 0;
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (busy || attempts >= 3) return;
    if (controller.text.trim().isEmpty) {
      setState(() => error = '请输入 PIN。');
      return;
    }
    setState(() => busy = true);
    String message;
    try {
      // A valid PIN ends this isolated process in the native verifier.
      message = await widget.verify(controller.text);
    } catch (_) {
      message = '无法验证 PIN，请重试。';
    }
    if (!mounted) return;
    setState(() {
      attempts++;
      busy = false;
      controller.clear();
      error = attempts >= 3
          ? '尝试次数过多，请取消后重试。'
          : message.isEmpty
              ? '无法验证 PIN，请重试。'
              : message;
    });
  }

  @override
  Widget build(BuildContext context) => CustomAlertDialog(
        title: const DragToMoveArea(
          child: SizedBox(width: double.infinity, child: Text('验证 PIN')),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.action),
            const SizedBox(height: 16),
            PasswordWidget(
              controller: controller,
              title: 'PIN',
              hintText: '请输入用于解锁设置的 PIN',
              errorText: error,
            ),
          ],
        ),
        actions: [
          dialogButton('Cancel', onPressed: widget.onCancel, isOutline: true),
          dialogButton('OK', onPressed: busy || attempts >= 3 ? null : submit),
        ],
        onSubmit: submit,
        onCancel: widget.onCancel,
      );
}
