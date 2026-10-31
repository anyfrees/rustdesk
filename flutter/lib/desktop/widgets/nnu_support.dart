import 'package:flutter/material.dart';

const nnuSupportTitle = 'IT技术支持专用版本，请勿共享给他人使用。';
const nnuNoticeSeenOption = 'nnu-first-use-notice-seen';

class NnuSupportTitle extends StatelessWidget {
  const NnuSupportTitle({super.key});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: nnuSupportTitle,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 12),
        child: Text(
          nnuSupportTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
        ),
      ),
    );
  }
}

class NnuSupportFooter extends StatelessWidget {
  final Widget? status;
  final bool showNotice;
  final VoidCallback onDismissNotice;
  final VoidCallback onOpenSupport;

  const NnuSupportFooter({
    super.key,
    this.status,
    required this.showNotice,
    required this.onDismissNotice,
    required this.onOpenSupport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1),
        if (showNotice)
          Container(
            color: theme.colorScheme.primary.withOpacity(0.06),
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 10),
                  child: Icon(Icons.info_outline,
                      size: 18, color: theme.colorScheme.primary),
                ),
                Expanded(
                  child: Text.rich(
                    const TextSpan(children: [
                      TextSpan(
                        text: '首次使用提示\n',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: '将本机 ID 发给信任的 IT。便携版可能启用预设密码，可在“设置 → 安全”中修改或清除。',
                      ),
                    ]),
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ),
                TextButton(
                  onPressed: onDismissNotice,
                  child: const Text('知道了'),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: LayoutBuilder(builder: (context, constraints) {
            final link = TextButton(
              onPressed: onOpenSupport,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 42),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                foregroundColor: theme.colorScheme.primary,
              ),
              child:
                  const Text('nnu.cn 提供服务支持', style: TextStyle(fontSize: 12)),
            );
            if (constraints.maxWidth < 480 ||
                MediaQuery.textScalerOf(context).scale(12) > 18) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (status != null) status!,
                  Align(alignment: Alignment.centerRight, child: link),
                ],
              );
            }
            return Row(children: [
              Expanded(child: status ?? const SizedBox.shrink()),
              link,
            ]);
          }),
        ),
      ],
    );
  }
}
