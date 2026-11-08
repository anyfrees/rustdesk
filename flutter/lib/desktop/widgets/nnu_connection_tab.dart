import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/model.dart';

String nnuConnectionRouteLabel(String label) =>
    const {
      '直接连接': '直连',
      '中继连接': '中继',
      'Direct connection': 'Direct',
      'Relay connection': 'Relay',
      'Direct Connection': 'Direct',
      'Relay Connection': 'Relay',
    }[label] ??
    label;

class NnuConnectionTab extends StatelessWidget {
  final String remoteId;
  final String deviceName;
  final bool direct;
  final String routeLabel;
  final String delayLabel;
  final String networkLabel;
  final String unmeasuredLabel;
  final List<String> qualityLabels;
  final String connectionDetails;
  final QualityMonitorModel quality;
  final Widget leading;
  final Widget securityIcon;
  final Widget trailing;

  const NnuConnectionTab({
    super.key,
    required this.remoteId,
    required this.deviceName,
    required this.direct,
    required this.routeLabel,
    required this.delayLabel,
    required this.networkLabel,
    required this.unmeasuredLabel,
    required this.qualityLabels,
    required this.connectionDetails,
    required this.quality,
    required this.leading,
    required this.securityIcon,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final routeColor = direct
        ? (dark ? const Color(0xff82d6a5) : const Color(0xff237b4a))
        : (dark ? const Color(0xff94bdf4) : const Color(0xff2866b1));
    final muted = theme.colorScheme.onSurfaceVariant;
    return MediaQuery.withClampedTextScaling(
      // The existing desktop title bar is 28 logical pixels high.
      maxScaleFactor: 1.35,
      child: AnimatedBuilder(
        animation: quality,
        builder: (context, child) {
          final delay = int.tryParse(quality.data.delay?.trim() ?? '');
          final latency = delay == null || delay < 0
              ? '—'
              : delay == 0
                  ? '<1'
                  : '$delay';
          final latencyColor = delay == null || delay < 0
              ? muted
              : delay <= 80
                  ? (dark ? const Color(0xff82d6a5) : const Color(0xff237b4a))
                  : delay <= 180
                      ? (dark
                          ? const Color(0xffedc773)
                          : const Color(0xff946311))
                      : (dark
                          ? const Color(0xfff1a3a3)
                          : const Color(0xffbd4949));
          final detail = '${deviceName.isEmpty ? remoteId : deviceName}\n'
              '$connectionDetails\n$delayLabel: $latency ms\n$networkLabel: '
              '${delay == null || delay < 0 ? unmeasuredLabel : qualityLabels[delay <= 20 ? 0 : delay <= 50 ? 1 : delay <= 80 ? 2 : delay <= 120 ? 3 : delay <= 180 ? 4 : 5]}';
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (MediaQuery.sizeOf(context).width - 90).clamp(240, 420),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (MediaQuery.sizeOf(context).width >= 480) leading,
                Tooltip(
                  message: detail,
                  child: MediaQuery.withClampedTextScaling(
                    maxScaleFactor: 1.35,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        securityIcon,
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 72),
                          child: Text(routeLabel,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  height: 1.15,
                                  fontWeight: FontWeight.w500,
                                  color: routeColor)),
                        ),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 41),
                          child: AnimatedDefaultTextStyle(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 180),
                            style: TextStyle(
                                fontSize: 11,
                                height: 1.15,
                                fontWeight: FontWeight.w500,
                                color: latencyColor,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ]),
                            child: Text.rich(
                              TextSpan(text: latency, children: [
                                TextSpan(
                                    text: ' ms',
                                    style:
                                        TextStyle(fontSize: 10, color: muted)),
                              ]),
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  child: SizedBox(
                    width: 1,
                    height: 13,
                    child: ColoredBox(color: theme.dividerColor),
                  ),
                ),
                Flexible(
                  child: Tooltip(
                    message:
                        '$remoteId${deviceName.isEmpty || deviceName == remoteId ? '' : '\n$deviceName'}',
                    child: Text(remoteId,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.1,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ),
                ),
                trailing,
              ],
            ),
          );
        },
      ),
    );
  }
}
