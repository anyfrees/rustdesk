import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/server_model.dart';
import 'nnu_official_support_badge.dart';
import 'nnu_official_support_text.dart';

class NnuOfficialSupportIdentityRow extends StatelessWidget {
  const NnuOfficialSupportIdentityRow(
    this.identity, {
    super.key,
    this.style,
    this.nameColor,
    this.showIntroduction = true,
  });

  final NnuOfficialSupportIdentity identity;
  final TextStyle? style;
  final Color? nameColor;
  final bool showIntroduction;

  @override
  Widget build(BuildContext context) {
    final verified = translate('Officially verified');
    final name = identity.accountName.isEmpty
        ? identity.displayName
        : identity.accountName;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        NnuOfficialSupportAvatar(name: name, jpeg: identity.avatarJpeg),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NnuOfficialSupportNameLine(identity, verifiedLabel: verified,
                  nameColor: nameColor),
              if (showIntroduction) ...[
                const SizedBox(height: 4),
                NnuOfficialSupportText(
                  identity.introduction,
                  style: nnuOfficialSupportTypography.merge(style),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class NnuOfficialSupportNameLine extends StatelessWidget {
  const NnuOfficialSupportNameLine(this.identity, {super.key,
    required this.verifiedLabel, this.nameColor, this.fontSize = 17});
  final NnuOfficialSupportIdentity identity;
  final String verifiedLabel;
  final Color? nameColor;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final name = identity.accountName.isEmpty ? identity.displayName : identity.accountName;
    return LayoutBuilder(builder: (context, constraints) => Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
            textWidthBasis: TextWidthBasis.longestLine,
            textHeightBehavior: const TextHeightBehavior(
              applyHeightToFirstAscent: false, applyHeightToLastDescent: false),
            style: nnuOfficialSupportTypography.copyWith(color: nameColor,
              fontSize: fontSize, fontWeight: FontWeight.w700, height: 1.15))),
        const SizedBox(width: 8),
        ConstrainedBox(constraints: BoxConstraints(
          maxWidth: (constraints.maxWidth * .5).clamp(32, 160)),
          child: NnuOfficialSupportBadge(badgeColor: identity.badgeColor,
            displayName: identity.displayName, introduction: identity.introduction,
            verifiedLabel: verifiedLabel, compact: true,
            alignment: AlignmentDirectional.centerStart)),
      ],
    ));
  }
}

class NnuOfficialSupportAvatar extends StatelessWidget {
  const NnuOfficialSupportAvatar({
    super.key,
    required this.name,
    required this.jpeg,
  });

  final String name;
  final String jpeg;

  Uint8List? _decode() {
    if (jpeg.isEmpty) return null;
    try {
      final bytes = base64Decode(jpeg);
      return bytes.length > 3 && bytes[0] == 0xff && bytes[1] == 0xd8
          ? bytes
          : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: colors.primaryContainer,
      child: Center(
        child: Text(
          name.characters.first,
          style: nnuOfficialSupportTypography.copyWith(
            fontWeight: FontWeight.w700,
            fontSize: 18,
            color: colors.onPrimaryContainer,
          ),
        ),
      ),
    );
    final bytes = _decode();
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: colors.outline.withOpacity(.25)),
      ),
      padding: const EdgeInsets.all(2),
      child: ClipOval(
        child: bytes == null
            ? fallback
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}
