import contextlib
from contextlib import asynccontextmanager

import asyncio
import uvicorn
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from net import on_net
from router import mDNSrouter


@asynccontextmanager
async def lifespan(app: FastAPI):
    task = asyncio.create_task(on_net())
    try:
        yield
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


app = FastAPI(lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
app.include_router(mDNSrouter)


@app.get("/health")
async def health():
    return {"ok": True}


if __name__ == "__main__":
    uvicorn.run("main:app", reload=False, host="127.0.0.1", port=3000)
