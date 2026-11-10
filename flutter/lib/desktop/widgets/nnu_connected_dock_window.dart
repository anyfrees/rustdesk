import 'dart:math' as math;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;

import '../../models/platform_model.dart';
import 'nnu_dock_message.dart';

const _positionKey = 'nnu-connected-dock-position';
const nnuDockCompactSize = Size(86, 86);
const nnuDockCardSize = Size(342, 244);

class NnuDockPlacement {
  NnuDockPlacement(this.workArea, double heightFraction)
      : compact = _compact(workArea, heightFraction);

  final Rect workArea;
  final Rect compact;

  static Rect logicalWorkArea(Rect physicalArea, double scale) => Rect.fromLTRB(
        physicalArea.left / scale,
        physicalArea.top / scale,
        physicalArea.right / scale,
        physicalArea.bottom / scale,
      );

  static Rect physicalBounds(Rect logicalArea, double scale) => Rect.fromLTRB(
        logicalArea.left * scale,
        logicalArea.top * scale,
        logicalArea.right * scale,
        logicalArea.bottom * scale,
      );

  static Rect _compact(Rect area, double fraction) {
    final centerY = area.top + area.height * fraction.clamp(0.0, 1.0);
    final top = (centerY - nnuDockCompactSize.height / 2)
        .clamp(area.top,
            math.max(area.top, area.bottom - nnuDockCompactSize.height))
        .toDouble();
    return Rect.fromLTWH(
      math.max(area.left, area.right - nnuDockCompactSize.width - 4),
      top,
      nnuDockCompactSize.width,
      nnuDockCompactSize.height,
    );
  }

  Rect get expanded {
    final width = math.min(nnuDockCardSize.width, workArea.width);
    final height = math.min(nnuDockCardSize.height, workArea.height);
    final top = (compact.center.dy - 79)
        .clamp(workArea.top, math.max(workArea.top, workArea.bottom - height))
        .toDouble();
    return Rect.fromLTWH(
      math.max(workArea.left, compact.right - width),
      top,
      width,
      height,
    );
  }

  Offset get avatarInExpanded => compact.center - expanded.topLeft;
}

final nnuConnectedDockWindow = NnuConnectedDockWindow();

Future<void> _syncTrustedShape(int mode) async {
  if (Platform.isWindows) {
    await const MethodChannel('org.rustdesk.rustdesk/host')
        .invokeMethod<void>('setTrustedWindowShape', mode);
  }
}

class NnuConnectedDockWindow {
  int _connectionCount = 1;
  Future<void> setConnectionCount(int count) async {
    count = count < 1 ? 1 : count;
    if (_connectionCount == count) return;
    _connectionCount = count;
    if (Platform.isWindows) {
      await const MethodChannel('org.rustdesk.rustdesk/host')
          .invokeMethod<void>('setTrustedDockConnections', count);
    }
  }
  NnuDockPlacement? _placement;
  NnuDockMessagePlacement? _message;
  bool _expanded = false;
  bool get hasMessage => _message != null;
  bool get messageOnLeft => _message?.onLeft ?? true;
  double get messageBubbleHeight => _message?.bubbleHeight ?? 76;
  double get messageMaxWidth {
    final placement = _placement;
    return placement == null ? 260 :
        NnuDockMessagePlacement(placement.workArea, placement.compact).bounds.width - 94;
  }
  Offset? get avatarInExpanded => _placement?.avatarInExpanded;

  Future<void> centerRequest(Size preferred) async {
    final current = await windowManager.getBounds();
    final area = await _workArea(current.center);
    await windowManager.setBounds(Rect.fromCenter(
      center: area.center,
      width: math.min(preferred.width, area.width),
      height: math.min(preferred.height, area.height),
    ));
    await _syncTrustedShape(1);
  }

  Future<void> enter() async {
    final native = Platform.isWindows ? await window_size.getWindowInfo() : null;
    final scale = native?.scaleFactor ?? 1.0;
    final current = native == null
        ? await windowManager.getBounds()
        : NnuDockPlacement.logicalWorkArea(native.frame, scale);
    final saved = bind.getLocalFlutterOption(k: _positionKey).split(',');
    final values = saved.map(double.tryParse).toList();
    final hasPosition = values.length == 3 &&
        values.every((value) => value != null && value.isFinite);
    final center =
        hasPosition ? Offset(values[0]!, values[1]!) : current.center;
    final area = await _workArea(center, scale: scale);
    final savedScreen = hasPosition && area.contains(center);
    final placement = NnuDockPlacement(area, savedScreen ? values[2]! : .48);
    await windowManager.setBounds(
      Platform.isWindows
          ? NnuDockPlacement.physicalBounds(placement.compact, scale)
          : placement.compact,
      ignoreDevicePixelRatio: Platform.isWindows,
    );
    await _syncTrustedShape(2);
    _placement = placement;
    _message = null;
    _expanded = false;
  }

  Future<void> resize({required bool expanded}) async {
    final placement = _placement;
    if (placement != null) {
      await windowManager
          .setBounds(expanded ? placement.expanded : placement.compact);
      await _syncTrustedShape(expanded ? 3 : 2);
      _message = null;
      _expanded = expanded;
    }
  }

  Future<bool> finish(Size preferred, {int shape = 1, required bool reducedMotion,
      required bool Function() stillCurrent}) async {
    final current = await windowManager.getBounds();
    final center = _message != null
        ? Offset(_message!.onLeft ? current.right - 43 : current.left + 43,
            current.center.dy)
        : _expanded ? current.topLeft + const Offset(48, 48) : current.center;
    final area = await _workArea(center);
    final compact = Rect.fromCenter(center: center,
      width: nnuDockCompactSize.width, height: nnuDockCompactSize.height);
    await windowManager.setBounds(compact);
    await _syncTrustedShape(2);
    _message = null;
    _expanded = false;
    if (!reducedMotion) {
      final clock = Stopwatch()..start();
      while (clock.elapsedMilliseconds < 380) {
        if (!stillCurrent()) return false;
        final progress = Curves.easeInOutCubic.transform(
            (clock.elapsedMilliseconds / 380).clamp(0, 1));
        await windowManager.setPosition(Offset.lerp(compact.topLeft,
          area.center - nnuDockCompactSize.center(Offset.zero), progress)!);
        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
      }
    }
    if (!stillCurrent()) return false;
    await windowManager.setBounds(Rect.fromCenter(center: area.center,
      width: math.min(preferred.width, area.width),
      height: math.min(preferred.height, area.height)));
    await _syncTrustedShape(shape);
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    return stillCurrent();
  }

  Future<bool> showMessage(Size size) async {
    final placement = _placement;
    if (placement == null) return false;
    final message = NnuDockMessagePlacement(placement.workArea, placement.compact, size);
    if (!message.canShow) return false;
    _message = message;
    await windowManager.setBounds(message.bounds);
    if (Platform.isWindows) {
      await const MethodChannel('org.rustdesk.rustdesk/host').invokeMethod<void>(
          'setTrustedMessageShape', {'mode': message.onLeft ? 4 : 5,
            'height': message.bubbleHeight});
    }
    return true;
  }

  Future<void> move(Offset grabOffset) async {
    final cursor = await screenRetriever.getCursorScreenPoint();
    await windowManager.setPosition(cursor - grabOffset);
  }

  Future<void> snap() async {
    final bounds = await windowManager.getBounds();
    final center = _message == null ? bounds.center : Offset(
        _message!.onLeft ? bounds.right - 43 : bounds.left + 43, bounds.center.dy);
    final area = await _workArea(center);
    final fraction = ((bounds.center.dy - area.top) / area.height)
        .clamp(0.0, 1.0)
        .toDouble();
    final placement = NnuDockPlacement(area, fraction);
    await windowManager.setBounds(placement.compact);
    if (_message != null) {
      await _syncTrustedShape(2);
      _message = null;
    }
    _placement = placement;
    try {
      await bind.setLocalFlutterOption(
        k: _positionKey,
        v: '${area.center.dx},${area.center.dy},$fraction',
      );
    } catch (error) {
      debugPrint('Could not save trusted dock position: $error');
    }
  }

  Future<Rect> _workArea(Offset center, {double? scale}) async {
    final screens = await window_size.getScreenList();
    scale ??= Platform.isWindows ? windowManager.getDevicePixelRatio() : 1.0;
    Rect? nearest;
    var distance = double.infinity;
    for (final screen in screens) {
      final area = NnuDockPlacement.logicalWorkArea(screen.visibleFrame, scale);
      if (area.isEmpty) continue;
      if (area.contains(center)) return area;
      final closest = Offset(
        center.dx.clamp(area.left, area.right).toDouble(),
        center.dy.clamp(area.top, area.bottom).toDouble(),
      );
      final candidate = (closest - center).distanceSquared;
      if (candidate < distance) {
        distance = candidate;
        nearest = area;
      }
    }
    if (nearest != null) return nearest;
    final primary = await screenRetriever.getPrimaryDisplay();
    return (primary.visiblePosition ?? Offset.zero) &
        (primary.visibleSize ?? primary.size);
  }
}
