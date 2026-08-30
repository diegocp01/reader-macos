#!/usr/bin/env python3
"""End-to-end smoke test and latency probe for the persistent engine."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
INSTALL_ROOT = Path(os.environ.get("KOKORO_READER_HOME", ROOT))
process = subprocess.Popen(
    [
        sys.executable,
        str(ROOT / "python" / "engine.py"),
        "--model-dir",
        str(INSTALL_ROOT / "models" / "Kokoro-82M-bf16"),
    ],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True,
)
assert process.stdin and process.stdout

ready = json.loads(process.stdout.readline())
assert ready["event"] == "ready", ready

started = time.perf_counter()
request = {
    "command": "speak",
    "text": (
        "Kokoro starts speaking the first sentence immediately. "
        "The remaining sentences continue generating in the background. "
        "This makes long selections feel much faster."
    ),
}
process.stdin.write(json.dumps(request) + "\n")
process.stdin.flush()

first_audio = None
chunk_count = 0
while True:
    event = json.loads(process.stdout.readline())
    if event["event"] == "audio":
        chunk_count += 1
        first_audio = first_audio or time.perf_counter()
        assert Path(event["path"]).is_file()
    if event["event"] == "done":
        finished = time.perf_counter()
        break
    if event["event"] == "error":
        raise RuntimeError(event["message"])

process.stdin.close()
process.wait(timeout=10)
assert first_audio is not None
print(
    json.dumps(
        {
            "backend": ready.get("backend"),
            "first_audio_seconds": round(first_audio - started, 3),
            "total_generation_seconds": round(finished - started, 3),
            "chunks": chunk_count,
        }
    )
)
