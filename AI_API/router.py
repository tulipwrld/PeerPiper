from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from ai import ai_chat

mDNSrouter = APIRouter(prefix="/api/mdns", tags=["mdns"])


@mDNSrouter.post("/llm")
async def ask_llm(request: Request):
    try:
        data = await request.json()
        message = str(data.get("message", "")).strip()
        if not message:
            return JSONResponse(status_code=400, content={"error": "Empty message"})

        answer = await ai_chat(message)
        return JSONResponse(status_code=200, content={"answer": answer})
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})
