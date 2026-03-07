# Federation Bridge Module

Отдельный модуль федерации для связки нескольких локальных сетей через центральный bridge/broker.

## Что решает

- Локальные сети `LAN-A` и `LAN-B` работают как раньше (без изменений в Flutter-коде).
- Если получатель не найден в локальной сети, клиент/коннектор может отправить зашифрованный envelope в broker.
- Broker держит очередь и отдает сообщения удаленной сети через pull-механику.

## Архитектура

- `broker.py`: центральный HTTP-сервис (FastAPI + SQLite).
- `edge_connector.py`: агент сети (outbox -> broker -> inbox).

## Установка

```bash
pip install -r federation_bridge/requirements.txt
```

## Запуск broker

```bash
python federation_bridge/broker.py
```

Сервис слушает `0.0.0.0:8787`.

Проверка:

```bash
curl http://127.0.0.1:8787/health
```

## Запуск edge-коннектора

Пример для сети A:

```bash
python federation_bridge/edge_connector.py \
  --broker http://127.0.0.1:8787 \
  --network-id lan-a \
  --node-id edge-a \
  --outbox federation_bridge/lan_a/outbox \
  --inbox federation_bridge/lan_a/inbox
```

Пример для сети B:

```bash
python federation_bridge/edge_connector.py \
  --broker http://127.0.0.1:8787 \
  --network-id lan-b \
  --node-id edge-b \
  --outbox federation_bridge/lan_b/outbox \
  --inbox federation_bridge/lan_b/inbox
```

## Формат outbox-файла

Создай JSON-файл в `outbox`, например:

```json
{
  "to_network": "lan-b",
  "to_node": null,
  "payload": {
    "kind": "e2ee_text",
    "target_uid": "<peer_uid>",
    "ciphertext": "..."
  }
}
```

`edge_connector` отправит его в broker и переместит файл в `sent/`.

## Формат inbox-файла

После pull, сообщения появятся в `inbox/<msg_id>.json`:

```json
{
  "msg_id": "...",
  "from_network": "lan-a",
  "to_network": "lan-b",
  "to_node": null,
  "payload": { ... },
  "created_at": 1234567890
}
```

## Интеграция в текущий мессенджер

Минимальный путь без ломки кода:

1. В месте, где direct-send не смог доставить peer в локальной сети, складывать envelope в `outbox/*.json`.
2. Отдельный процесс `edge_connector.py` пересылает это в другую сеть.
3. На принимающей стороне читать `inbox/*.json` и передавать payload в текущий обработчик входящих пакетов.

Важно: broker не должен видеть открытый текст — только уже зашифрованные payload/envelope.

## API broker

- `POST /v1/register`
- `POST /v1/route`
- `GET  /v1/pull/{network_id}/{node_id}?limit=100`
- `POST /v1/ack`
- `POST /v1/prune`
- `GET  /health`

## Нагрузочное замечание

Broker хранит очередь в SQLite. Для moderate нагрузки (десятки/сотни msg/s) достаточно.
Если потребуется больше — заменить SQLite на Postgres/Redis и вынести broker в отдельный сервис.
