import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../common/widgets/nnu_official_support_badge.dart';
import '../../common/widgets/nnu_official_support_identity_row.dart';
import '../../models/server_model.dart';
import 'nnu_request_waves.dart';

const nnuTrustedRequestWindowSize = Size(446, 286);

class NnuTrustedRequest extends StatelessWidget {
  const NnuTrustedRequest({
    super.key,
    required this.identity,
    required this.fullControl,
    required this.onAccept,
    required this.onReject,
  });

  final NnuOfficialSupportIdentity identity;
  final bool fullControl;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xffe5eef7) : const Color(0xff1e344b);
    final muted = dark ? const Color(0xffa6bacb) : const Color(0xff5b7083);
    final line = dark ? const Color(0xff445965) : const Color(0xffcfdee9);
    final radius = BorderRadius.circular(24);
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return TweenAnimationBuilder<double>(
      duration:
          reduceMotion ? Duration.zero : const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      tween: Tween(begin: 0, end: 1),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - value)),
          child: Transform.scale(scale: .982 + value * .018, child: child),
        ),
      ),
      child: NnuRequestWaves(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-.88, -1.15),
                    radius: 1.5,
                    colors: dark
                        ? const [Color(0xff2c3e4d), Color(0xff233442)]
                        : const [Color(0xfff9fcff), Color(0xffe2edf6)],
                  ),
                ),
              ),
              BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: dark
                          ? const Color(0x2ed4e7f3)
                          : const Color(0xfff9fcff),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: dark
                          ? const [Color(0xa72c3e4d), Color(0xa6233442)]
                          : const [Color(0xc7f9fcff), Color(0xa9edf4fa)],
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      padding: const EdgeInsets.all(22),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: (constraints.maxHeight - 44)
                              .clamp(0, double.infinity)
                              .toDouble(),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            NnuOfficialSupportIdentityRow(
                              identity,
                              showIntroduction: false,
                              nameColor: ink,
                              style: TextStyle(
                                color: muted,
                                fontSize: 13,
                                height: 1.55,
                              ),
                            ),
                            Divider(height: 29, color: line),
                            Text(
                              translate('Remote assistance request'),
                              style: nnuOfficialSupportTypography.copyWith(
                                color: ink,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Icon(Icons.lock_outline,
                                    size: 15, color: muted),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    translate(fullControl
                                        ? 'Accepting grants full remote control'
                                        : 'Accepting grants access within this device policy'),
                                    style:
                                        nnuOfficialSupportTypography.copyWith(
                                      color: muted,
                                      fontSize: 13,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: onReject,
                                    style: OutlinedButton.styleFrom(
                                      enabledMouseCursor: SystemMouseCursors.click,
                                      textStyle: nnuOfficialSupportTypography
                                          .copyWith(fontSize: 13),
                                      minimumSize: const Size(0, 43),
                                      foregroundColor: dark
                                          ? const Color(0xffd0dde8)
                                          : const Color(0xff4e6172),
                                      backgroundColor: dark
                                          ? const Color(0xff304553)
                                          : const Color(0xfff7f9fb),
                                      side: BorderSide(color: line),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                    ),
                                    child: Text(
                                        translate('Reject remote request')),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: FilledButton(
                                    onPressed: onAccept,
                                    style: FilledButton.styleFrom(
                                      enabledMouseCursor: SystemMouseCursors.click,
                                      textStyle: nnuOfficialSupportTypography
                                          .copyWith(fontSize: 13),
                                      minimumSize: const Size(0, 43),
                                      backgroundColor: const Color(0xff245bb2),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                    ),
                                    child: Text(
                                        translate('Accept remote request')),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      )),
    );
  }
}
