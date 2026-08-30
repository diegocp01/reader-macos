#!/usr/bin/env python3
"""Persistent MLX Kokoro engine with low-latency chunk streaming."""

from __future__ import annotations

import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import traceback


PROTOCOL_OUT = sys.stdout
EMIT_LOCK = threading.Lock()


def emit(event: str, **values: object) -> None:
    with EMIT_LOCK:
        print(json.dumps({"event": event, **values}, ensure_ascii=False), file=PROTOCOL_OUT, flush=True)


def load_engine(model_dir: Path):
    with contextlib.redirect_stdout(sys.stderr):
        from kokoro_mlx import KokoroTTS

        tts = KokoroTTS.from_pretrained(model_dir)
        # MLX compiles kernels lazily. Pay that cost at launch, not on first click.
        tts.generate("Ready.", voice="af_heart", sample_rate=24_000)
    return tts


def low_latency_text_chunks(text: str, max_chars: int = 120) -> list[str]:
    """Split at natural boundaries so the first audio can start quickly."""
    sentences = re.split(r"(?<=[.!?…])\s+|\n+", text.strip())
    chunks: list[str] = []
    current = ""
    for sentence in filter(None, (part.strip() for part in sentences)):
        words = sentence.split()
        pieces: list[str] = []
        piece = ""
        for word in words:
            candidate = f"{piece} {word}".strip()
            if piece and len(candidate) > max_chars:
                pieces.append(piece)
                piece = word
            else:
                piece = candidate
        if piece:
            pieces.append(piece)

        for piece in pieces:
            candidate = f"{current} {piece}".strip()
            if current and len(candidate) > max_chars:
                chunks.append(current)
                current = piece
            else:
                current = candidate
    if current:
        chunks.append(current)
    return chunks


def synthesize_stream(
    tts,
    text: str,
    output_dir: Path,
    request_id: int,
    cancelled: threading.Event,
) -> None:
    import soundfile as sf

    try:
        emit("stream_start", request=request_id)
        produced = 0
        with contextlib.redirect_stdout(sys.stderr):
            for index, text_chunk in enumerate(low_latency_text_chunks(text)):
                if cancelled.is_set():
                    emit("cancelled", request=request_id)
                    return
                result = tts.generate(
                    text_chunk,
                    voice="af_heart",
                    speed=1.0,
                    sample_rate=24_000,
                    language="en-us",
                )
                destination = output_dir / f"speech-{os.getpid()}-{request_id}-{index}.wav"
                sf.write(destination, result.audio, result.sample_rate)
                produced += 1
                emit("audio", request=request_id, path=str(destination), index=index)
        if not produced:
            raise RuntimeError("Kokoro produced no audio for the selected text.")
        emit("done", request=request_id)
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        emit("error", request=request_id, message=str(error))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    required = [
        args.model_dir / "config.json",
        args.model_dir / "kokoro-v1_0.safetensors",
        args.model_dir / "voices" / "af_heart.safetensors",
    ]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        emit("error", message="Missing MLX model files: " + ", ".join(missing))
        return 1

    try:
        tts = load_engine(args.model_dir)
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        emit("error", message=f"Could not load MLX Kokoro: {error}")
        return 1

    emit("ready", backend="mlx")
    if args.check:
        return 0

    output_dir = Path(tempfile.gettempdir()) / "kokoro-reader"
    output_dir.mkdir(parents=True, exist_ok=True)
    worker: threading.Thread | None = None
    cancelled = threading.Event()
    request_id = 0

    for raw_line in sys.stdin:
        try:
            request = json.loads(raw_line)
            command = request.get("command")
            if command == "stop":
                cancelled.set()
                continue
            if command != "speak":
                continue

            text = str(request.get("text", "")).strip()
            if not text:
                raise ValueError("No text was provided.")
            if len(text) > 50_000:
                raise ValueError("Selection is too long; choose less than 50,000 characters.")

            cancelled.set()
            if worker and worker.is_alive():
                worker.join()
            cancelled = threading.Event()
            request_id += 1
            worker = threading.Thread(
                target=synthesize_stream,
                args=(tts, text, output_dir, request_id, cancelled),
                daemon=True,
            )
            worker.start()
        except Exception as error:
            traceback.print_exc(file=sys.stderr)
            emit("error", message=str(error))

    cancelled.set()
    if worker and worker.is_alive():
        worker.join()
    tts.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
