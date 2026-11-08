import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'nnu_announcement_model.dart';
import 'nnu_announcement_style.dart';

class NnuAnnouncementCarousel extends StatefulWidget {
  final List<NnuAnnouncement> notices;
  final int intervalSeconds;
  const NnuAnnouncementCarousel(
      {super.key, required this.notices, this.intervalSeconds = 8});
  @override
  State<NnuAnnouncementCarousel> createState() =>
      _NnuAnnouncementCarouselState();
}

class _NnuAnnouncementCarouselState extends State<NnuAnnouncementCarousel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;
  Timer? _timer;
  int _index = 0;
  bool _paused = false, _hovered = false, _focused = false, _dialogOpen = false;
  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600), value: 1);
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    if (widget.notices.length > 1) {
      _timer = Timer.periodic(Duration(seconds: widget.intervalSeconds), (_) {
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        if (!mounted ||
            _paused ||
            _hovered ||
            _focused ||
            _dialogOpen ||
            !TickerMode.of(context) ||
            (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
          return;
        }
        _select((_index + 1) % widget.notices.length, restart: false);
      });
    }
  }

  @override
  void didUpdateWidget(covariant NnuAnnouncementCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final id = oldWidget.notices.isEmpty
        ? null
        : oldWidget.notices[math.min(_index, oldWidget.notices.length - 1)].id;
    final found = widget.notices.indexWhere((item) => item.id == id);
    _index = found < 0 ? 0 : found;
    _restart();
  }

  void _select(int index, {bool restart = true}) {
    setState(() => _index = index);
    if (MediaQuery.of(context).disableAnimations ||
        widget.notices[_index].effectiveMotion == 'none') {
      _animation.stop();
      _animation.value = 1;
    } else {
      _animation.forward(from: 0);
    }
    if (restart) {
      _restart();
    }
  }

  Future<void> _open() async {
    _dialogOpen = true;
    try {
      await showNnuAnnouncement(context, widget.notices[_index]);
    } finally {
      _dialogOpen = false;
      if (mounted) {
        _restart();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.notices.isEmpty) {
      return const SizedBox.shrink();
    }
    final notice = widget.notices[_index], multiple = widget.notices.length > 1;
    final reduced = MediaQuery.of(context).disableAnimations;
    final controls = multiple
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            Text('${_index + 1}/${widget.notices.length}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: ['capsule', 'obsidian', 'titanium', 'glass']
                            .contains(notice.theme)
                        ? const Color(0xffc3cede)
                        : Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withOpacity(.7),
                    fontSize: 11)),
            IconButton(
                onPressed: () => setState(() => _paused = !_paused),
                tooltip: _paused ? '继续轮播' : '暂停轮播',
                constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
                padding: EdgeInsets.zero,
                icon: Icon(
                    _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    size: 16)),
            IconButton(
                onPressed: () => _select((_index + 1) % widget.notices.length),
                tooltip: '下一条公告',
                constraints: const BoxConstraints(minWidth: 28, minHeight: 32),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.chevron_right, size: 18)),
          ])
        : null;
    final topics = notice.theme == 'rotation' && multiple
        ? SizedBox(
            height: widget.notices.any((item) => item.hasCustomTitle)
                ? math.max(
                    24,
                    MediaQuery.textScalerOf(context).scale(widget.notices
                                .fold<int>(
                                    10,
                                    (size, item) =>
                                        math.max(size, item.titleSize))
                                .toDouble()) *
                            1.3 +
                        8)
                : 24,
            child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (var i = 0; i < widget.notices.length; i++)
                    Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: TextButton(
                            onPressed: () => _select(i),
                            style: TextButton.styleFrom(
                                minimumSize: const Size(24, 24),
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 5),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                foregroundColor: i == _index
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).hintColor,
                                backgroundColor: i == _index
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withOpacity(.08)
                                    : null),
                            child: Text(widget.notices[i].title,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: widget.notices[i].hasCustomTitle
                                    ? nnuNoticeTitleStyle(
                                        widget.notices[i],
                                        TextStyle(
                                            fontSize: 10,
                                            color: MediaQuery.of(context).highContrast
                                                ? null
                                                : nnuNoticeColor(
                                                    widget
                                                        .notices[i].titleColor,
                                                    i == _index
                                                        ? Theme.of(context)
                                                            .colorScheme
                                                            .primary
                                                        : Theme.of(context)
                                                            .colorScheme
                                                            .onSurface,
                                                    Theme.of(context)
                                                        .scaffoldBackgroundColor)))
                                    : const TextStyle(fontSize: 10))))
                ])))
        : null;
    Widget result = AnimatedBuilder(
        animation: _animation,
        builder: (context, child) {
          final phase = reduced || notice.effectiveMotion == 'none'
              ? 1.0
              : _animation.value;
          final enter = Curves.easeOut.transform(math.min(1.0, phase * 8));
          return Opacity(
              opacity: enter,
              child: NnuStyledAnnouncement(
                  notice: notice,
                  onOpen: _open,
                  controls: controls,
                  topics: topics,
                  phase: phase));
        });
    if (multiple) {
      final hasTopics =
          widget.notices.any((notice) => notice.theme == 'rotation');
      final largestText = MediaQuery.textScalerOf(context).scale(widget.notices
          .fold<int>(14, (size, item) => math.max(size, item.titleSize))
          .toDouble());
      result = SizedBox(
          height: hasTopics
              ? 44 + largestText * 3.3
              : math.max(62, 34 + largestText * 2.6),
          width: double.infinity,
          child: result);
    }
    return Focus(
        onFocusChange: (value) => _focused = value,
        child: MouseRegion(
            onEnter: (_) => _hovered = true,
            onExit: (_) => _hovered = false,
            child: result));
  }
}
