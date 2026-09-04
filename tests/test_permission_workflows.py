"""Exercise installer/repair failure boundaries without touching real TCC or apps."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class PermissionWorkflows(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="kokoro-permission-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        for name in ("scripts/install-app.sh", "repair-permissions.command"):
            shutil.copy2(ROOT / name, self.root / name)
        self.apps = self.root / "Applications"
        self.app = self.apps / "Kokoro Reader.app"
        self.app.mkdir(parents=True)
        self.source = self.root / ".build/app/Kokoro Reader.app"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls"
        self.env = dict(os.environ, KOKORO_READER_APPLICATIONS_DIR=str(self.apps),
                        CALL_LOG=str(self.log), PATH=f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin")
        self.write_executable(self.source / "Contents/MacOS/KokoroReader", '''
printf 'helper %s\n' "$*" >> "$CALL_LOG"
if [[ "$1" == --quit-running ]]; then exit "${QUIT_EXIT:-0}"; fi
echo enabled
''')
        self.write_executable(self.root / "scripts/build.sh", '''
echo build >> "$CALL_LOG"
exit "${BUILD_EXIT:-0}"
''')
        self.write_executable(self.bin / "codesign", '''
echo verify >> "$CALL_LOG"
if [[ "$*" == *"/Applications/"* ]]; then exit "${DEST_VERIFY_EXIT:-0}"; fi
exit "${VERIFY_EXIT:-0}"
''')
        self.write_executable(self.bin / "ditto", '''
echo copy >> "$CALL_LOG"
/bin/cp -R "$1/." "$2/"
''')
        self.write_executable(self.bin / "open", 'echo open >> "$CALL_LOG"')
        self.write_executable(self.bin / "sleep", 'exit 0')
        self.write_executable(self.bin / "tccutil", '''
printf 'tccutil %s\n' "$*" >> "$CALL_LOG"
exit "${RESET_EXIT:-0}"
''')

    def write_executable(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/zsh\nset -eu\n" + content)
        path.chmod(0o755)

    def run_script(self, script, answer="y\n", **overrides):
        result = subprocess.run(["/bin/zsh", str(self.root / script)], input=answer,
                                text=True, capture_output=True,
                                env=dict(self.env, **overrides), timeout=15)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return result, calls

    def test_install_quits_before_copy_without_resetting_permission(self):
        result, calls = self.run_script("scripts/install-app.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["build", "verify", "helper --quit-running", "copy", "verify",
                                 "open", "helper --launch-at-login-status"])

    def test_install_stops_if_running_app_cannot_quit(self):
        result, calls = self.run_script("scripts/install-app.sh", QUIT_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["build", "verify", "helper --quit-running"])

    def test_install_rejects_invalid_source_before_execution(self):
        result, calls = self.run_script("scripts/install-app.sh", VERIFY_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["build", "verify"])

    def test_invalid_installed_copy_is_not_launched(self):
        result, calls = self.run_script("scripts/install-app.sh", DEST_VERIFY_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["build", "verify", "helper --quit-running", "copy", "verify"])

    def test_install_build_failure_leaves_running_app_alone(self):
        result, calls = self.run_script("scripts/install-app.sh", BUILD_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["build"])

    def test_repair_quits_resets_only_reader_and_reopens(self):
        result, calls = self.run_script("repair-permissions.command")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["build", "helper --quit-running",
                                 "tccutil reset Accessibility com.local.kokoro-reader", "open"])

    def test_cancelled_repair_has_no_side_effects(self):
        result, calls = self.run_script("repair-permissions.command", answer="n\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_repair_requires_installed_app(self):
        self.app.rmdir()
        result, calls = self.run_script("repair-permissions.command")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_repair_stops_on_build_quit_or_reset_failure(self):
        for variable, expected in (("BUILD_EXIT", ["build"]),
                                   ("QUIT_EXIT", ["build", "helper --quit-running"]),
                                   ("RESET_EXIT", ["build", "helper --quit-running",
                                                   "tccutil reset Accessibility com.local.kokoro-reader"])):
            with self.subTest(variable=variable):
                self.log.unlink(missing_ok=True)
                result, calls = self.run_script("repair-permissions.command", **{variable: "1"})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, expected)


if __name__ == "__main__":
    unittest.main()
