# P2P NODE — Flutter

Flutter port of `gui1.py` (tkinter P2P chat).  
Material Design 3 · Light/Dark themes · Android · iOS · Desktop

---

## Project structure

```
lib/
  main.dart                    ← Entry point, MultiProvider setup
  theme/
    app_colors.dart            ← LIGHT_THEME / DARK_THEME constants
    theme_provider.dart        ← toggle_theme() equivalent
  models/
    peer.dart                  ← {uid: name} peer data
    message.dart               ← ChatMessage (add_message equivalent)
  p2p/
    p2p_service.dart           ← P2PBridge interface + stub (demo)
  screens/
    chat_screen.dart           ← ChatUI main layout
  widgets/
    app_header.dart            ← build_header()
    peers_panel.dart           ← build_users_panel()
    chat_area.dart             ← build_chat_area() + add_message()
    message_input_bar.dart     ← build_input_bar() — SEND + BROADCAST
    search_dialog.dart         ← cmd_search_with_query() dialog
assets/
  icons/icon.svg
```

---

## Quick start

```bash
flutter pub get
flutter run -d macos        # Desktop
flutter run -d android
flutter run -d ios
```

---

## Replacing the stub with real P2P networking

`lib/p2p/p2p_service.dart` contains `P2PServiceStub` — a demo implementation
with two hard-coded peers and simulated incoming messages.

To wire up the **real backend** (equivalent to Python `main.py` + `P2PBridge`),
create `RealP2PService extends P2PService` and:

### 1 — mDNS / Zeroconf  (replaces Python `zeroconf`)
```yaml
# pubspec.yaml
dependencies:
  nsd: ^2.0.0
```
```dart
import 'package:nsd/nsd.dart';

// Register your node
final registration = await register(Service(
  name: '$myName-${myId.substring(0,12)}',
  type: '_p2p_chat._tcp',
  port: CHAT_PORT,
  txt: {'uid': myId, 'name': myName, 'xpub': myXpub},
));

// Discover peers
final discovery = await startDiscovery('_p2p_chat._tcp');
discovery.addServiceListener((service, status) {
  if (status == ServiceStatus.found) {
    final uid  = service.txt?['uid']  ?? '';
    final name = service.txt?['name'] ?? service.name ?? '';
    _peers[uid] = Peer(uid: uid, name: name, ip: service.host);
    notifyListeners();
  }
});
```

### 2 — TCP server  (replaces Python `asyncio.start_server`)
```dart
import 'dart:io';

final server = await ServerSocket.bind(InternetAddress.anyIPv4, CHAT_PORT);
server.listen((socket) async {
  // Read framed JSON, decrypt, push to messages stream
  final data = await socket.first;
  final payload = decrypt(data, sessionKey);
  _messages.add(ChatMessage(sender: payload['name'], text: payload['text'], ...));
  notifyListeners();
});
```

### 3 — Crypto  (replaces Python `cryptography` / `nacl`)
```yaml
dependencies:
  pointycastle: ^3.7.3
```
- X25519 key exchange → `ECDHBasicAgreement` with curve25519
- AES-256-GCM → `GCMBlockCipher`

### 4 — Swap the provider
```dart
// main.dart
ChangeNotifierProvider<P2PService>(create: (_) => RealP2PService()),
```

---

## Key mapping: Python → Flutter

| Python (gui1.py)              | Flutter                          |
|-------------------------------|----------------------------------|
| `LIGHT_THEME / DARK_THEME`    | `AppColors.light / .dark`        |
| `toggle_theme()`              | `ThemeProvider.toggle()`         |
| `P2PBridge`                   | `P2PService` (abstract)          |
| `build_header()`              | `AppHeader` widget               |
| `build_users_panel()`         | `PeersPanel` widget              |
| `build_chat_area()`           | `ChatArea` widget                |
| `build_input_bar()`           | `MessageInputBar` widget         |
| `cmd_send()`                  | `ChatScreen._handleSend()`       |
| `cmd_broadcast()`             | `ChatScreen._handleBroadcast()`  |
| `cmd_search_with_query()`     | `SearchDialog`                   |
| `add_message()`               | `_MessageRow` in `ChatArea`      |
| `show_temp_message()`         | `ChatMessage(isSystem: true)`    |
| `_start_polling()`            | `ChatScreen._startPolling()`     |
| `_incoming_queue`             | `P2PService.messages` stream     |
| `RoundedButton`               | `_HeaderButton / _InputButton`   |
| `ToolTip`                     | Flutter `Tooltip` widget         |
| `AutoScrollbar`               | `ListView` + `ScrollController`  |
