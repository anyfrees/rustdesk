import 'package:flutter/material.dart';

import '../../models/server_model.dart';
import 'nnu_official_support_badge.dart';
import 'nnu_official_support_identity_row.dart';
import 'nnu_official_support_text.dart';

class NnuOfficialSupportProfile extends StatelessWidget {
  const NnuOfficialSupportProfile(
    this.identity, {
    super.key,
    required this.peerId,
    this.status,
    this.trailing,
  });

  final NnuOfficialSupportIdentity identity;
  final String peerId;
  final Widget? status;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.background,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.08),
            spreadRadius: 1,
            blurRadius: 1,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: NnuOfficialSupportIdentityRow(
                  identity,
                  nameColor: theme.colorScheme.onSurface,
                  showIntroduction: false,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 4),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: 6),
          NnuOfficialSupportText(
            'ID  $peerId',
            maxLines: 1,
            style: theme.textTheme.bodySmall
                ?.merge(nnuOfficialSupportTypography)
                .copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(.65),
                  fontSize: 11.5,
                  height: 1.4,
                ),
          ),
          if (status != null) ...[
            const SizedBox(height: 5),
            DefaultTextStyle(
              style: (theme.textTheme.bodySmall ?? const TextStyle())
                  .merge(nnuOfficialSupportTypography)
                  .copyWith(
                    color: theme.colorScheme.onSurface,
                    fontSize: 12,
                    height: 1.4,
                  ),
              child: status!,
            ),
          ],
        ],
      ),
    );
  }
}
