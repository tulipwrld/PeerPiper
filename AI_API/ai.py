import asyncio
import os
from typing import Optional

_pipe = None
_pipe_error = ""
_pipe_mode = "none"  # hf | stub
_pipe_lock = asyncio.Lock()


def _simple_stub_answer(message: str) -> str:
    text = message.strip()
    if not text:
        return "Напиши вопрос, и я постараюсь помочь."
    lower = text.lower()
    if "привет" in lower:
        return "Привет. Я запущен в fallback-режиме AI и готов отвечать."
    if "кто ты" in lower:
        return "Я локальный AI-ассистент в fallback-режиме. Основная модель сейчас недоступна."
    return f"[Fallback AI] Получил запрос: {text}"


async def _get_pipe():
    global _pipe, _pipe_error, _pipe_mode
    if _pipe is not None:
        return _pipe

    async with _pipe_lock:
        if _pipe is not None:
            return _pipe

        model_name = os.getenv("AI_MODEL_NAME", "microsoft/Phi-3-mini-4k-instruct")
        use_cuda = os.getenv("AI_USE_CUDA", "0") == "1"
        candidates = [
            model_name,
            "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
            "distilgpt2",
        ]

        try:
            import torch
            from transformers import AutoModelForCausalLM, AutoTokenizer, pipeline
        except Exception as e:
            _pipe_error = f"Import error: {e}"
            _pipe_mode = "stub"
            _pipe = "stub"
            return _pipe

        device_map: Optional[str] = "auto" if use_cuda else None
        torch_dtype = "auto" if use_cuda else torch.float32

        for candidate in candidates:
            try:
                model_kwargs = {
                    "torch_dtype": torch_dtype,
                    "trust_remote_code": "phi" in candidate.lower(),
                }
                if device_map is not None:
                    model_kwargs["device_map"] = device_map

                model = AutoModelForCausalLM.from_pretrained(candidate, **model_kwargs)
                tokenizer = AutoTokenizer.from_pretrained(candidate)
                _pipe = pipeline("text-generation", model=model, tokenizer=tokenizer)
                _pipe_error = ""
                _pipe_mode = "hf"
                return _pipe
            except Exception as e:
                _pipe_error = f"Model init error ({candidate}): {e}"

        _pipe_mode = "stub"
        _pipe = "stub"
        return _pipe


async def ai_chat(message: str) -> str:
    global _pipe_error, _pipe_mode
    pipe = await _get_pipe()

    if pipe == "stub" or _pipe_mode == "stub":
        details = _pipe_error or "no details"
        stub = _simple_stub_answer(message)
        return f"{stub}\n\n[info] Основная модель недоступна: {details}"

    generation_args = {
        "max_new_tokens": 220,
        "return_full_text": False,
        "temperature": 0.2,
        "do_sample": True,
    }

    prompt = (
        "Ты дружелюбный ИИ-ассистент. Отвечай по-русски кратко и по делу.\n"
        f"Пользователь: {message}\n"
        "Ассистент:"
    )

    try:
        output = await asyncio.to_thread(pipe, prompt, **generation_args)
        if not output:
            return "Пустой ответ от модели."
        first = output[0]
        if isinstance(first, dict):
            text = str(first.get("generated_text", "")).strip()
        else:
            text = str(first).strip()
        return text or "Пустой ответ от модели."
    except Exception as e:
        return f"AI generation error: {e}"
