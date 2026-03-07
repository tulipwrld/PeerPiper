import json
import sys

import httpx


def main():
    broker = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8787"
    c = httpx.Client(timeout=10)

    print(c.get(f"{broker}/health").json())

    print(c.post(f"{broker}/v1/register", json={
        "node_id": "edge-a",
        "network_id": "lan-a",
        "endpoint": "smoke",
        "meta": {},
    }).json())

    print(c.post(f"{broker}/v1/route", json={
        "from_network": "lan-a",
        "to_network": "lan-b",
        "to_node": None,
        "payload": {"kind": "test", "text": "hello"},
    }).json())

    pulled = c.get(f"{broker}/v1/pull/lan-b/edge-b").json()
    print(json.dumps(pulled, indent=2, ensure_ascii=False))

    ids = [x["msg_id"] for x in pulled.get("items", [])]
    if ids:
        print(c.post(f"{broker}/v1/ack", json={"message_ids": ids}).json())


if __name__ == "__main__":
    main()
