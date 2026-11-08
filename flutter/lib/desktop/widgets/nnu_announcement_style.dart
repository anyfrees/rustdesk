import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'nnu_action_button.dart';
import 'nnu_announcement_model.dart';

Color nnuNoticeColor(String value, Color fallback, Color background,
    {double contrast = 4.5}) {
  if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value)) return fallback;
  final color = Color(0xff000000 | int.parse(value.substring(1), radix: 16));
  final light = color.computeLuminance(), base = background.computeLuminance();
  if ((math.max(light, base) + .05) / (math.min(light, base) + .05) >= contrast)
    return color;
  return base > .179 ? Colors.black : Colors.white;
}

TextStyle nnuNoticeTitleStyle(NnuAnnouncement notice, TextStyle base) =>
    base.copyWith(
        fontFamily: {
          'sans': 'Microsoft YaHei',
          'serif': 'SimSun',
          'mono': 'Consolas'
        }[notice.titleFont],
        fontFamilyFallback: notice.titleFont == 'serif'
            ? const ['Songti SC', 'Noto Serif CJK SC', 'serif']
            : notice.titleFont == 'mono'
                ? const ['Microsoft YaHei', 'monospace']
                : null,
        fontSize: notice.titleSize == 0 ? null : notice.titleSize.toDouble(),
        fontWeight: {
          'normal': FontWeight.w400,
          'medium': FontWeight.w500,
          'bold': FontWeight.w700
        }[notice.titleWeight]);

IconData? nnuNoticeIcon(NnuAnnouncement notice) {
  final key = notice.icon == 'auto'
      ? <String, String>{
            'clean': 'megaphone',
            'safety': 'shield',
            'capsule': 'bell',
            'editorial': 'calendar',
            'rotation': 'info',
            'obsidian': 'bell',
            'titanium': 'sparkles',
            'glass': 'sparkles',
            'frosted': 'bell',
          }[notice.theme] ??
          'megaphone'
      : notice.icon;
  return <String, IconData>{
    'megaphone': Icons.campaign_outlined,
    'shield': Icons.verified_user_outlined,
    'bell': Icons.notifications_none,
    'warning': Icons.warning_amber_rounded,
    'info': Icons.info_outline,
    'wrench': Icons.build_outlined,
    'sparkles': Icons.auto_awesome_outlined,
    'calendar': Icons.event_outlined,
    'support': Icons.support_agent,
    'network': Icons.lan_outlined
  }[key];
}

Future<void> showNnuAnnouncement(
        BuildContext context, NnuAnnouncement notice) =>
    showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(notice.title,
                  style: nnuNoticeTitleStyle(
                      notice,
                      Theme.of(context).textTheme.titleLarge!.copyWith(
                          color: MediaQuery.of(context).highContrast
                              ? null
                              : nnuNoticeColor(
                                  notice.titleColor,
                                  Theme.of(context).colorScheme.onSurface,
                                  Theme.of(context).colorScheme.surface)))),
              content: SizedBox(
                  width: 480,
                  child: SingleChildScrollView(
                      child: SelectableText(notice.body))),
              actions: [
                NnuActionButton(
                    label: '关闭', onPressed: () => Navigator.of(context).pop())
              ],
            ));

class NnuStyledAnnouncement extends StatelessWidget {
  final NnuAnnouncement notice;
  final VoidCallback onOpen;
  final Widget? controls, topics;
  final double phase;
  const NnuStyledAnnouncement(
      {super.key,
      required this.notice,
      required this.onOpen,
      this.controls,
      this.topics,
      this.phase = 1});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context), kind = notice.theme;
    final dark = theme.brightness == Brightness.dark;
    final premium = ['obsidian', 'titanium', 'glass', 'capsule'].contains(kind);
    final highContrast = MediaQuery.of(context).highContrast;
    final foreground = premium
        ? const Color(0xffedf2fa)
        : kind == 'frosted'
            ? (dark ? const Color(0xffecf0f5) : const Color(0xff263442))
            : theme.colorScheme.onSurface;
    final secondary = premium
        ? const Color(0xffc3cede)
        : theme.colorScheme.onSurface.withOpacity(.75);
    final accent = premium
        ? (kind == 'titanium'
            ? const Color(0xffe2d9c2)
            : const Color(0xffacd8ff))
        : kind == 'safety'
            ? (dark ? const Color(0xffffca78) : const Color(0xff85510b))
            : kind == 'editorial'
                ? (dark ? const Color(0xff85d5b6) : const Color(0xff26785b))
                : theme.colorScheme.primary;
    final background = kind == 'frosted'
        ? (dark ? const Color(0xf02d3641) : const Color(0xf0e6ebf0))
        : premium
            ? (kind == 'capsule'
                ? const Color(0xff213b60)
                : kind == 'glass'
                    ? const Color(0xe8172434)
                    : const Color(0xff11151b))
            : kind == 'safety'
                ? (dark ? const Color(0xff352c1f) : const Color(0xfffff6e7))
                : Color.alphaBlend(theme.colorScheme.primary.withOpacity(.045),
                    theme.scaffoldBackgroundColor);
    final titleColor = highContrast
        ? accent
        : nnuNoticeColor(notice.titleColor, accent, background);
    final iconColor = highContrast
        ? accent
        : nnuNoticeColor(notice.iconColor, accent, background, contrast: 3);
    final radius = BorderRadius.circular(9);
    final iconData = nnuNoticeIcon(notice);
    Widget? leading;
    if (iconData != null) {
      final motion = notice.effectiveMotion;
      final wave = math.sin(phase * math.pi * 4) * (1 - phase);
      leading = Transform.rotate(
          angle: motion == 'sway' ? wave * .16 : 0,
          child: Transform.scale(
              scale: motion == 'breathe'
                  ? 1 + math.sin(phase * math.pi * 2).abs() * .12
                  : 1,
              child: Icon(iconData, size: 20, color: iconColor)));
      if (['safety', 'capsule', 'glass'].contains(kind)) {
        leading = Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: accent.withOpacity(.09),
                borderRadius: BorderRadius.circular(kind == 'safety' ? 9 : 18),
                border: kind == 'glass'
                    ? Border.all(color: accent.withOpacity(.23))
                    : null),
            child: leading);
      }
    }
    final textStyle =
        theme.textTheme.bodySmall?.copyWith(color: foreground, height: 1.3);
    Widget copy;
    if ((controls != null && topics == null) ||
        kind == 'clean' || kind == 'capsule' || kind == 'obsidian') {
      copy = notice.hasCustomTitle
          ? Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: notice.title.trim(),
                    style: nnuNoticeTitleStyle(
                        notice, textStyle!.copyWith(color: titleColor))),
                TextSpan(
                    text:
                        ' ${notice.body.trim().replaceAll(RegExp(r'\s+'), ' ')}')
              ]),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textStyle)
          : Text(notice.summary,
              maxLines: 2, overflow: TextOverflow.ellipsis, style: textStyle);
    } else {
      copy = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (kind == 'rotation' && topics != null)
              topics!
            else
              Text(notice.title.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nnuNoticeTitleStyle(
                      notice,
                      textStyle!.copyWith(
                          color: titleColor, fontWeight: FontWeight.w600))),
            const SizedBox(height: 4),
            Text(
                kind == 'rotation'
                    ? notice.summary
                    : notice.body.trim().replaceAll(RegExp(r'\s+'), ' '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textStyle?.copyWith(color: secondary)),
          ]);
    }
    final row = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          if (leading != null) ...[
            InkWell(onTap: onOpen, child: leading),
            const SizedBox(width: 10)
          ],
          Expanded(
              child: InkWell(
                  onTap: onOpen,
                  borderRadius: BorderRadius.circular(4),
                  child:
                      Semantics(button: true, label: '查看公告全文', child: copy))),
          const SizedBox(width: 6),
          if (controls != null)
            IconTheme(data: IconThemeData(color: accent), child: controls!)
          else
            IconButton(
                onPressed: onOpen,
                tooltip: '查看公告全文',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
                icon: Icon(Icons.chevron_right, size: 18, color: accent)),
        ]));
    Widget surface;
    if (kind == 'frosted') {
      Widget inner = Container(
          decoration: BoxDecoration(
              color: highContrast ? background.withAlpha(255) : background,
              borderRadius: radius,
              border: Border.all(
                  color:
                      dark ? const Color(0xff56616f) : const Color(0xffc1ccd6)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(.06),
                    blurRadius: 6,
                    offset: const Offset(0, 2))
              ]),
          child: row);
      if (!highContrast)
        inner = BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: inner);
      surface = ClipRRect(borderRadius: radius, child: inner);
    } else if (kind == 'titanium' || kind == 'glass') {
      final edge = kind == 'glass'
          ? [
              const Color(0xcce5f6ff),
              const Color(0x558ebee5),
              const Color(0x33e6f5ff)
            ]
          : [
              const Color(0xffa5a29a),
              const Color(0xff45484e),
              const Color(0xff777971)
            ];
      Widget inner = DecoratedBox(
          decoration: BoxDecoration(
              color: kind == 'glass' && !highContrast ? background : null,
              gradient: kind == 'titanium'
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xff272b30), Color(0xff101216)])
                  : null,
              borderRadius: radius,
              border: Border.all(color: Colors.white.withOpacity(.075))),
          child: row);
      if (kind == 'glass') {
        if (highContrast) {
          inner = ColoredBox(color: const Color(0xff111923), child: inner);
        } else {
          inner = BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: inner);
        }
      }
      surface = DecoratedBox(
          decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: edge),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(.16),
                    blurRadius: 12,
                    offset: const Offset(0, 4))
              ]),
          child: Padding(
              padding: const EdgeInsets.all(1.2),
              child: ClipRRect(borderRadius: radius, child: inner)));
    } else {
      surface = Container(
          decoration: BoxDecoration(
              color: background,
              borderRadius: radius,
              border: kind == 'safety' || kind == 'editorial'
                      ? Border.all(color: accent.withOpacity(.42))
                      : Border.all(
                          color: premium
                              ? const Color(0xff394250)
                              : theme.dividerColor.withOpacity(.2)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(dark ? .12 : .04),
                    blurRadius: 6,
                    offset: const Offset(0, 2))
              ]),
          child: row);
    }
    return Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
        child: Material(type: MaterialType.transparency, child: surface));
  }
}
