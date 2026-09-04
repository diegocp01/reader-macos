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
3. Select text and click the waveform. If access is needed, choose **Open Settings**, then allow **Kokoro Reader** in **System Settings → Privacy & Security → Accessibility**. On macOS 27, this pane is named **Device Control and Data Access**. Return to your text and click the waveform again.

The app enables **Launch at Login** automatically so the menu-bar icon returns after a logout or restart. macOS may show a background-item notification; if approval is required, enable **Kokoro Reader** in **System Settings → General → Login Items**. Right-click the menu-bar icon to turn Launch at Login off later.

The installer creates:

- `~/Applications/Kokoro Reader.app`
- `~/Library/Application Support/Kokoro Reader/` for the private Python runtime and model

No administrator password is required.

Public builds are compiled and ad-hoc signed on each Mac. Updating the app can invalidate the permission saved for the previous build, even when its switch still appears enabled. The installer waits for the old app to quit before replacing it; it does not reset permissions automatically.

### Permission enabled, but reading is still blocked

1. Double-click `repair-permissions.command` in the downloaded repository and confirm the repair.
2. Click the waveform and choose **Open Settings** if prompted. Enable **Kokoro Reader** again under **Privacy & Security → Accessibility**, or **Device Control and Data Access** on macOS 27.
3. Select text and click the waveform. If access is still blocked, quit and reopen Kokoro Reader once after approving it.

The repair quits the running reader, clears **only** its stale Accessibility permission, and reopens the installed app. It builds a small app helper using Apple Command Line Tools so it can also stop older versions safely; it does not reinstall the app, download models, change login preferences, or clear other apps' permissions. Any current reading stops. If quitting or resetting fails, the command stops and prints the error.

Without Command Line Tools, remove Kokoro Reader from that settings pane using **−**, then use **+** to add `~/Applications/Kokoro Reader.app` again and enable it. Simply switching the old entry off and on may retain the stale signature. The app's right-click **Text Access Help…** menu also shows the installed path.

This recovery does not make ad-hoc signatures stable across updates. Releases signed consistently with a Developer ID identity can preserve their designated requirement across builds; the repo currently distributes locally built apps, so reauthorization can still be necessary. See [Apple's code-signing requirements documentation](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

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

Run the installer/permission workflow tests with `python3 -m unittest discover -s tests -p 'test_*.py' -v`. They use temporary app directories and stub system commands, so they do not reset real permissions or stop the installed reader. `KOKORO_READER_APPLICATIONS_DIR` overrides the app directory for isolated install/repair testing; normal users can leave it unset.

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

Turn off **Launch at Login** from the app's right-click menu, then double-click `uninstall.command`. It moves the app and support files to the Trash so they remain recoverable.

## License

Kokoro Reader source code is available under the [MIT License](LICENSE).
