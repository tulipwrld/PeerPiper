import os
import sqlite3
import time
import uuid
import json
from contextlib import contextmanager
from typing import Any

from fastapi import FastAPI
from pydantic import BaseModel, Field

DB_PATH = os.getenv("FEDERATION_DB", "federation_bridge/broker.db")
DELIVERED_TTL_SEC = int(os.getenv("FEDERATION_DELIVERED_TTL_SEC", "604800"))


class RegisterReq(BaseModel):
    node_id: str
    network_id: str
    endpoint: str = ""
    meta: dict[str, Any] = Field(default_factory=dict)


class RouteReq(BaseModel):
    from_network: str
    to_network: str
    to_node: str | None = None
    payload: dict[str, Any]


class AckReq(BaseModel):
    message_ids: list[str]


@contextmanager
def _db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def _init_db() -> None:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with _db() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS nodes (
              node_id TEXT PRIMARY KEY,
              network_id TEXT NOT NULL,
              endpoint TEXT NOT NULL DEFAULT '',
              meta_json TEXT NOT NULL DEFAULT '{}',
              last_seen INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
              msg_id TEXT PRIMARY KEY,
              from_network TEXT NOT NULL,
              to_network TEXT NOT NULL,
              to_node TEXT,
              payload_json TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              delivered INTEGER NOT NULL DEFAULT 0,
              delivered_at INTEGER
            )
            """
        )
        conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_pull ON messages(to_network, to_node, delivered, created_at)")


app = FastAPI(title="Federation Bridge Broker", version="1.0.0")


@app.on_event("startup")
def _startup() -> None:
    _init_db()


@app.get("/health")
def health() -> dict[str, Any]:
    return {"ok": True, "db": DB_PATH}


@app.post("/v1/register")
def register(req: RegisterReq) -> dict[str, Any]:
    now = int(time.time())
    with _db() as conn:
        conn.execute(
            """
            INSERT INTO nodes(node_id, network_id, endpoint, meta_json, last_seen)
            VALUES (?, ?, ?, json(?), ?)
            ON CONFLICT(node_id) DO UPDATE SET
              network_id=excluded.network_id,
              endpoint=excluded.endpoint,
              meta_json=excluded.meta_json,
              last_seen=excluded.last_seen
            """,
            (req.node_id, req.network_id, req.endpoint, json.dumps(req.meta), now),
        )
    return {"ok": True, "ts": now}


@app.post("/v1/route")
def route(req: RouteReq) -> dict[str, Any]:
    msg_id = uuid.uuid4().hex
    now = int(time.time())
    with _db() as conn:
        conn.execute(
            """
            INSERT INTO messages(msg_id, from_network, to_network, to_node, payload_json, created_at, delivered)
            VALUES (?, ?, ?, ?, json(?), ?, 0)
            """,
            (
                msg_id,
                req.from_network,
                req.to_network,
                req.to_node,
                json.dumps(req.payload),
                now,
            ),
        )
    return {"ok": True, "msg_id": msg_id, "queued_at": now}


@app.get("/v1/pull/{network_id}/{node_id}")
def pull(network_id: str, node_id: str, limit: int = 100) -> dict[str, Any]:
    lim = max(1, min(limit, 1000))
    with _db() as conn:
        rows = conn.execute(
            """
            SELECT msg_id, from_network, to_network, to_node, payload_json, created_at
            FROM messages
            WHERE delivered = 0
              AND to_network = ?
              AND (to_node IS NULL OR to_node = ?)
            ORDER BY created_at ASC
            LIMIT ?
            """,
            (network_id, node_id, lim),
        ).fetchall()

    items = []
    for r in rows:
        payload = r["payload_json"]
        try:
            payload_data = json.loads(payload)
        except Exception:
            payload_data = {"raw": payload}
        items.append(
            {
                "msg_id": r["msg_id"],
                "from_network": r["from_network"],
                "to_network": r["to_network"],
                "to_node": r["to_node"],
                "payload": payload_data,
                "created_at": r["created_at"],
            }
        )
    return {"ok": True, "items": items}


@app.post("/v1/ack")
def ack(req: AckReq) -> dict[str, Any]:
    if not req.message_ids:
        return {"ok": True, "updated": 0}
    now = int(time.time())
    with _db() as conn:
        q = ",".join(["?"] * len(req.message_ids))
        cur = conn.execute(
            f"""
            UPDATE messages
            SET delivered = 1, delivered_at = ?
            WHERE msg_id IN ({q})
            """,
            [now, *req.message_ids],
        )
        updated = cur.rowcount
    return {"ok": True, "updated": updated}


@app.post("/v1/prune")
def prune() -> dict[str, Any]:
    now = int(time.time())
    cutoff = now - DELIVERED_TTL_SEC
    with _db() as conn:
        cur = conn.execute(
            "DELETE FROM messages WHERE delivered = 1 AND delivered_at IS NOT NULL AND delivered_at < ?",
            (cutoff,),
        )
    return {"ok": True, "deleted": cur.rowcount, "cutoff": cutoff}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("broker:app", host="0.0.0.0", port=8787, reload=False)
