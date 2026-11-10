import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:uuid/uuid.dart';

class _Binding extends Fake implements RustdeskImpl {
  @override
  String translate({required String name, required String locale, dynamic hint}) => name;
}
class _Server extends Fake implements ServerModel {
  @override
  final multipleDesktopDocks = [
    Client(1, true, false, false, 'A', '1', false, false, false),
    Client(2, true, false, false, 'B', '2', false, false, false),
  ];
  @override
  Client? get desktopConnectionDock => multipleDesktopDocks.first;
  @override
  Client? get trustedDesktopDock => null;
}
class _Session extends Fake implements FFI {
  @override
  final serverModel = _Server();
  @override
  final sessionId = UuidValue('00000000-0000-4000-8000-000000000001');
}

void main() {
  test('messages from any orbit participant keep the legacy side panel closed', () async {
    platformFFI.setBindingForTesting(_Binding());
    final previous = desktopType;
    desktopType = DesktopType.cm;
    addTearDown(() => desktopType = previous);
    final session = _Session();
    final chat = ChatModel(WeakReference<FFI>(session))..isConnManager = true;
    addTearDown(() { chat.dispose(); chat.inputNode.dispose(); });
    for (final client in session.serverModel.multipleDesktopDocks) {
      await chat.showChatPage(MessageKey(client.peerId, client.id));
      expect(chat.isShowCMSidePage, isFalse);
    }
  });
}
