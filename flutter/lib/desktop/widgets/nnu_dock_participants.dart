import 'package:flutter/material.dart';

class NnuDockParticipantColors {
  static const palette = [
    Color(0xff52d890),
    Color(0xff439ce8),
    Color(0xffb287df),
    Color(0xffe3a23f),
    Color(0xffdf819d),
    Color(0xff43b8c4),
    Color(0xffa1b84c),
    Color(0xffd98965),
  ];
  final _slots = <int, int>{};

  void retain(Iterable<int> ids) {
    final active = ids.toSet();
    _slots.removeWhere((id, _) => !active.contains(id));
    for (final id in active) {
      colorFor(id);
    }
  }

  Color colorFor(int id) => palette[_slots.putIfAbsent(id, () {
        for (var slot = 0; slot < palette.length; slot++) {
          if (!_slots.containsValue(slot)) return slot;
        }
        return id.abs() % palette.length;
      })];
}

class NnuDockNotice {
  const NnuDockNotice(this.connectionId, this.token, this.text);
  final int connectionId;
  final Object token;
  final String text;
}

class NnuDockMessageQueue {
  final _pending = <NnuDockNotice>[];
  final _seen = <int, Object>{};
  bool get isNotEmpty => _pending.isNotEmpty;

  void markSeen(int connectionId, Object token) => _seen[connectionId] = token;

  void add(NnuDockNotice notice) {
    if (identical(_seen[notice.connectionId], notice.token)) return;
    _seen[notice.connectionId] = notice.token;
    // Chat history retains every message; limit only notification previews.
    if (_pending.length >= 24) _pending.removeAt(0);
    _pending.add(notice);
  }

  void retry(NnuDockNotice notice) {
    if (_pending.length >= 24) _pending.removeLast();
    _pending.insert(0, notice);
  }

  NnuDockNotice? take(Set<int> connected) {
    _seen.removeWhere((id, _) => !connected.contains(id));
    while (_pending.isNotEmpty) {
      final notice = _pending.removeAt(0);
      if (connected.contains(notice.connectionId)) return notice;
    }
    return null;
  }
}

class NnuParticipantWave extends CustomPainter {
  NnuParticipantWave(this.animation, this.color, {this.phase = 0})
      : super(repaint: animation);
  final Animation<double> animation;
  final Color color;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final radius = size.shortestSide / 2;
    for (final delay in [0.0, .5]) {
      final t = (animation.value + phase + delay) % 1;
      paint.color = color.withOpacity(.65 * (1 - t));
      canvas.drawCircle(
          size.center(Offset.zero), radius * (.8 + .19 * t), paint);
    }
  }

  @override
  bool shouldRepaint(NnuParticipantWave oldDelegate) =>
      oldDelegate.animation != animation ||
      oldDelegate.color != color ||
      oldDelegate.phase != phase;
}
