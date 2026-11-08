import 'package:flutter/material.dart';

class NnuActionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool outlined;
  final Color? disabledForegroundColor;

  const NnuActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.outlined = false,
    this.disabledForegroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        alignment: Alignment.center,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.standard,
        minimumSize: const Size(80, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        foregroundColor:
            primary ? Theme.of(context).colorScheme.onPrimary : color,
        disabledForegroundColor: disabledForegroundColor,
        backgroundColor: primary
            ? color
            : outlined
                ? color.withOpacity(0.04)
                : null,
        side: outlined ? BorderSide(color: color.withOpacity(0.24)) : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          height: 1.2,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
      child: Text(label, textAlign: TextAlign.center),
    );
  }
}
