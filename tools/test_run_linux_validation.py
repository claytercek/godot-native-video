#!/usr/bin/env python3
"""Xvfb startup CLI regressions, without Godot, X11, or media toolchains."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

TOOLS = pathlib.Path(__file__).resolve().parent


class XvfbStartupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gnv-xvfb-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.repo = self.root / "repo"
        tools = self.repo / "tools"
        tools.mkdir(parents=True)
        for name in ("run_linux_validation.sh", "check_linux_validation_log.py"):
            shutil.copyfile(TOOLS / name, tools / name)
        library = self.repo / "project/lib/libnative_video.so"
        library.parent.mkdir(parents=True)
        library.write_bytes(b"test library")
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        for name in ("h264-aac.mp4", "h264-silent.mp4", "h264-multitrack.mp4",
                     "h264-multitrack.mkv", "invalid.mp4"):
            (self.fixtures / name).write_bytes(b"test fixture")
        self.results = self.root / "results"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.executable("pkg-config", "#!/bin/sh\necho test-version\n")
        self.executable("gst-inspect-1.0", "#!/bin/sh\nexit 1\n")
        self.executable("godot", f"#!{sys.executable}\n" + '''import os
import pathlib
import sys
if "--version" in sys.argv:
    print("4.7.2.stable")
else:
    with pathlib.Path(os.environ["GNV_TEST_CALLS"]).open("a") as calls:
        calls.write(os.environ.get("DISPLAY", "unset") + " " + " ".join(sys.argv[1:]) + "\\n")
    print("SMOKE: PASS\\nPRESENTATION_EPOCH_PASS\\nLINUX_TRANSPORT_ORACLES_PASS\\nLINUX_TRANSPORT_PASS")
''')
        self.executable("Xvfb", f"#!{sys.executable}\n" + '''import os
import pathlib
import time
pathlib.Path(os.environ["GNV_TEST_PID"]).write_text(str(os.getpid()))
print("fake Xvfb diagnostic", flush=True)
mode = os.environ["GNV_TEST_MODE"]
if mode == "early-exit":
    raise SystemExit(7)
if mode == "delayed":
    time.sleep(5.5)
    os.write(3, b"0\\n")
elif mode == "partial":
    os.write(3, b"4")
    time.sleep(0.4)
    os.write(3, b"2\\n")
elif mode == "incomplete":
    os.write(3, b"42")
elif mode == "invalid":
    os.write(3, (os.environ["GNV_TEST_DISPLAY"] + "\\n").encode())
time.sleep(120)
''')
        self.icd = self.root / "lvp.json"
        self.icd.write_text("{}")
        self.calls = self.root / "godot-calls"
        self.pid_file = self.root / "xvfb-pid"

    def executable(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_validation(self, mode, display=""):
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                   GNV_LVP_ICD=str(self.icd), GNV_TEST_MODE=mode,
                   GNV_TEST_DISPLAY=display, GNV_TEST_CALLS=str(self.calls),
                   GNV_TEST_PID=str(self.pid_file))
        start = time.monotonic()
        result = subprocess.run([
            "bash", str(self.repo / "tools/run_linux_validation.sh"),
            "--fixtures", str(self.fixtures), "--results", str(self.results),
            "--rendered-only", "--skip-build", "--renderer", "software-xvfb",
            "--godot", str(self.bin / "godot"),
        ], env=env, text=True, capture_output=True, timeout=40)
        elapsed = time.monotonic() - start
        # Both successful validation and startup failures must reap the server.
        pid = int(self.pid_file.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        return result, elapsed

    def assert_success(self, result, display):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("LINUX_VALIDATION_PASS", result.stdout)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(len(calls), 5)
        for call in calls:
            self.assertTrue(call.startswith(f":{display} "), call)
            self.assertIn("--display-driver x11 --rendering-method forward_plus --rendering-driver vulkan", call)

    def assert_failure(self, result, reason):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(reason, result.stderr)
        self.assertIn(str(self.results / "xvfb.log"), result.stderr)
        self.assertIn("fake Xvfb diagnostic", result.stderr)
        self.assertNotIn("LINUX_VALIDATION_PASS", result.stdout)
        self.assertFalse(self.calls.exists(), "Godot must not run before Xvfb is ready")

    def test_readiness_delayed_beyond_five_seconds(self):
        result, elapsed = self.run_validation("delayed")
        self.assert_success(result, "0")
        self.assertGreater(elapsed, 5)

    def test_partial_line_waits_for_newline(self):
        result, _ = self.run_validation("partial")
        self.assert_success(result, "42")

    def test_incomplete_line_times_out(self):
        result, elapsed = self.run_validation("incomplete")
        self.assert_failure(result, "timed out after 30s")
        self.assertGreater(elapsed, 28)
        self.assertLess(elapsed, 35)

    def test_invalid_display_is_rejected(self):
        for display in ("", "abc", ":42", "-1", " 42", "42 ", "4 2"):
            with self.subTest(display=display):
                result, _ = self.run_validation("invalid", display)
                self.assert_failure(result, "invalid display number")

    def test_early_exit_reports_status_and_log(self):
        result, elapsed = self.run_validation("early-exit")
        self.assert_failure(result, "exited before readiness (status 7)")
        self.assertLess(elapsed, 5)

    def test_missing_readiness_times_out(self):
        result, elapsed = self.run_validation("timeout")
        self.assert_failure(result, "timed out after 30s")
        self.assertGreater(elapsed, 28)
        self.assertLess(elapsed, 35)


if __name__ == "__main__":
    unittest.main()
