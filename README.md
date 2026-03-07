# P2P NODE — Децентрализованная система связи

> Flutter-приложение для обмена сообщениями, файлами и голосовых/видеозвонков без интернета и серверов.  
> Работает через Wi-Fi LAN / Wi-Fi Direct — устройства общаются напрямую.

---

## Содержание

- [Быстрый старт](#быстрый-старт)
- [Архитектура](#архитектура)
- [Транспорт и обнаружение узлов](#транспорт-и-обнаружение-узлов)
- [Протокол сообщений и надёжность](#протокол-сообщений-и-надёжность)
- [Мультихоп и маршрутизация](#мультихоп-и-маршрутизация)
- [Звонки в реальном времени](#звонки-в-реальном-времени)
- [Передача файлов](#передача-файлов)
- [Безопасность](#безопасность)
- [Структура проекта](#структура-проекта)
- [Зависимости](#зависимости)
- [Логи и диагностика](#логи-и-диагностика)
- [Инструкция]

---

## Быстрый старт

### Требования
- Flutter SDK ≥ 3.19
- Dart ≥ 3.3
- Для Desktop: macOS 12+ или Windows 10+
- Для Mobile: Android 8+ / iOS 14+

### Установка и запуск

```bash
git clone https://github.com/lena4426/flutter.git
cd flutter
flutter pub get

# Desktop
flutter run -d macos
flutter run -d windows

# Mobile
flutter run -d android
flutter run -d ios

# Посмотреть доступные устройства
flutter devices
```

### Первый запуск
1. Приложение автоматически генерирует Ed25519/X25519 идентификатор и сохраняет его в SharedPreferences.
2. Обнаружение соседей начинается сразу — через mDNS (Bonsoir) по Wi-Fi.
3. Список найденных устройств отображается в боковой панели.
4. Нажми на пир → начни переписку или звонок.

---

## Архитектура

```
┌─────────────────────────────────────────────────────┐
│                   Flutter UI Layer                  │
│  ChatScreen · PeersPanel · CallScreen · FilePanel   │
└────────────────────┬────────────────────────────────┘
                     │ ChangeNotifier (Provider)
┌────────────────────▼────────────────────────────────┐
│               RealP2PService                        │
│   Orchestrates: Identity · Discovery · Transport    │
│   Gossip · FileTransfer · CallService               │
└──┬──────────┬──────────┬────────────┬───────────────┘
   │          │          │            │
┌──▼──┐  ┌───▼───┐  ┌───▼──┐  ┌─────▼──────┐
│mDNS │  │  TCP  │  │Gossip│  │ WebRTC     │
│Disc.│  │Transp.│  │Servic│  │ CallService│
└─────┘  └───────┘  └──────┘  └────────────┘
                     │
              ┌──────▼──────┐
              │  SQLite DB  │
              │ (DbService) │
              └─────────────┘
```

### Ключевые модули

| Модуль | Файл | Назначение |
|---|---|---|
| `RealP2PService` | `real_p2p_service.dart` | Главный оркестратор: связывает все слои |
| `DiscoveryService` | `discovery_service.dart` | mDNS-обнаружение через Bonsoir |
| `TcpTransport` | `tcp_transport.dart` | TCP-соединения, framing, очередь отправки |
| `CryptoUtils` | `crypto_utils.dart` | Ed25519, X25519 ECDH, AES-256-GCM, HKDF |
| `GossipService` | `gossip_service.dart` | Gossip-рассылка, store-and-forward (DTN) |
| `FileTransferService` | `file_transfer.dart` | Чанки 64KB, SHA-256, возобновление |
| `CallService` | `call_service.dart` | WebRTC (аудио / видео / screenshare) |
| `DbService` | `db_service.dart` | SQLite: история, незавершённые transfer'ы |
| `Identity` | `identity.dart` | Генерация/хранение ключей узла |
| `Packet` | `packet.dart` | Структуры пакетов, сериализация |

---

## Транспорт и обнаружение узлов

### mDNS / Zeroconf

Обнаружение выполняется через **Bonsoir** (`_p2pchat._tcp`).  
Каждый узел анонсирует себя с TXT-записью:

```
uid   = <UUID узла>
name  = <отображаемое имя>
xpub  = <X25519 публичный ключ в hex>
ip    = <IPv4-адрес, встроенный в TXT>
```

IP встраивается в TXT-запись напрямую — это устраняет проблему mDNS hostname-resolution на Windows и Android, где `host` может вернуть `NULL`.

**Fallback-цепочка разрешения IP:**
1. Поле `ip` из TXT-записи *(основной путь)*
2. DNS-lookup по mDNS-хосту (таймаут 2 с)
3. `sourceIp` из входящего TCP-подключения (Sybil challenge)

### TCP-транспорт

- Порт: `45678` (по умолчанию)
- Framing: 4-байтовый length-prefix перед каждым пакетом
- Переподключение: автоматически при обрыве, экспоненциальный backoff
- Очередь исходящих сообщений — сохраняется до восстановления соединения

### Топология

Сеть — **полносвязная mesh** среди видимых узлов.  
Каждый узел устанавливает соединения со всеми известными пирами.  
При смене сети (например, переключение Wi-Fi) — автоматическое переоткрытие соединений и переобнаружение через mDNS.

---

## Протокол сообщений и надёжность

### Структура пакета

Каждый пакет содержит:
- `msg_id` — UUID сообщения (дедупликация)
- `packet_id` — UUID пакета (для ACK)
- `sender_uid` / `sender_name` / `sender_xpub`
- `ttl` — time-to-live для gossip (default: 5 хопов)
- `timestamp`
- Зашифрованный payload (AES-256-GCM) + HMAC-подпись отправителя

### ACK и ретраи

```
Отправитель                    Получатель
    │── packet (packet_id) ──────▶│
    │                             │ обрабатывает
    │◀── ACK (packet_id) ─────────│
    │
    │  (нет ACK через 3 с)
    │── retry #1 ────────────────▶│
    │── retry #2 ────────────────▶│  (до 5 попыток)
```

### Дедупликация

- Каждый узел хранит LRU-кэш из 20 000 последних `msg_id`
- При получении дубликата — отбрасывается без обработки и без пересылки
- Защита от петель: пакет не пересылается узлу, от которого он пришёл

### Store-and-Forward (DTN)

Если целевой узел недоступен, сообщение помещается в **DTN-очередь** (Delay-Tolerant Networking) и сохраняется в SQLite. При обнаружении пира — автоматическая доставка очереди.

### Rate-limiting

На каждый входящий узел — скользящее окно: не более 120 пакетов/минуту.  
Превышение — пакеты отбрасываются (защита от спама/перегрузки ретранслятора).

---

## Мультихоп и маршрутизация

### Gossip-протокол

Сообщения, адресованные недоступным напрямую узлам, рассылаются через **gossip**:

1. Узел-отправитель выбирает **3 случайных соседа** (fanout = 3) и передаёт им конверт.
2. Каждый получатель проверяет `msg_id` в кэше — если не видел, пересылает дальше (TTL–1).
3. При TTL = 0 — пакет отбрасывается.
4. `SEEN_GOSSIP_IDS` (LRU 20 000) исключает повторную рассылку.

```
A ──▶ B ──▶ D
 \         ▲
  ──▶ C ───┘
```

Если A хочет достучаться до D (нет прямого соединения), сообщение пройдёт через B и/или C.

### Групповые чаты — Sender Key

Для групп используется схема **Sender Key**:
- У каждого участника — свой симметричный ключ группы (AES-256).
- Ключ распределяется через зашифрованные unicast-сообщения каждому члену группы.
- Сообщение шифруется один раз sender key'ем и gossip'ится всем членам группы.
- При смене состава группы — перевыпуск ключа.

---

## Звонки в реальном времени

### Транспортный стек

| Слой | Технология |
|---|---|
| Медиа | WebRTC (flutter_webrtc) |
| Топология | Mesh — прямые peer-to-peer соединения |
| Сигналинг | Encrypted unicast через TCP (RealP2PService) |
| NAT traversal | STUN (stun.l.google.com), LAN-режим без STUN |
| Аудио | Opus (встроен в WebRTC), echoCancellation + noiseSuppression |
| Видео | VP8/H.264, 1280×720, 30 fps |

### Режимы звонков

- **Аудио** — только голос (минимальная задержка)
- **Видео** — аудио + камера
- **Screenshare** — трансляция экрана + микрофон
- **Групповой** — mesh-топология, отдельный `RTCPeerConnection` на каждого участника

### Параметры качества

- **Буфер джиттера**: управляется WebRTC автоматически (adaptive jitter buffer)
- **Обработка потерь пакетов**: NACK + FEC (Forward Error Correction) — встроено в WebRTC
- **Повторная отправка**: RTX (RTP retransmission) для видео
- **Таймаут ICE**: при состоянии `disconnected` — автоматическое закрытие сессии

### Сбор метрик

Каждые **15 секунд** для каждого участника звонка собирается статистика через `RTCPeerConnection.getStats()`:

| Метрика | Источник |
|---|---|
| RTT (мс) | `remote-inbound-rtp → roundTripTime` |
| Jitter (мс) | `remote-inbound-rtp → jitter` |
| Packet loss (%) | delta `packetsLost / packetsSent` |

Метрики отображаются в UI рядом с именем участника в реальном времени.

### Устойчивость

- При `RTCPeerConnectionState.failed` — сессия удаляется, остальные участники продолжают звонок.
- При потере всех сессий — звонок завершается автоматически.
- UI остаётся интерактивным при любых потерях (управление mic/cam работает независимо от состояния ICE).

---

## Передача файлов

### Протокол

```
Отправитель                          Получатель
│── FILE_HEADER (filename, size,  ──▶│
│   total_chunks, file_hash,          │
│   chunk_key_wrapped) ───────────────│
│                                     │
│── CHUNK_0 (chunk_hash, data) ──────▶│ проверяет SHA-256
│── CHUNK_1 ───────────────────────── │
│   ...                               │
│── CHUNK_N ────────────────────────▶ │
│                                     │ проверяет SHA-256 всего файла
│◀── FILE_ACK / FILE_NACK ────────────│
```

### Параметры

| Параметр | Значение |
|---|---|
| Размер чанка | 64 KB |
| Макс. размер файла | 200 MB |
| Хэш чанка | SHA-256 |
| Хэш файла | SHA-256 (по всем данным) |
| Шифрование | AES-256-GCM, уникальный ключ на каждый transfer |

### Возобновление передачи

Состояние незавершённых transfer'ов сохраняется в SQLite.  
При переподключении к пиру — автоматически возобновляется с последнего подтверждённого чанка.  
Частичная доставка: при обрыве принятые чанки не теряются.

### Ограничение нагрузки

- При активном звонке (`hasActiveCall == true`) — скорость файлопередачи **автоматически снижается** (throttle), чтобы не забить канал медиа-трафиком.
- Параллельные transfer'ы ограничены во избежание перегрузки TCP-соединения.

---

## Безопасность

### Криптографический стек

| Алгоритм | Применение |
|---|---|
| **Ed25519** | Подпись каждого пакета, аутентификация узла |
| **X25519 ECDH** | Выработка попарных сессионных ключей |
| **HKDF-SHA256** | KDF для получения симметричных ключей из ECDH |
| **AES-256-GCM** | Шифрование payload (с AAD) |
| **PBKDF2-SHA256** | Деривация мастер-ключа из пароля |
| **SHA-256** | Хэширование чанков и файлов |

### Аутентификация узлов (анти-Sybil)

При обнаружении нового пира выполняется **challenge-response**:
1. Наш узел отправляет случайный `challenge_id`.
2. Пир подписывает challenge своим Ed25519 приватным ключом и отвечает.
3. Мы верифицируем подпись через `xpub` из mDNS TXT-записи.
4. Пир принимается в список только после успешной верификации.

Deadline challenge'а — **10 секунд**. Непрошедшие challenge — отбрасываются.

### Сквозное шифрование (E2EE)

- Каждая пара узлов вырабатывает уникальный сессионный ключ через X25519.
- Payload каждого пакета зашифрован AES-256-GCM с уникальным nonce.
- Ни один промежуточный ретранслятор не может прочитать содержимое сообщения.

### Защита от спама и подмены

- Rate-limit: 120 пакетов/мин с одного узла.
- Дедупликация по `msg_id` исключает replay-атаки.
- Ed25519-подпись каждого пакета исключает подмену отправителя.
- Gossip-петли предотвращаются через LRU-кэш просмотренных ID.

### Модель угроз

| Угроза | Защита |
|---|---|
| Прослушивание трафика в Wi-Fi | AES-256-GCM E2EE |
| Подмена личности (Sybil) | Ed25519 challenge-response |
| Replay-атаки | `msg_id` дедупликация + timestamp |
| DoS/спам | Rate-limiting, TTL-ограничение gossip |
| Перехват при пересылке через ретранслятор | E2EE — ретранслятор видит только зашифрованный blob |

---

## Структура проекта

```
flutter/
├── lib/
│   ├── main.dart                  ← Entry point, Provider setup
│   ├── theme/
│   │   ├── app_colors.dart        ← Цветовые константы Light/Dark
│   │   └── theme_provider.dart    ← Переключение темы
│   ├── models/
│   │   ├── peer.dart              ← Модель пира {uid, name, ip, xpub}
│   │   └── message.dart           ← ChatMessage
│   ├── p2p/
│   │   ├── p2p_service.dart       ← Абстрактный интерфейс + P2PServiceStub
│   │   ├── real_p2p_service.dart  ← Продакшн-реализация
│   │   ├── identity.dart          ← Генерация и хранение ключей
│   │   ├── discovery_service.dart ← mDNS Bonsoir
│   │   ├── tcp_transport.dart     ← TCP framing, очереди
│   │   ├── crypto_utils.dart      ← Ed25519, X25519, AES-GCM, HKDF
│   │   ├── packet.dart            ← Структуры пакетов
│   │   ├── gossip_service.dart    ← Gossip + Sender Key групп
│   │   ├── file_transfer.dart     ← Chunked file transfer
│   │   ├── call_service.dart      ← WebRTC calls
│   │   └── db_service.dart        ← SQLite хранилище
│   ├── screens/
│   │   └── chat_screen.dart       ← Главный экран чата
│   └── widgets/
│       ├── app_header.dart        ← Заголовок с именем и статусом
│       ├── peers_panel.dart       ← Список найденных устройств
│       ├── chat_area.dart         ← Область сообщений
│       ├── message_input_bar.dart ← Поле ввода + кнопки
│       └── search_dialog.dart     ← Диалог поиска сообщений
├── assets/
│   └── icons/icon.svg
├── macos/                         ← macOS runner
├── test/
├── pubspec.yaml
└── README.md
```

---

## Зависимости

```yaml
dependencies:
  flutter:
    sdk: flutter
  provider: ^6.1.0              # State management
  cryptography: ^2.7.0          # Ed25519, X25519, AES-GCM, HKDF
  crypto: ^3.0.3                # SHA-256
  convert: ^3.1.1               # hex encoding
  bonsoir: ^6.0.0               # mDNS discovery & advertising
  flutter_webrtc: ^0.10.0       # WebRTC audio/video calls
  network_info_plus: ^4.0.0     # Получение IP-адреса
  path_provider: ^2.1.0         # Пути к файлам
  path: ^1.9.0
  shared_preferences: ^2.2.0    # Хранение identity
  uuid: ^4.0.0                  # Генерация ID
  sqflite: ^2.3.0               # SQLite
  sqflite_common_ffi: ^2.3.0    # SQLite для Desktop
```

---

## Логи и диагностика

Все компоненты выводят структурированные логи через `debugPrint` с префиксами:

```
[DISCOVERY] advertise OK port=45678 ip=192.168.1.42
[DISCOVERY] Found: Alice-a1b2c3d4e5f6
[DISCOVERY] Resolved: Alice → 192.168.1.55
[TCP] Connected to 192.168.1.55:45678
[P2P] Challenge sent to Alice (a1b2c3...)
[P2P] Peer verified: Alice
[GOSSIP] Spread msg_id=<uuid> to 3 peers (TTL=5)
[FILE] Sending chunk 12/48 to Alice (64KB)
[CALL] Alice: RTCPeerConnectionStateConnected
[CALL] Stats Alice: RTT=18ms jitter=2ms loss=0.0%
```

Для просмотра логов на мобильном устройстве:
```bash
flutter logs
# или через DevTools:
flutter run --observatory-port=8888
```

---

## Поведение при сбоях

| Сценарий | Поведение системы |
|---|---|
| Пир отключился | mDNS `lost` → удаляется из списка; DTN-очередь сохраняет сообщения |
| Обрыв Wi-Fi | TCP переподключение с backoff; mDNS переобнаружение |
| Смена сети (Wi-Fi → другой AP) | Переопределение IP, новый mDNS-анонс |
| Ретранслятор в цепочке упал | Gossip перестраивает маршрут через оставшихся пиров |
| Участник звонка вышел | Его сессия закрывается; остальные продолжают |
| Файл-transfer оборвался | Чанки сохранены в БД, возобновление при реконнекте |

##Запуск на Windows и macOS
Установи Flutter SDK (≥ 3.19)

bash
# Проверь версию
flutter --version
Клонируй репозиторий

bash
git clone https://github.com/lena4426/flutter.git
cd flutter
Установи зависимости

bash
flutter pub get
🪟 Windows
Требования
Windows 10/11 (64-bit)

PowerShell 5.0+

Visual Studio 2022 (для компиляции C++ кода)

Установка инструментов
Visual Studio 2022 (обязательно)

Скачай с visualstudio.microsoft.com

При установке выбери workload:

"Desktop development with C++"

Убедись, что установлен Windows 10/11 SDK

Проверь настройки Flutter

bash
flutter doctor
Должно быть:

text
[√] Windows version (10.0.22621)
[√] Visual Studio (2022 17.x)
Запуск
bash
# Режим разработки (с горячей перезагрузкой)
flutter run -d windows

# Сборка exe-файла
flutter build windows --release

# Запуск собранного приложения
.\build\windows\x64\runner\Release\p2p_node.exe
🔧 Особенности Windows
Брандмауэр — при первом запуске разреши приложению доступ в сеть

Wi-Fi Direct — работает только на Windows 10/11 с поддержкой Wi-Fi Direct

Пути к файлам — используй обратные слеши (\) или raw-строки: r"C:\Users\..."

🍎 macOS
Требования
macOS 12+ (Monterey или новее)

Xcode 15+

CocoaPods

Установка инструментов
Xcode (обязательно)

bash
# Установка через App Store или:
xcode-select --install
CocoaPods (для iOS-симулятора)

bash
sudo gem install cocoapods
Проверь настройки Flutter

bash
flutter doctor
Должно быть:

text
[✓] Xcode - develop for iOS and macOS (Xcode 15.x)
[✓] CocoaPods (1.15.x)
Запуск
bash
# Режим разработки
flutter run -d macos

# Сборка приложения
flutter build macos --release

# Запуск собранного приложения
open build/macos/Build/Products/Release/p2p_node.app
