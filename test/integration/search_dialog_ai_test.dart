import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:p2p_node/models/group.dart';
import 'package:p2p_node/models/message.dart';
import 'package:p2p_node/models/peer.dart';
import 'package:p2p_node/p2p/p2p_service.dart';
import 'package:p2p_node/widgets/search_dialog.dart';
import 'package:p2p_node/theme/app_colors.dart';

class _FakeP2PService extends P2PService {
  @override
  String get myName => 'NIK';

  @override
  String? get myUid => 'my_uid';

  @override
  String get myIp => '127.0.0.1';

  @override
  bool get hasLocalAiHost => true;

  @override
  bool get isOnline => true;

  @override
  bool get isInitialized => true;

  @override
  Map<String, Peer> get peers => {
        'peer1': const Peer(uid: 'peer1', name: 'ELENA', isOnline: true),
      };

  @override
  Set<String> get aiPeerIds => {'peer1'};

  @override
  Map<String, ChatGroup> get groups => const {};

  @override
  List<ChatMessage> get messages => const [];

  @override
  List<P2PLogEntry> get logs => const [];

  @override
  Map<String, List<P2PLogEntry>> get logsByPeer => const {};

  @override
  Future<void> init({String password = 'default'}) async {}

  @override
  Future<void> sendMessage(String targetUid, String text) async {}

  @override
  Future<void> sendAiMessage(String targetUid, String text) async {}

  @override
  Future<void> broadcastMessage(String text) async {}

  @override
  Future<void> sendFile(String targetUid, String filename, Uint8List data) async {}

  @override
  Future<void> sendGroupMessage(List<String> memberUids, String text) async {}

  @override
  Future<void> sendGroupMessageToGroup(String groupId, String text) async {}

  @override
  Future<ChatGroup> createGroup(String name, List<String> memberUids) async {
    throw UnimplementedError();
  }

  @override
  Future<void> updateGroupMembers(String groupId, List<String> memberUids) async {}

  @override
  Future<String?> exportLogsToTxt() async => null;

  @override
  void refreshPeers() {}

  @override
  void addLocalMessage(ChatMessage msg) {}

  @override
  Future<void> setMyName(String name) async {}
}

void main() {
  testWidgets('search dialog shows Local AI and remote AI results', (tester) async {
    final svc = _FakeP2PService();

    await tester.pumpWidget(
      ChangeNotifierProvider<P2PService>.value(
        value: svc,
        child: MaterialApp(
          home: Scaffold(
            body: SearchDialog(colors: AppColors.dark),
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'ai');
    await tester.tap(find.text('Find'));
    await tester.pumpAndSettle();

    expect(find.text('Local AI'), findsOneWidget);
    expect(find.text('ELENA AI'), findsOneWidget);
  });
}
