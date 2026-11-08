import 'dart:async';
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../common/widgets/chat_page.dart';
import '../../common/widgets/nnu_official_support_badge.dart';
import '../../common/widgets/nnu_official_support_identity_row.dart';
import '../../models/server_model.dart';
import '../../models/chat_model.dart';
import 'nnu_connected_dock_window.dart';
import 'nnu_dock_message.dart';
import 'nnu_password_connection.dart';

class NnuConnectedDock extends StatefulWidget {
  const NnuConnectedDock({
    super.key,
    required this.client,
    required this.changeWindow,
    required this.runLocalAction,
    required this.allowRemoteModification,
    required this.onDisconnect,
    this.onOpenFile,
    this.onVoiceCall,
    this.exiting = false,
  });

  final Client client;
  final bool exiting;
  final Future<bool> Function(Future<void> Function()) changeWindow;
  final void Function(VoidCallback) runLocalAction;
  final bool allowRemoteModification;
  final VoidCallback onDisconnect;
  final VoidCallback? onOpenFile;
  final VoidCallback? onVoiceCall;

  @override
  State<NnuConnectedDock> createState() => _NnuConnectedDockState();
}

class _NnuConnectedDockState extends State<NnuConnectedDock>
    with TickerProviderStateMixin, WindowListener {
  late final _open = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 310),
    reverseDuration: const Duration(milliseconds: 230),
  );
  late final _wave = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );
  late final _messageMotion = AnimationController(vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 160));
  Object? _seenMessage;
  String? _messageText;
  Timer? _messageExpiry;
  bool _reducedMotion = false;
  bool _expanded = false;
  bool _dragging = false;
  bool _showChat = false;
  final _chatBlock = false.obs;
  int _transition = 0;
  Future<void>? _move;
  Offset? _grab;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    final model = gFFI.chatModel;
    final messages = model.messages[MessageKey(widget.client.peerId, widget.client.id)]?.chatMessages;
    if (messages != null && messages.isNotEmpty) _seenMessage = messages.first;
    model.addListener(_receiveMessage);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _syncWave();
  }

  @override
  void didUpdateWidget(covariant NnuConnectedDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exiting) {
      ++_transition;
      _open.stop();
      _wave.stop();
      _clock?.cancel();
    }
  }

  void _syncWave() {
    if (widget.exiting || _reducedMotion || _expanded || _dragging) {
      _wave.stop();
    } else if (!_wave.isAnimating) {
      _wave.repeat();
    }
  }

  @override
  void dispose() {
    gFFI.chatModel.removeListener(_receiveMessage);
    _messageExpiry?.cancel();
    _messageMotion.dispose();
    windowManager.removeListener(this);
    _clock?.cancel();
    _open.dispose();
    _wave.dispose();
    super.dispose();
  }

  @override
  void onWindowBlur() {
    if (_expanded && !widget.exiting) unawaited(_setExpanded(false));
  }

  Future<void> _setExpanded(bool expanded) async {
    if (widget.exiting || _expanded == expanded || _dragging) return;
    final transition = ++_transition;
    _messageExpiry?.cancel();
    _messageMotion.value = 0;
    setState(() {
      _messageText = null;
      _expanded = expanded;
      if (!expanded) _showChat = false;
    });
    _syncWave();
    try {
      if (expanded) {
        final resized = await widget
            .changeWindow(() => nnuConnectedDockWindow.resize(expanded: true));
        if (!mounted || transition != _transition) return;
        if (!resized) {
          setState(() => _expanded = false);
          _syncWave();
          return;
        }
        _clock = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
        if (_reducedMotion) {
          _open.value = 1;
        } else {
          await _open.forward().orCancel;
        }
      } else {
        _clock?.cancel();
        if (_reducedMotion) {
          _open.value = 0;
        } else {
          await _open.reverse().orCancel;
        }
        if (mounted && transition == _transition) {
          await widget.changeWindow(
              () => nnuConnectedDockWindow.resize(expanded: false));
        }
      }
    } on TickerCanceled {
      // The latest tap owns the transition.
    }
  }

  void _receiveMessage() {
    if (!widget.client.authorized) return;
    final model = gFFI.chatModel;
    final key = model.latestReceivedKey;
    if (key?.connId != widget.client.id) return;
    final messages = model.messages[key]?.chatMessages;
    if (messages == null || messages.isEmpty) return;
    final message = messages.first;
    if (identical(message, _seenMessage) || message.user.id == model.me.id) return;
    _seenMessage = message;
    if (!_expanded && !_dragging && _open.value == 0) {
      unawaited(_showMessage(message.text));
    }
  }

  Future<void> _showMessage(String text) async {
    text = text.characters.take(500).toString();
    final size = NnuDockMessageBubble.measure(context, text,
        nnuConnectedDockWindow.messageMaxWidth);
    final transition = ++_transition;
    _messageExpiry?.cancel();
    var shown = false;
    final applied = await widget.changeWindow(() async {
      if (mounted && transition == _transition && !_expanded && !_dragging) {
        shown = await nnuConnectedDockWindow.showMessage(size);
      }
    });
    if (!mounted || transition != _transition || !applied || !shown) return;
    setState(() => _messageText = text);
    if (_reducedMotion) {
      _messageMotion.value = 1;
    } else {
      _messageMotion.forward();
    }
    _messageExpiry = Timer(const Duration(seconds: 7), () => unawaited(_hideMessage()));
  }

  Future<void> _hideMessage() async {
    final transition = ++_transition;
    try {
      if (_reducedMotion) {
        _messageMotion.value = 0;
      } else {
        await _messageMotion.reverse().orCancel;
      }
      if (!mounted || transition != _transition || _expanded || _dragging) return;
      await widget.changeWindow(() async {
        if (mounted && transition == _transition) {
          await nnuConnectedDockWindow.resize(expanded: false);
        }
      });
      if (mounted && transition == _transition) setState(() => _messageText = null);
    } on TickerCanceled {
      // A newer message or the user's action owns the window.
    }
  }

  void _openMessageChat() {
    widget.runLocalAction(() async {
      await _setExpanded(true);
      if (mounted && _expanded) _openChat();
    });
  }

  void _startDrag(DragStartDetails _) {
    if (_grab == null || _expanded || _open.value != 0 || _move != null) {
      return;
    }
    setState(() => _dragging = true);
    ++_transition;
    _messageExpiry?.cancel();
    _messageMotion.value = 0;
    _messageText = null;
    _syncWave();
  }

  void _updateDrag(DragUpdateDetails _) {
    final grab = _grab;
    if (!_dragging || _move != null || grab == null) return;
    _move = widget
        .changeWindow(() => nnuConnectedDockWindow.move(grab))
        .then((_) => _move = null);
  }

  Future<void> _finishDrag() async {
    if (!_dragging) return;
    await _move;
    if (!mounted) return;
    final grab = _grab;
    _grab = null;
    await widget.changeWindow(() async {
      if (grab != null) await nnuConnectedDockWindow.move(grab);
      await nnuConnectedDockWindow.snap();
    });
    if (mounted) {
      setState(() => _dragging = false);
      _syncWave();
    }
  }

  @override
  Widget build(BuildContext context) {
    final identity = widget.client.officialSupport;
    final name = identity == null
        ? (widget.client.name.isEmpty ? widget.client.peerId : widget.client.name)
        : identity.accountName.isEmpty ? identity.displayName : identity.accountName;
    final reduced = _reducedMotion;
    return IgnorePointer(ignoring: widget.exiting, child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape &&
              _expanded) {
            unawaited(_setExpanded(false));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final center = Offset(size.width / 2, size.height / 2);
            return AnimatedBuilder(
              animation: _open,
              child: _avatar(name.isEmpty ? '?' : name, identity?.avatarJpeg ?? ''),
              builder: (context, avatar) {
                final large = _expanded || _open.value > 0;
                final origin = large
                    ? (nnuConnectedDockWindow.avatarInExpanded ?? center)
                    : nnuConnectedDockWindow.hasMessage
                        ? Offset(nnuConnectedDockWindow.messageOnLeft
                            ? size.width - 43 : 43, center.dy)
                        : center;
                final progress =
                    large ? Curves.easeOutCubic.transform(_open.value) : 0.0;
                final avatarCenter =
                    Offset.lerp(origin, const Offset(48, 48), progress)!;
                const avatarSize = 52.0;
                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    if (!large && !_dragging && _messageText != null &&
                        NnuDockMessagePlacement.hasBubbleSpace(size.width))
                      Positioned(
                        left: nnuConnectedDockWindow.messageOnLeft ? 4 : 90,
                        right: nnuConnectedDockWindow.messageOnLeft ? 90 : 4,
                        top: (size.height - nnuConnectedDockWindow.messageBubbleHeight) / 2,
                        height: nnuConnectedDockWindow.messageBubbleHeight,
                        child: NnuDockMessageBubble(
                          text: _messageText!,
                          onLeft: nnuConnectedDockWindow.messageOnLeft,
                          animation: CurveTween(curve: Curves.easeOutCubic).animate(_messageMotion),
                          onOpen: _openMessageChat,
                        ),
                      ),
                    if (large && progress > 0)
                      Positioned.fill(
                        child: IgnorePointer(
                          ignoring: !_expanded,
                          child: Opacity(
                            opacity: progress,
                            child: Transform.scale(
                              alignment: Alignment(
                                2 * origin.dx / size.width - 1,
                                2 * origin.dy / size.height - 1,
                              ),
                              scale: lerpDouble(.32, 1, progress)!,
                              child: _showChat
                                  ? _chatPane()
                                  : _card(name, identity),
                            ),
                          ),
                        ),
                      ),
                    if (!reduced && !_expanded && !_dragging)
                      Positioned(
                        left: avatarCenter.dx - 43,
                        top: avatarCenter.dy - 43,
                        width: 86,
                        height: 86,
                        child: IgnorePointer(
                          child: TweenAnimationBuilder<Color?>(
                            tween: ColorTween(end: widget.client.authorized
                                ? const Color(0xff66e6a0) : const Color(0xffed6b79)),
                            duration: const Duration(milliseconds: 240),
                            builder: (_, color, __) => CustomPaint(
                              painter: _ConnectedWave(_wave, color!))),
                        ),
                      ),
                    if (!_showChat)
                      Positioned(
                        key: const ValueKey('dock-avatar'),
                        left: avatarCenter.dx - avatarSize / 2,
                        top: avatarCenter.dy - avatarSize / 2,
                        width: avatarSize,
                        height: avatarSize,
                        child: avatar!,
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    ));
  }

  void _openChat() {
    if (!widget.client.authorized) return;
    final client = widget.client;
    final model = gFFI.chatModel;
    model.changeCurrentKey(MessageKey(client.peerId, client.id));
    client.unreadChatMessageCount.value = 0;
    setState(() => _showChat = true);
    model.requestChatInputFocus();
  }

  Widget _chatPane() {
    final content = ChatPage(type: ChatPageType.desktopCM);
    return Padding(
      padding: const EdgeInsets.all(4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(21),
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: translate('Back'),
                    icon: const Icon(Icons.arrow_back_rounded, size: 19),
                    onPressed: () => setState(() => _showChat = false),
                  ),
                  Text(translate('Chat'),
                      style: Theme.of(context).textTheme.titleSmall),
                ],
              ),
              Expanded(
                child: widget.allowRemoteModification
                    ? content
                    : buildRemoteBlock(
                        child: content, block: _chatBlock, mask: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatar(String name, String jpeg) {
    final statusColor = widget.client.authorized
        ? const Color(0xff52d890) : const Color(0xffed6b79);
    return Semantics(
      button: true,
      expanded: _expanded,
      label: '$name · ${widget.client.authorized ? translate('Connected') : '等待密码验证'}',
      child: MouseRegion(
        cursor:
            _dragging ? SystemMouseCursors.grabbing : SystemMouseCursors.click,
        child: GestureDetector(
          onPanDown: (details) {
            if (!_dragging) _grab = details.globalPosition;
          },
          onPanStart: _startDrag,
          onPanUpdate: _updateDrag,
          onPanEnd: (_) => unawaited(_finishDrag()),
          onPanCancel: () => unawaited(_finishDrag()),
          child: Material(
            type: MaterialType.transparency,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkResponse(
              containedInkWell: true,
              highlightShape: BoxShape.circle,
              mouseCursor: _dragging
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.click,
              onTap: () => unawaited(_setExpanded(!_expanded)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _expanded ? const Color(0xffeaf2fd) : statusColor,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1.5),
                  child: NnuOfficialSupportAvatar(name: name, jpeg: jpeg),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(String name, NnuOfficialSupportIdentity? identity) {
    if (!widget.client.authorized || identity == null) {
      return NnuPasswordConnectionCard(client: widget.client, name: name,
        exiting: widget.exiting, onDisconnect: () => widget.runLocalAction(widget.onDisconnect));
    }
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? const Color(0xffe2efff) : const Color(0xff203e61);
    final muted = dark ? const Color(0xffa9bdd4) : const Color(0xff486781);
    final line = dark ? const Color(0x487da4c5) : const Color(0x4595adc7);
    final elapsed =
        DateTime.now().difference(widget.client.trustedConnectedAt!);
    final seconds = elapsed.isNegative ? 0 : elapsed.inSeconds;
    final clock = [seconds ~/ 3600, seconds ~/ 60 % 60, seconds % 60]
        .map((part) => part.toString().padLeft(2, '0'))
        .join(':');
    final radius = BorderRadius.circular(21);
    final verified = translate('Officially verified');
    return DefaultTextStyle.merge(
        style: nnuOfficialSupportTypography,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: line),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: dark
                        ? const [Color(0xf2263f58), Color(0xed1a2e45)]
                        : const [Color(0xf7eff7ff), Color(0xf2dce9f5)],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(17),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 65),
                        child: SizedBox(height: 50,
                          child: NnuOfficialSupportNameLine(identity,
                            verifiedLabel: verified, nameColor: ink, fontSize: 19)),
                      ),
                      const SizedBox(height: 11),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text('ID  ${widget.client.peerId}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                                color: muted, fontSize: 12)),
                                        const SizedBox(height: 5),
                                        Wrap(
                                          spacing: 7,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            const Icon(Icons.circle,
                                                color: Color(0xff3caa73),
                                                size: 7),
                                            Text(translate('Connected'),
                                                style: TextStyle(
                                                    color: ink,
                                                    fontWeight:
                                                        FontWeight.w600)),
                                            Text(clock,
                                                style: TextStyle(color: muted)),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  _actionIcon(Icons.call_outlined, 'Voice call',
                                      ink, widget.onVoiceCall,
                                      tooltip: {'ios', 'android'}.contains(
                                              identity.peerPlatform.toLowerCase())
                                          ? '${translate('Voice call')} · ${translate('Unsupported')}'
                                          : null),
                                  const SizedBox(width: 5),
                                  Stack(
                                    children: [
                                      _actionIcon(
                                          Icons.chat_bubble_outline_rounded,
                                          'Chat',
                                          ink,
                                          _openChat),
                                      PositionedDirectional(
                                        top: 0,
                                        end: 0,
                                        child: IgnorePointer(
                                          child: unreadMessageCountBuilder(
                                              widget.client
                                                  .unreadChatMessageCount),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 5),
                                  _actionIcon(Icons.folder_copy_outlined,
                                      'Transfer file', ink, widget.onOpenFile,
                                      tooltip: identity.peerPlatform
                                                  .toLowerCase() ==
                                              'ios'
                                          ? '${translate('Transfer file')} · iOS ${translate('Unsupported')}'
                                          : null),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () =>
                            widget.runLocalAction(widget.onDisconnect),
                        icon: const Icon(Icons.link_off, size: 16),
                        label: Text(translate('Disconnect')),
                        style: OutlinedButton.styleFrom(
                          enabledMouseCursor: SystemMouseCursors.click,
                          textStyle: nnuOfficialSupportTypography.copyWith(
                              fontSize: 13),
                          minimumSize: const Size(0, 39),
                          foregroundColor: dark
                              ? const Color(0xffffaab4)
                              : const Color(0xff983540),
                          backgroundColor: dark
                              ? const Color(0x26884653)
                              : const Color(0xa8fff5f7),
                          side: BorderSide(
                              color: dark
                                  ? const Color(0x64764c5c)
                                  : const Color(0x58b86d76)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ));
  }

  Widget _actionIcon(
      IconData icon, String label, Color ink, VoidCallback? action,
      {String? tooltip}) {
    return IconButton(
      tooltip: tooltip ?? translate(label),
      onPressed: action == null ? null : () => widget.runLocalAction(action),
      icon: Icon(icon, size: 19),
      style: IconButton.styleFrom(
        enabledMouseCursor: SystemMouseCursors.click,
        fixedSize: const Size(36, 36),
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
        foregroundColor: ink,
        backgroundColor: ink.withOpacity(.07),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    );
  }
}

class _ConnectedWave extends CustomPainter {
  _ConnectedWave(this.wave, this.color) : super(repaint: wave);

  final Color color;

  final Animation<double> wave;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final delay in [0.0, .5]) {
      final phase = (wave.value + delay) % 1;
      paint.color = color.withOpacity(.64 * (1 - phase));
      canvas.drawCircle(center, 26 + 15 * phase, paint);
    }
  }

  @override
  bool shouldRepaint(_ConnectedWave oldDelegate) => oldDelegate.wave != wave || oldDelegate.color != color;
}
