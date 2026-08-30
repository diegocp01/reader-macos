# Kokoro Reader

Click a macOS menu-bar icon to read whatever text you selected with the mouse. No hotkey, account, cloud API, or internet connection is required after installation.

## Requirements

- Apple Silicon Mac: M1 or newer
- macOS 14 or newer
- About 1.5 GB of free disk space
- Apple Command Line Tools (`xcode-select --install` if needed)

Intel Macs are not currently supported because the MLX engine requires Apple Silicon.

## Install

1. Download this repository with **Code → Download ZIP** and unzip it.
2. Double-click `install.command`. If macOS blocks it, Control-click it and choose **Open**.
3. On first launch, allow **Kokoro Reader** in **System Settings → Privacy & Security → Accessibility**.

The installer creates:

- `~/Applications/Kokoro Reader.app`
- `~/Library/Application Support/Kokoro Reader/` for the private Python runtime and model

No administrator password is required.

Because public builds are compiled and ad-hoc signed on each Mac, installing a rebuilt update may require toggling Kokoro Reader off and on again under Accessibility.

## Use

1. Select text with the mouse.
2. Left-click the waveform icon in the menu bar.
3. Left-click again to stop. Right-click for Read, Stop, or Quit.

The app pre-warms Kokoro at launch and streams small sentence batches for low time-to-first-audio.

## Offline and privacy

After installation, selected text never leaves the Mac. Kokoro runs locally through Apple MLX/Metal, and generated audio is written only to the user's temporary folder for playback.

## Model download and licensing

Model weights are intentionally excluded from GitHub. The installer downloads three required files from `mlx-community/Kokoro-82M-bf16` at a pinned revision and verifies them using `support/model-checksums.sha256`.

The Kokoro weights and MLX conversion are Apache 2.0 licensed. The `kokoro-mlx` inference package is MIT licensed. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Development

```sh
./scripts/install-uv.sh
KOKORO_READER_HOME="$PWD/.test-install" ./scripts/setup-runtime.sh
KOKORO_READER_HOME="$PWD/.test-install" ./scripts/download-model.sh
./scripts/build.sh
```

Run the latency smoke test on an unsandboxed Apple Silicon session:

```sh
KOKORO_READER_HOME="$PWD/.test-install" .test-install/.venv/bin/python3 tests/engine_smoke.py
```

## Uninstall

Double-click `uninstall.command`. It moves the app and support files to the Trash so they remain recoverable.

## License

Kokoro Reader source code is available under the [MIT License](LICENSE).
