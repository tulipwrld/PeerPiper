import argparse
import json
import os
import shutil
import time
from pathlib import Path

import httpx


def _post_json(client: httpx.Client, url: str, body: dict):
    r = client.post(url, json=body, timeout=15)
    r.raise_for_status()
    return r.json()


def register(client: httpx.Client, broker: str, network_id: str, node_id: str):
    _post_json(
        client,
        f"{broker}/v1/register",
        {
            "node_id": node_id,
            "network_id": network_id,
            "endpoint": "edge-connector",
            "meta": {},
        },
    )


def flush_outbox(
    client: httpx.Client,
    broker: str,
    network_id: str,
    outbox: Path,
    sent: Path,
):
    outbox.mkdir(parents=True, exist_ok=True)
    sent.mkdir(parents=True, exist_ok=True)

    for f in sorted(outbox.glob("*.json")):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            to_network = str(data.get("to_network", "")).strip()
            to_node = data.get("to_node")
            payload = data.get("payload")
            if not to_network or payload is None:
                raise ValueError("outbox JSON must contain to_network and payload")

            res = _post_json(
                client,
                f"{broker}/v1/route",
                {
                    "from_network": network_id,
                    "to_network": to_network,
                    "to_node": to_node,
                    "payload": payload,
                },
            )
            target = sent / f"{f.stem}.{res.get('msg_id','sent')}.json"
            shutil.move(str(f), target)
        except Exception as e:
            print(f"[EDGE] outbox send failed for {f.name}: {e}")


def pull_inbox(
    client: httpx.Client,
    broker: str,
    network_id: str,
    node_id: str,
    inbox: Path,
    limit: int,
):
    inbox.mkdir(parents=True, exist_ok=True)

    r = client.get(
        f"{broker}/v1/pull/{network_id}/{node_id}",
        params={"limit": limit},
        timeout=20,
    )
    r.raise_for_status()
    body = r.json()
    items = body.get("items", [])
    if not items:
        return 0

    ack_ids = []
    for item in items:
        msg_id = item["msg_id"]
        path = inbox / f"{msg_id}.json"
        if not path.exists():
            path.write_text(json.dumps(item, ensure_ascii=False, indent=2), encoding="utf-8")
        ack_ids.append(msg_id)

    _post_json(client, f"{broker}/v1/ack", {"message_ids": ack_ids})
    return len(ack_ids)


def main():
    p = argparse.ArgumentParser(description="Federation edge connector")
    p.add_argument("--broker", required=True, help="Broker base URL, e.g. http://host:8787")
    p.add_argument("--network-id", required=True, help="Local network id (lan-a, office, etc)")
    p.add_argument("--node-id", required=True, help="Connector node id")
    p.add_argument("--outbox", default="federation_bridge/outbox")
    p.add_argument("--inbox", default="federation_bridge/inbox")
    p.add_argument("--poll-sec", type=float, default=2.0)
    p.add_argument("--register-sec", type=float, default=15.0)
    p.add_argument("--pull-limit", type=int, default=100)
    args = p.parse_args()

    outbox = Path(args.outbox)
    inbox = Path(args.inbox)
    sent = outbox.parent / "sent"

    broker = args.broker.rstrip("/")
    last_register = 0.0

    with httpx.Client() as client:
        while True:
            now = time.time()
            try:
                if now - last_register >= args.register_sec:
                    register(client, broker, args.network_id, args.node_id)
                    last_register = now

                flush_outbox(client, broker, args.network_id, outbox, sent)
                pulled = pull_inbox(
                    client,
                    broker,
                    args.network_id,
                    args.node_id,
                    inbox,
                    args.pull_limit,
                )
                if pulled:
                    print(f"[EDGE] pulled {pulled} item(s)")
            except Exception as e:
                print(f"[EDGE] loop error: {e}")

            time.sleep(args.poll_sec)


if __name__ == "__main__":
    main()
