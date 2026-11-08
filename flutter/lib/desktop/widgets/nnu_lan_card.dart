import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const nnuDefaultDirectPort = 21118;

String nnuLanEndpoint(String ip, int port) => port == nnuDefaultDirectPort
    ? ip
    : '${ip.contains(':') ? '[$ip]' : ip}:$port';

class NnuLanCard extends StatelessWidget {
  final bool enabled;
  final bool stopped;
  final int port;
  final List<String> addresses;

  const NnuLanCard(
      {super.key,
      required this.enabled,
      this.stopped = false,
      this.port = nnuDefaultDirectPort,
      required this.addresses});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = enabled && !stopped;
    final caption = !enabled
        ? '已关闭，可在安全设置中开启'
        : stopped
            ? '服务已停止，暂不可连接'
            : '';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor.withOpacity(0.18)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.lan_outlined,
              size: 16,
              color: active ? theme.colorScheme.primary : theme.disabledColor),
          const SizedBox(width: 6),
          Expanded(
              child: Text('局域网连接',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 8),
        if (!active)
          Text(caption,
              style:
                  theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))
        else if (addresses.isEmpty)
          Text('未检测到局域网 IPv4 地址', style: theme.textTheme.bodySmall)
        else
          for (final ip in addresses)
            Tooltip(
              message: '复制连接地址',
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () async {
                  await Clipboard.setData(
                      ClipboardData(text: nnuLanEndpoint(ip, port)));
                  if (context.mounted) {
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        const SnackBar(
                            content: Text('连接地址已复制'),
                            duration: Duration(seconds: 2)));
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Text(nnuLanEndpoint(ip, port),
                      softWrap: true,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(fontWeight: FontWeight.w500)),
                ),
              ),
            ),
      ]),
    );
  }
}
