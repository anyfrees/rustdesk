// original cm window in Sciter version.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/audio_input.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/cm_file_model.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';
import 'package:get/get.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../common.dart';
import '../../common/widgets/chat_page.dart';
import '../../common/widgets/nnu_official_support_badge.dart';
import '../../common/widgets/nnu_official_support_profile.dart';
import '../../main.dart' show changeTrustedDockWindow, syncTrustedCmWindow,
    trustedEndedClient, trustedEndRevealed, desktopVoiceCall, voiceCallArrived, cancelledPasswordDock;
import '../../models/file_model.dart';
import '../../models/platform_model.dart';
import '../../models/server_model.dart';
import '../widgets/nnu_trusted_request.dart';
import '../widgets/nnu_connected_dock.dart';
import '../widgets/nnu_session_ended.dart';
import '../widgets/nnu_voice_call.dart';
import '../widgets/nnu_direct_voice_call.dart';
import '../widgets/nnu_voice_sound.dart';

/// Set only by this window's own close control, and only once the user has confirmed. Any other
/// way the window can go - a session logout closing every window, the window manager, a native
/// title-bar button this app does not draw - leaves it false, which is the honest answer:
/// nothing in that close says who asked for it. It lives at file scope because the control that
/// sets it (`ConnectionManagerState`) and the handler that reads it (`_DesktopServerPageState`)
/// are different widgets.
bool _cmClosedByOperator = false;

class DesktopServerPage extends StatefulWidget {
  const DesktopServerPage({Key? key}) : super(key: key);

  @override
  State<DesktopServerPage> createState() => _DesktopServerPageState();
}

class _DesktopServerPageState extends State<DesktopServerPage>
    with WindowListener, AutomaticKeepAliveClientMixin {
  final tabController = gFFI.serverModel.tabController;
  int? _answeredTrustedRequest;

  _DesktopServerPageState() {
    gFFI.ffiModel.updateEventListener(gFFI.sessionId, "");
    Get.put<DesktopTabController>(tabController);
    tabController.onRemoved = (_, id) {
      onRemoveId(id);
    };
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    // Other platforms keep the old behaviour exactly: the ambiguity this guards against is a
    // Linux session logout, which closes every window in the session.
    final byOperator = _cmClosedByOperator || !isLinux;
    Future.wait([gFFI.serverModel.closeAll(byOperator: byOperator), gFFI.close()]).then((_) {
      if (isMacOS) {
        RdPlatformChannel.instance.terminate();
      } else {
        windowManager.setPreventClose(false);
        windowManager.close();
      }
    });
    super.onWindowClose();
  }

  void onRemoveId(String id) {
    if (tabController.state.value.tabs.isEmpty && trustedEndedClient == null &&
        cancelledPasswordDock == null) {
      windowManager.close();
    }
  }

  void _answerTrustedRequest(ServerModel model, Client request, bool accept) {
    checkClickTime(request.id, () {
      if (!mounted ||
          model.trustedDesktopRequest != request ||
          _answeredTrustedRequest == request.id) {
        return;
      }
      _answeredTrustedRequest = request.id;
      if (accept) {
        model.sendLoginResponse(request, true, waitForAuthorization: true);
      } else {
        bind.cmCloseConnection(connId: request.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gFFI.serverModel),
        ChangeNotifierProvider.value(value: gFFI.chatModel),
      ],
      child: Consumer<ServerModel>(
        builder: (context, serverModel, child) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(syncTrustedCmWindow());
          });
          final request = serverModel.trustedDesktopRequest;
          if (request != null) {
            return Scaffold(
              backgroundColor: Colors.transparent,
              body: GestureDetector(
                onPanStart: (_) => windowManager.startDragging(),
                child: NnuTrustedRequest(
                  key: ValueKey(request.id),
                  identity: request.officialSupport!,
                  fullControl: request.canAcceptFullControl,
                  onAccept: () =>
                      _answerTrustedRequest(serverModel, request, true),
                  onReject: () =>
                      _answerTrustedRequest(serverModel, request, false),
                ),
              ),
            );
          }
          final voice = desktopVoiceCall;
          if (voice != null) {
            final identity = voice.officialSupport;
            final name = identity?.accountName.isNotEmpty == true
                ? identity!.accountName : voice.name.isEmpty ? voice.peerId : voice.name;
            return Scaffold(backgroundColor: Colors.transparent,
              body: GestureDetector(onPanStart: (_) {
                if (voiceCallArrived.value) windowManager.startDragging();
              }, child: NnuVoiceSound(key: ValueKey(voice.id),
                tone: voice.incomingVoiceCall ? NnuVoiceTone.incoming : NnuVoiceTone.quiet,
                builder: (enabled, toggle, stop) => NnuVoiceCall(
                  name: name, avatarJpeg: identity?.avatarJpeg ?? '',
                  soundEnabled: enabled, onToggleSound: isWindows ? toggle : null,
                  incoming: voice.incomingVoiceCall, arrived: voiceCallArrived,
                  onAccept: () { stop(); bind.cmHandleIncomingVoiceCall(id: voice.id, accept: true); },
                  onReject: () { stop(); bind.cmHandleIncomingVoiceCall(id: voice.id, accept: false); },
                  onHangUp: () => bind.cmCloseVoiceCall(id: voice.id),
                  onMicrophone: () => nnuChooseVoiceMicrophone(context)))));
          }
          final dock = serverModel.desktopConnectionDock ?? cancelledPasswordDock;
          if (dock != null) {
            void localAction(VoidCallback action) => checkClickTime(dock.id, () {
                  if (mounted && serverModel.desktopConnectionDock?.id == dock.id) {
                    action();
                  }
                });
            return NnuConnectedDock(
              key: ValueKey(dock.id),
              client: dock,
              exiting: serverModel.desktopConnectionDock == null,
              changeWindow: (change) => changeTrustedDockWindow(dock.id, change),
              runLocalAction: localAction,
              allowRemoteModification: allowRemoteCMModification(),
              onDisconnect: () => bind.cmCloseConnection(connId: dock.id),
              onVoiceCall: dock.authorized && !dock.disconnected &&
                      !dock.inVoiceCall && !bind.isIncomingOnly() &&
                      !{'ios', 'android'}.contains(
                          dock.officialSupport?.peerPlatform.toLowerCase())
                  ? () => unawaited(nnuStartDirectVoiceCall(context, dock.peerId,
                      dock.officialSupport?.accountName ?? dock.name))
                  : null,
              onOpenFile: dock.authorized && dock.canReverseFileTransfer && !bind.isIncomingOnly()
                  ? () => unawaited(_openDockFileTransfer(dock))
                  : null,
            );
          }
          final ended = trustedEndedClient;
          if (ended != null) {
            return Scaffold(backgroundColor: Colors.transparent,
              body: GestureDetector(onPanStart: (_) => windowManager.startDragging(),
                child: NnuSessionEndTransition(key: ValueKey(ended.id),
                  identity: ended.officialSupport!, revealed: trustedEndRevealed,
                  child: NnuSessionEnded(
                  identity: ended.officialSupport!, peerId: ended.peerId,
                  onClose: () async {
                    await bind.cmRemoveDisconnectedConnection(connId: ended.id);
                    if (!serverModel.clients.any((client) => !client.disconnected)) windowManager.close();
                  })),
              ));
          }
          if (serverModel.approveMode == 'password' &&
              !serverModel.clients.any((c) => !c.disconnected)) {
            return const Scaffold(backgroundColor: Colors.transparent, body: SizedBox.shrink());
          }
          final body = Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: ConnectionManager(),
          );
          return isLinux
              ? buildVirtualWindowFrame(context, body)
              : workaroundWindowBorder(
                  context,
                  Container(
                    decoration: BoxDecoration(
                        border:
                            Border.all(color: MyTheme.color(context).border!)),
                    child: body,
                  ));
        },
      ),
    );
  }

  Future<void> _openDockFileTransfer(Client client) async {
    if (!client.canReverseFileTransfer || bind.isIncomingOnly()) return;
    try {
      await Process.start(
        Platform.resolvedExecutable,
        ['--file-transfer', client.peerId],
        mode: ProcessStartMode.detached,
      );
    } catch (error) {
      debugPrint('Could not open trusted session file transfer: $error');
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(translate('Failed to connect'))));
      }
    }
  }

  @override
  bool get wantKeepAlive => true;
}

class ConnectionManager extends StatefulWidget {
  @override
  State<StatefulWidget> createState() => ConnectionManagerState();
}

class ConnectionManagerState extends State<ConnectionManager>
    with WidgetsBindingObserver {
  final RxBool _controlPageBlock = false.obs;
  final RxBool _sidePageBlock = false.obs;

  ConnectionManagerState() {
    gFFI.serverModel.tabController.onSelected = (client_id_str) {
      final client_id = int.tryParse(client_id_str);
      if (client_id != null) {
        final client =
            gFFI.serverModel.clients.firstWhereOrNull((e) => e.id == client_id);
        if (client != null) {
          gFFI.chatModel.changeCurrentKey(MessageKey(client.peerId, client.id));
          if (client.unreadChatMessageCount.value > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              client.unreadChatMessageCount.value = 0;
              gFFI.chatModel.showChatPage(MessageKey(client.peerId, client.id));
            });
          }
          windowManager.setTitle(getWindowNameWithId(client.peerId));
          gFFI.cmFileModel.updateCurrentClientId(client.id);
        }
      }
    };
    gFFI.chatModel.isConnManager = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (!allowRemoteCMModification()) {
        shouldBeBlocked(_controlPageBlock, null);
        shouldBeBlocked(_sidePageBlock, null);
      }
    }
  }

  @override
  void initState() {
    gFFI.serverModel.updateClientState();
    WidgetsBinding.instance.addObserver(this);
    super.initState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final serverModel = Provider.of<ServerModel>(context);
    pointerHandler(PointerEvent e) {
      if (serverModel.cmHiddenTimer != null) {
        serverModel.cmHiddenTimer!.cancel();
        serverModel.cmHiddenTimer = null;
        debugPrint("CM hidden timer has been canceled");
      }
    }

    return serverModel.clients.isEmpty
        ? Column(
            children: [
              buildTitleBar(),
              Expanded(
                child: Center(
                  child: Text(translate("Waiting")),
                ),
              ),
            ],
          )
        : Listener(
            onPointerDown: pointerHandler,
            onPointerMove: pointerHandler,
            child: DesktopTab(
              showTitle: false,
              showMaximize: false,
              showMinimize: true,
              showClose: true,
              onWindowCloseButton: handleWindowCloseButton,
              controller: serverModel.tabController,
              selectedBorderColor: MyTheme.accent,
              maxLabelWidth: 100,
              tail: null, //buildScrollJumper(),
              tabBuilder: (key, icon, label, themeConf) {
                final client = serverModel.clients
                    .firstWhereOrNull((client) => client.id.toString() == key);
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Tooltip(
                        message: key,
                        waitDuration: Duration(seconds: 1),
                        child: label),
                    unreadMessageCountBuilder(client?.unreadChatMessageCount)
                        .marginOnly(left: 4),
                  ],
                );
              },
              pageViewBuilder: (pageView) => LayoutBuilder(
                builder: (context, constrains) {
                  var borderWidth = 0.0;
                  if (constrains.maxWidth >
                      kConnectionManagerWindowSizeClosedChat.width) {
                    borderWidth = kConnectionManagerWindowSizeOpenChat.width -
                        constrains.maxWidth;
                  } else {
                    borderWidth = kConnectionManagerWindowSizeClosedChat.width -
                        constrains.maxWidth;
                  }
                  if (borderWidth < 0 || borderWidth > 50) {
                    borderWidth = 0;
                  }
                  final realClosedWidth =
                      kConnectionManagerWindowSizeClosedChat.width -
                          borderWidth;
                  final realChatPageWidth =
                      constrains.maxWidth - realClosedWidth;
                  final row = Row(children: [
                    if (constrains.maxWidth >
                        kConnectionManagerWindowSizeClosedChat.width)
                      Consumer<ChatModel>(
                          builder: (_, model, child) => SizedBox(
                                width: realChatPageWidth,
                                child: allowRemoteCMModification()
                                    ? buildSidePage()
                                    : buildRemoteBlock(
                                        child: buildSidePage(),
                                        block: _sidePageBlock,
                                        mask: true),
                              )),
                    SizedBox(
                        width: realClosedWidth,
                        child: SizedBox(
                            width: realClosedWidth,
                            child: allowRemoteCMModification()
                                ? pageView
                                : buildRemoteBlock(
                                    child: _buildKeyEventBlock(pageView),
                                    block: _controlPageBlock,
                                    mask: false,
                                  ))),
                  ]);
                  return Container(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    child: row,
                  );
                },
              ),
            ),
          );
  }

  Widget buildSidePage() {
    final selected = gFFI.serverModel.tabController.state.value.selected;
    if (selected < 0 || selected >= gFFI.serverModel.clients.length) {
      return Offstage();
    }
    final clientType = gFFI.serverModel.clients[selected].type_();
    if (clientType == ClientType.file) {
      return _FileTransferLogPage();
    } else {
      return ChatPage(type: ChatPageType.desktopCM);
    }
  }

  Widget _buildKeyEventBlock(Widget child) {
    return ExcludeFocus(child: child, excluding: true);
  }

  Widget buildTitleBar() {
    return SizedBox(
      height: kDesktopRemoteTabBarHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const _AppIcon(),
          Expanded(
            child: GestureDetector(
              onPanStart: (d) {
                windowManager.startDragging();
              },
              child: Container(
                color: Theme.of(context).colorScheme.background,
              ),
            ),
          ),
          const SizedBox(
            width: 4.0,
          ),
          const _CloseButton()
        ],
      ),
    );
  }

  Widget buildScrollJumper() {
    final offstage = gFFI.serverModel.clients.length < 2;
    final sc = gFFI.serverModel.tabController.state.value.scrollController;
    return Offstage(
        offstage: offstage,
        child: Row(
          children: [
            ActionIcon(
                icon: Icons.arrow_left, iconSize: 22, onTap: sc.backward),
            ActionIcon(
                icon: Icons.arrow_right, iconSize: 22, onTap: sc.forward),
          ],
        ));
  }

  Future<bool> handleWindowCloseButton() async {
    var tabController = gFFI.serverModel.tabController;
    final connLength = tabController.length;
    if (connLength <= 1) {
      _cmClosedByOperator = true;
      windowManager.close();
      return true;
    } else {
      final bool res;
      if (!option2bool(kOptionEnableConfirmClosingTabs,
          bind.mainGetLocalOption(key: kOptionEnableConfirmClosingTabs))) {
        res = true;
      } else {
        res = await closeConfirmDialog();
      }
      if (res) {
        // After the dialog, never before it: an external close while it is open must not
        // inherit an intent the user had not expressed yet.
        _cmClosedByOperator = true;
        windowManager.close();
      }
      return res;
    }
  }
}

Widget buildConnectionCard(Client client) {
  if (client.officialSupport != null) {
    return Consumer<ServerModel>(
      builder: (context, value, child) {
        final theme = Theme.of(context);
        final dark = theme.brightness == Brightness.dark;
        final ink = dark ? const Color(0xffe6efff) : const Color(0xff203f68);
        return Theme(
          data: theme.copyWith(
            colorScheme: theme.colorScheme.copyWith(
              background: dark ? const Color(0xff19273e) : const Color(0xffedf3fb),
              onSurface: ink,
            ),
            textTheme: theme.textTheme.apply(
              fontFamily: nnuOfficialSupportTypography.fontFamily,
              fontFamilyFallback: nnuOfficialSupportTypography.fontFamilyFallback,
              bodyColor: ink,
              displayColor: ink,
            ),
            dividerColor:
                dark ? const Color(0xff3a4e6c) : const Color(0xffb9cde7),
          ),
          child: DefaultTextStyle.merge(
            style: nnuOfficialSupportTypography,
            child: Column(
              key: ValueKey(client.id),
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    primary: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _CmHeader(client: client),
                        if (!client.disconnected) _PrivilegeBoard(client: client),
                      ],
                    ),
                  ),
                ),
                _CmControlPanel(client: client),
              ],
            ).paddingSymmetric(vertical: 4, horizontal: 8),
          ),
        );
      },
    );
  }
  return Consumer<ServerModel>(
    builder: (context, value, child) => Column(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      key: ValueKey(client.id),
      children: [
        _CmHeader(client: client),
        client.type_() == ClientType.file ||
                client.type_() == ClientType.portForward ||
                client.type_() == ClientType.terminal ||
                client.disconnected
            ? Offstage()
            : _PrivilegeBoard(client: client),
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: _CmControlPanel(client: client),
          ),
        )
      ],
    ).paddingSymmetric(vertical: 4.0, horizontal: 8.0),
  );
}

class _AppIcon extends StatelessWidget {
  const _AppIcon({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: 4.0),
      child: loadIcon(30),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () {
        windowManager.close();
      },
      icon: const Icon(
        IconFont.close,
        size: 18,
      ),
      splashColor: Colors.transparent,
      hoverColor: Colors.transparent,
    );
  }
}

class _CmHeader extends StatefulWidget {
  final Client client;

  const _CmHeader({Key? key, required this.client}) : super(key: key);

  @override
  State<_CmHeader> createState() => _CmHeaderState();
}

class _CmHeaderState extends State<_CmHeader>
    with AutomaticKeepAliveClientMixin {
  Client get client => widget.client;

  final _time = 0.obs;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(Duration(seconds: 1), (_) {
      if (client.authorized && !client.disconnected) {
        _time.value = _time.value + 1;
      }
    });
    // Call onSelected in post frame callback, since we cannot guarantee that the callback will not call setState.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gFFI.serverModel.tabController.onSelected?.call(client.id.toString());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final identity = client.officialSupport;
    if (identity != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(5, 10, 5, 6),
        child: NnuOfficialSupportProfile(
          identity,
          peerId: client.peerId,
          status: Wrap(
            spacing: 8,
            runSpacing: 3,
            children: [
              Text(_connectionStatus),
              if (client.authorized) _duration(),
            ],
          ),
          trailing: _showHeaderAction ? _buildHeaderAction(compact: true) : null,
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10.0),
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            Color(0xff00bfe1),
            Color(0xff0071ff),
          ],
        ),
      ),
      margin: EdgeInsets.symmetric(horizontal: 5.0, vertical: 10.0),
      padding: EdgeInsets.only(
        top: 10.0,
        bottom: 10.0,
        left: 10.0,
        right: 5.0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildClientAvatar().marginOnly(right: 10.0),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                    child: Text(
                  client.name,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                    overflow: TextOverflow.ellipsis,
                  ),
                  maxLines: 1,
                )),
                FittedBox(
                  child: Text(
                    "(${client.peerId})",
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
                if (client.type_() == ClientType.terminal)
                  FittedBox(
                    child: Text(
                      translate("Terminal"),
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                if (client.type_() == ClientType.file)
                  FittedBox(
                    child: Text(
                      translate("Transfer file"),
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                if (client.type_() == ClientType.camera)
                  FittedBox(
                    child: Text(
                      translate("View camera"),
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                if (client.portForward.isNotEmpty)
                  FittedBox(
                    child: Text(
                      "Port Forward: ${client.portForward}",
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ),
                SizedBox(height: 10.0),
                FittedBox(
                    child: Row(
                  children: [
                    Text(
                      _connectionStatus,
                      style: const TextStyle(color: Colors.white),
                    ).marginOnly(right: 8.0),
                    if (client.authorized)
                      _duration(style: const TextStyle(color: Colors.white)),
                  ],
                ))
              ],
            ),
          ),
          Offstage(
            offstage: !_showHeaderAction,
            child: _buildHeaderAction(),
          ),
        ],
      ),
    );
  }

  String get _connectionStatus => client.authorized
      ? translate(client.disconnected ? 'Disconnected' : 'Connected')
      : "${translate("Request access to your device")}...";

  Widget _duration({TextStyle? style}) => Obx(
        () => Text(
          formatDurationToTime(Duration(seconds: _time.value)),
          style: style,
        ),
      );

  bool get _showHeaderAction => client.authorized &&
      (client.type_() == ClientType.remote ||
          client.type_() == ClientType.file ||
          client.type_() == ClientType.camera);

  Widget _buildHeaderAction({bool compact = false}) {
    final file = client.type_() == ClientType.file;
    return IconButton(
      onPressed: () => checkClickTime(client.id, () {
        if (file) {
          gFFI.chatModel.toggleCMFilePage();
        } else {
          gFFI.chatModel.toggleCMChatPage(MessageKey(client.peerId, client.id));
        }
      }),
      icon: SvgPicture.asset(
        file ? 'assets/file_transfer.svg' : 'assets/chat2.svg',
        colorFilter: compact
            ? svgColor(Theme.of(context).colorScheme.onSurface)
            : null,
      ),
      splashRadius: kDesktopIconButtonSplashRadius,
      tooltip: compact ? translate(file ? 'Transfer file' : 'Chat') : null,
      constraints:
          compact ? const BoxConstraints.tightFor(width: 38, height: 34) : null,
      padding: compact ? const EdgeInsets.all(6) : const EdgeInsets.all(8),
    );
  }

  @override
  bool get wantKeepAlive => true;

  Widget _buildClientAvatar() {
    return buildAvatarWidget(
          avatar: client.avatar,
          size: 70,
          borderRadius: 15,
          fallback: _buildInitialAvatar(),
        ) ??
        _buildInitialAvatar();
  }

  Widget _buildInitialAvatar() {
    return Container(
      width: 70,
      height: 70,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: str2color(client.name),
        borderRadius: BorderRadius.circular(15.0),
      ),
      child: Text(
        client.name.isNotEmpty ? client.name[0] : '?',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.white,
          fontSize: 55,
        ),
      ),
    );
  }
}

class _PrivilegeBoard extends StatefulWidget {
  final Client client;

  const _PrivilegeBoard({Key? key, required this.client}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _PrivilegeBoardState();
}

class _PrivilegeBoardState extends State<_PrivilegeBoard> {
  late final client = widget.client;
  Widget buildPermissionIcon(bool enabled, IconData iconData,
      Function(bool)? onTap, String tooltipText,
      {required bool canModify}) {
    return Tooltip(
      message: "$tooltipText: ${enabled ? "ON" : "OFF"}",
      waitDuration: Duration.zero,
      child: Container(
        decoration: BoxDecoration(
          color: enabled
              ? (canModify ? MyTheme.accent : MyTheme.accent.withOpacity(0.6))
              : Colors.grey[700],
          borderRadius: BorderRadius.circular(10.0),
        ),
        padding: EdgeInsets.all(8.0),
        child: InkWell(
          onTap: canModify
              ? () =>
                  checkClickTime(widget.client.id, () => onTap?.call(!enabled))
              : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Expanded(
                child: Icon(
                  iconData,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final crossAxisCount = 4;
    final spacing = 10.0;
    final canModifyPermission =
        bind.mainGetBuildinOption(key: kOptionEnablePermChangeInAcceptWindow) !=
            'N';
    return Container(
      width: double.infinity,
      height: 160.0,
      margin: EdgeInsets.all(5.0),
      padding: EdgeInsets.all(5.0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10.0),
        color: Theme.of(context).colorScheme.background,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(client.officialSupport == null ? .2 : .08),
            spreadRadius: 1,
            blurRadius: 1,
            offset: Offset(0, 1.5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            translate("Permissions"),
            style: TextStyle(
              fontSize: client.officialSupport == null ? 16 : 15,
              fontWeight: client.officialSupport == null
                  ? FontWeight.bold
                  : FontWeight.w500,
              color: client.officialSupport == null
                  ? null
                  : Theme.of(context).colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ).marginOnly(left: 4.0, bottom: 8.0),
          Expanded(
            child: GridView.count(
              crossAxisCount: crossAxisCount,
              padding: EdgeInsets.symmetric(horizontal: spacing),
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              children: client.type_() == ClientType.camera
                  ? [
                      buildPermissionIcon(
                        client.audio,
                        Icons.volume_up_rounded,
                        (enabled) {
                          bind.cmSwitchPermission(
                              connId: client.id,
                              name: "audio",
                              enabled: enabled);
                          setState(() {
                            client.audio = enabled;
                          });
                        },
                        translate('Enable audio'),
                        canModify: canModifyPermission,
                      ),
                      buildPermissionIcon(
                        client.recording,
                        Icons.videocam_rounded,
                        (enabled) {
                          bind.cmSwitchPermission(
                              connId: client.id,
                              name: "recording",
                              enabled: enabled);
                          setState(() {
                            client.recording = enabled;
                          });
                        },
                        translate('Enable recording session'),
                        canModify: canModifyPermission,
                      ),
                    ]
                  : [
                      buildPermissionIcon(
                        client.keyboard,
                        Icons.keyboard,
                        (enabled) {
                          bind.cmSwitchPermission(
                              connId: client.id,
                              name: "keyboard",
                              enabled: enabled);
                          setState(() {
                            client.keyboard = enabled;
                          });
                        },
                        translate('Enable keyboard/mouse'),
                        canModify: canModifyPermission,
                      ),
                      buildPermissionIcon(
                        client.clipboard,
                        Icons.assignment_rounded,
                        (enabled) {
                          bind.cmSwitchPermission(
                              connId: client.id,
                              name: "clipboard",
                              enabled: enabled);
                          setState(() {
                            client.clipboard = enabled;
                          });
                        },
                        translate('Enable clipboard'),
                        canModify: canModifyPermission,
                      ),
                      buildPermissionIcon(
                        client.audio,
                        Icons.volume_up_rounded,
                        (enabled) {
                          bind.cmSwitchPermission(
                              connId: client.id,
                              name: "audio",
                              enabled: enabled);
                          setState(() {
                            client.audio = enabled;
                          });
                        },
                        translate('Enable audio'),
                        canModify: canModifyPermission,
                      ),
                      buildPermissionIcon(
                        client.file,
                        Icons.upload_file_rounded,
                        (enabled) {
                          bind.cmSwitchPermission(
                              connId: client.id,
                              name: "file",
                              enabled: enabled);
                          setState(() {
                            client.file = enabled;
                          });
                        },
                        translate('Enable file copy and paste'),
                        canModify: canModifyPermission,
                      ),
                      buildPermissionIcon(
                        client.restart,
                        Icons.restart_alt_rounded,
                        (enabled) {
                          bind.cmSwitchPermission(
                              connId: client.id,
                              name: "restart",
                              enabled: enabled);
                          setState(() {
                            client.restart = enabled;
                          });
                        },
                        translate('Enable remote restart'),
                        canModify: canModifyPermission,
                      ),
                      buildPermissionIcon(
                        client.recording,
                        Icons.videocam_rounded,
                        (enabled) {
                          bind.cmSwitchPermission(
                              connId: client.id,
                              name: "recording",
                              enabled: enabled);
                          setState(() {
                            client.recording = enabled;
                          });
                        },
                        translate('Enable recording session'),
                        canModify: canModifyPermission,
                      ),
                      // only windows support block input
                      if (isWindows)
                        buildPermissionIcon(
                          client.blockInput,
                          Icons.block,
                          (enabled) {
                            bind.cmSwitchPermission(
                                connId: client.id,
                                name: "block_input",
                                enabled: enabled);
                            setState(() {
                              client.blockInput = enabled;
                            });
                          },
                          translate('Enable blocking user input'),
                          canModify: canModifyPermission,
                        ),
                      if (bind.mainSupportedPrivacyModeImpls() != '[]')
                        buildPermissionIcon(
                          client.privacyMode,
                          Icons.visibility_off,
                          (enabled) {
                            bind.cmSwitchPermission(
                                connId: client.id,
                                name: "privacy_mode",
                                enabled: enabled);
                            setState(() {
                              client.privacyMode = enabled;
                            });
                          },
                          translate('Enable privacy mode'),
                          canModify: canModifyPermission,
                        )
                    ],
            ),
          ),
        ],
      ),
    );
  }
}

const double buttonBottomMargin = 8;

class _CmControlPanel extends StatelessWidget {
  final Client client;

  const _CmControlPanel({Key? key, required this.client}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return client.authorized
        ? client.disconnected
            ? buildDisconnected(context)
            : buildAuthorized(context)
        : buildUnAuthorized(context);
  }

  buildAuthorized(BuildContext context) {
    final bool canElevate = bind.cmCanElevate();
    final model = Provider.of<ServerModel>(context);
    final showElevation = canElevate &&
        model.showElevation &&
        client.type_() == ClientType.remote;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Offstage(
          offstage: !client.inVoiceCall,
          child: Row(
            children: [
              Expanded(
                child: buildButton(context,
                    color: MyTheme.accent,
                    onClick: null, onTapDown: (details) async {
                  final devicesInfo =
                      await AudioInput.getDevicesInfo(true, true);
                  List<String> devices = devicesInfo['devices'] as List<String>;
                  if (devices.isEmpty) {
                    msgBox(
                      gFFI.sessionId,
                      'custom-nocancel-info',
                      'Prompt',
                      'no_audio_input_device_tip',
                      '',
                      gFFI.dialogManager,
                    );
                    return;
                  }

                  String currentDevice = devicesInfo['current'] as String;
                  final x = details.globalPosition.dx;
                  final y = details.globalPosition.dy;
                  final position = RelativeRect.fromLTRB(x, y, x, y);
                  showMenu(
                    context: context,
                    position: position,
                    items: devices
                        .map((d) => PopupMenuItem<String>(
                              value: d,
                              height: 18,
                              padding: EdgeInsets.zero,
                              onTap: () => AudioInput.setDevice(d, true, true),
                              child: IgnorePointer(
                                  child: RadioMenuButton(
                                value: d,
                                groupValue: currentDevice,
                                onChanged: (v) {
                                  if (v != null)
                                    AudioInput.setDevice(v, true, true);
                                },
                                child: Container(
                                  child: Text(
                                    d,
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                  constraints: BoxConstraints(
                                      maxWidth:
                                          kConnectionManagerWindowSizeClosedChat
                                                  .width -
                                              80),
                                ),
                              )),
                            ))
                        .toList(),
                  );
                },
                    icon: Icon(
                      Icons.call_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                    text: "Audio input",
                    textColor: Colors.white),
              ),
              Expanded(
                child: buildButton(
                  context,
                  color: Colors.red,
                  onClick: () => closeVoiceCall(),
                  icon: Icon(
                    Icons.call_end_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                  text: "Stop voice call",
                  textColor: Colors.white,
                ),
              )
            ],
          ),
        ),
        Offstage(
          offstage: !client.incomingVoiceCall,
          child: Row(
            children: [
              Expanded(
                child: buildButton(context,
                    color: MyTheme.accent,
                    onClick: () => handleVoiceCall(true),
                    icon: Icon(
                      Icons.call_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                    text: "Accept",
                    textColor: Colors.white),
              ),
              Expanded(
                child: buildButton(
                  context,
                  color: Colors.red,
                  onClick: () => handleVoiceCall(false),
                  icon: Icon(
                    Icons.phone_disabled_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                  text: "Dismiss",
                  textColor: Colors.white,
                ),
              )
            ],
          ),
        ),
        Offstage(
          offstage: !client.fromSwitch,
          child: buildButton(context,
              color: Colors.purple,
              onClick: () => handleSwitchBack(context),
              icon: Icon(Icons.reply, color: Colors.white),
              text: "Switch Sides",
              textColor: Colors.white),
        ),
        Offstage(
          offstage: !showElevation,
          child: buildButton(
            context,
            color: MyTheme.accent,
            onClick: () {
              handleElevate(context);
              windowManager.minimize();
            },
            icon: Icon(
              Icons.security_rounded,
              color: Colors.white,
              size: 14,
            ),
            text: 'Elevate',
            textColor: Colors.white,
          ),
        ),
        Row(
          children: [
            Expanded(
              child: buildButton(context,
                  color: Colors.redAccent,
                  onClick: handleDisconnect,
                  text: 'Disconnect',
                  icon: Icon(
                    Icons.link_off_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                  textColor: Colors.white),
            ),
          ],
        )
      ],
    ).marginOnly(bottom: buttonBottomMargin);
  }

  buildDisconnected(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
            child: buildButton(context,
                color: MyTheme.accent,
                onClick: handleClose,
                text: 'Close',
                textColor: Colors.white)),
      ],
    ).marginOnly(bottom: buttonBottomMargin);
  }

  buildUnAuthorized(BuildContext context) {
    final bool canElevate = bind.cmCanElevate();
    final model = Provider.of<ServerModel>(context);
    final showElevation = canElevate &&
        model.showElevation &&
        client.type_() == ClientType.remote &&
        bind.mainGetBuildinOption(
                key: kOptionHideElevateButtonInAcceptWindow) !=
            'Y';
    final showAccept = model.approveMode != 'password';
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Offstage(
          offstage: !showElevation || !showAccept,
          child: buildButton(context, color: Colors.green[700], onClick: () {
            handleAccept(context);
            handleElevate(context);
            windowManager.minimize();
          },
              text: 'Accept and Elevate',
              icon: Icon(
                Icons.security_rounded,
                color: Colors.white,
                size: 14,
              ),
              textColor: Colors.white,
              tooltip: 'accept_and_elevate_btn_tooltip'),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (showAccept)
              Expanded(
                child: Column(
                  children: [
                    buildButton(
                      context,
                      color: MyTheme.accent,
                      onClick: () {
                        handleAccept(context);
                        windowManager.minimize();
                      },
                      text: 'Accept',
                      textColor: Colors.white,
                    ),
                  ],
                ),
              ),
            Expanded(
              child: buildButton(
                context,
                color: Colors.transparent,
                border: Border.all(color: Colors.grey),
                onClick: handleDisconnect,
                text: 'Cancel',
                textColor: null,
              ),
            ),
          ],
        ),
      ],
    ).marginOnly(bottom: buttonBottomMargin);
  }

  Widget buildButton(BuildContext context,
      {required Color? color,
      GestureTapCallback? onClick,
      Widget? icon,
      BoxBorder? border,
      required String text,
      required Color? textColor,
      String? tooltip,
      GestureTapDownCallback? onTapDown}) {
    assert(!(onClick == null && onTapDown == null));
    Widget textWidget;
    if (icon != null) {
      textWidget = Text(
        translate(text),
        style: TextStyle(color: textColor),
        textAlign: TextAlign.center,
      );
    } else {
      textWidget = Expanded(
        child: Text(
          translate(text),
          style: TextStyle(color: textColor),
          textAlign: TextAlign.center,
        ),
      );
    }
    final borderRadius = BorderRadius.circular(10.0);
    final btn = Container(
      height: 28,
      decoration: BoxDecoration(
          color: color, borderRadius: borderRadius, border: border),
      child: InkWell(
        borderRadius: borderRadius,
        onTap: () {
          if (onClick == null) return;
          checkClickTime(client.id, onClick);
        },
        onTapDown: (details) {
          if (onTapDown == null) return;
          checkClickTime(client.id, () {
            onTapDown.call(details);
          });
        },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Offstage(offstage: icon == null, child: icon).marginOnly(right: 5),
            textWidget,
          ],
        ),
      ),
    );
    return (tooltip != null
            ? Tooltip(
                message: translate(tooltip),
                child: btn,
              )
            : btn)
        .marginAll(4);
  }

  void handleDisconnect() {
    bind.cmCloseConnection(connId: client.id);
  }

  void handleAccept(BuildContext context) {
    final model = Provider.of<ServerModel>(context, listen: false);
    model.sendLoginResponse(client, true);
  }

  void handleElevate(BuildContext context) {
    final model = Provider.of<ServerModel>(context, listen: false);
    model.setShowElevation(false);
    bind.cmElevatePortable(connId: client.id);
  }

  void handleClose() async {
    await bind.cmRemoveDisconnectedConnection(connId: client.id);
    if (await bind.cmGetClientsLength() == 0) {
      windowManager.close();
    }
  }

  void handleSwitchBack(BuildContext context) {
    bind.cmSwitchBack(connId: client.id);
  }

  void handleVoiceCall(bool accept) {
    bind.cmHandleIncomingVoiceCall(id: client.id, accept: accept);
  }

  void closeVoiceCall() {
    bind.cmCloseVoiceCall(id: client.id);
  }
}

void checkClickTime(int id, Function() callback) async {
  if (allowRemoteCMModification()) {
    callback();
    return;
  }
  var clickCallbackTime = DateTime.now().millisecondsSinceEpoch;
  await bind.cmCheckClickTime(connId: id);
  Timer(const Duration(milliseconds: 120), () async {
    var d = clickCallbackTime - await bind.cmGetClickTime();
    if (d > 120) callback();
  });
}

bool allowRemoteCMModification() {
  return option2bool(kOptionAllowRemoteCmModification,
      bind.mainGetLocalOption(key: kOptionAllowRemoteCmModification));
}

class _FileTransferLogPage extends StatefulWidget {
  _FileTransferLogPage({Key? key}) : super(key: key);

  @override
  State<_FileTransferLogPage> createState() => __FileTransferLogPageState();
}

class __FileTransferLogPageState extends State<_FileTransferLogPage> {
  @override
  Widget build(BuildContext context) {
    return statusList();
  }

  Widget generateCard(Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.all(
          Radius.circular(15.0),
        ),
      ),
      child: child,
    );
  }

  iconLabel(CmFileLog item) {
    switch (item.action) {
      case CmFileAction.none:
        return Container();
      case CmFileAction.localToRemote:
      case CmFileAction.remoteToLocal:
        return Column(
          children: [
            Transform.rotate(
              angle: item.action == CmFileAction.remoteToLocal ? 0 : pi,
              child: SvgPicture.asset(
                "assets/arrow.svg",
                colorFilter: svgColor(Theme.of(context).tabBarTheme.labelColor),
              ),
            ),
            Text(item.action == CmFileAction.remoteToLocal
                ? translate('Send')
                : translate('Receive'))
          ],
        );
      case CmFileAction.remove:
        return Column(
          children: [
            Icon(
              Icons.delete,
              color: Theme.of(context).tabBarTheme.labelColor,
            ),
            Text(translate('Delete'))
          ],
        );
      case CmFileAction.createDir:
        return Column(
          children: [
            Icon(
              Icons.create_new_folder,
              color: Theme.of(context).tabBarTheme.labelColor,
            ),
            Text(translate('Create Folder'))
          ],
        );
      case CmFileAction.rename:
        return Column(
          children: [
            Icon(
              Icons.drive_file_move_outlined,
              color: Theme.of(context).tabBarTheme.labelColor,
            ),
            Text(translate('Rename'))
          ],
        );
    }
  }

  Widget statusList() {
    return PreferredSize(
      preferredSize: const Size(200, double.infinity),
      child: Container(
          padding: const EdgeInsets.all(12.0),
          child: Obx(
            () {
              final jobTable = gFFI.cmFileModel.currentJobTable;
              statusListView(List<CmFileLog> jobs) => ListView.builder(
                    controller: ScrollController(),
                    itemBuilder: (BuildContext context, int index) {
                      final item = jobs[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: generateCard(
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: 50,
                                    child: iconLabel(item),
                                  ).paddingOnly(left: 15),
                                  const SizedBox(
                                    width: 16.0,
                                  ),
                                  Expanded(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.fileName,
                                        ).paddingSymmetric(vertical: 10),
                                        if (item.totalSize > 0)
                                          Text(
                                            '${translate("Total")} ${readableFileSize(item.totalSize.toDouble())}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: MyTheme.darkGray,
                                            ),
                                          ),
                                        if (item.totalSize > 0)
                                          Offstage(
                                            offstage: item.state !=
                                                JobState.inProgress,
                                            child: Text(
                                              '${translate("Speed")} ${readableFileSize(item.speed)}/s',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: MyTheme.darkGray,
                                              ),
                                            ),
                                          ),
                                        Offstage(
                                          offstage: !(item.isTransfer() &&
                                              item.state !=
                                                  JobState.inProgress),
                                          child: Text(
                                            translate(
                                              item.display(),
                                            ),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: MyTheme.darkGray,
                                            ),
                                          ),
                                        ),
                                        if (item.totalSize > 0)
                                          Offstage(
                                            offstage: item.state !=
                                                JobState.inProgress,
                                            child: LinearPercentIndicator(
                                              padding:
                                                  EdgeInsets.only(right: 15),
                                              animateFromLastPercent: true,
                                              center: Text(
                                                '${(item.finishedSize / item.totalSize * 100).toStringAsFixed(0)}%',
                                              ),
                                              barRadius: Radius.circular(15),
                                              percent: item.finishedSize /
                                                  item.totalSize,
                                              progressColor: MyTheme.accent,
                                              backgroundColor:
                                                  Theme.of(context).hoverColor,
                                              lineHeight:
                                                  kDesktopFileTransferRowHeight,
                                            ).paddingSymmetric(vertical: 15),
                                          ),
                                      ],
                                    ),
                                  ),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [],
                                  ),
                                ],
                              ),
                            ],
                          ).paddingSymmetric(vertical: 10),
                        ),
                      );
                    },
                    itemCount: jobTable.length,
                  );

              return jobTable.isEmpty
                  ? generateCard(
                      Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SvgPicture.asset(
                              "assets/transfer.svg",
                              colorFilter: svgColor(
                                  Theme.of(context).tabBarTheme.labelColor),
                              height: 40,
                            ).paddingOnly(bottom: 10),
                            Text(
                              translate("No transfers in progress"),
                              textAlign: TextAlign.center,
                              textScaler: TextScaler.linear(1.20),
                              style: TextStyle(
                                  color:
                                      Theme.of(context).tabBarTheme.labelColor),
                            ),
                          ],
                        ),
                      ),
                    )
                  : statusListView(jobTable);
            },
          )),
    );
  }
}
