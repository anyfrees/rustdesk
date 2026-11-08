import 'package:flutter/material.dart';

import 'nnu_action_button.dart';

class NnuUpdateFooter extends StatelessWidget {
  const NnuUpdateFooter({
    super.key,
    required this.label,
    required this.onPressed,
    this.status,
    this.progress,
    this.working = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final String? status;
  final double? progress;
  final bool working;

  @override
  Widget build(BuildContext context) {
    if (!working) {
      return NnuActionButton(
        outlined: true,
        label: status ?? label,
        onPressed: onPressed,
      );
    }

    final colors = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final value = progress;
    final percent = value == null ? null : (value * 100 + 1e-7).floor();
    return Semantics(
      liveRegion: value == null,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: value == null
                      ? LinearProgressIndicator(
                          value: reduceMotion ? 0 : null,
                          color: colors.primary.withOpacity(.22),
                          backgroundColor: colors.primary.withOpacity(.05),
                        )
                      : TweenAnimationBuilder<double>(
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 160),
                          curve: Curves.easeOutCubic,
                          tween: Tween(end: value),
                          builder: (context, paintedProgress, _) =>
                              LinearProgressIndicator(
                            value: paintedProgress,
                            color: colors.primary.withOpacity(.22),
                            backgroundColor: colors.primary.withOpacity(.05),
                          ),
                        ),
                ),
              ),
            ),
          ),
          NnuActionButton(
            outlined: true,
            label: percent == null ? (status ?? label) : '${status ?? label} $percent%',
            onPressed: null,
            disabledForegroundColor: colors.onSurface,
          ),
        ],
      ),
    );
  }
}
