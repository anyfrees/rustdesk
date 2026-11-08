import 'package:flutter/material.dart';

class NnuSettingsRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? hint;

  const NnuSettingsRow(
      {super.key,
      required this.label,
      required this.value,
      required this.onChanged,
      this.hint});

  @override
  Widget build(BuildContext context) {
    final active = onChanged != null;
    final row = MergeSemantics(
        child: GestureDetector(
      onTap: active ? () => onChanged!(!value) : null,
      child: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: Row(children: [
            Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Checkbox(
                  value: value,
                  onChanged: active
                      ? (next) {
                          if (next != null) onChanged!(next);
                        }
                      : null,
                )),
            Expanded(
                child: Text(label,
                    style: TextStyle(
                        color: active
                            ? null
                            : Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.color
                                ?.withOpacity(0.6)))),
          ])),
    ));
    return hint == null ? row : Tooltip(message: hint!, child: row);
  }
}
