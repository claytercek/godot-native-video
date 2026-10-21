#!/usr/bin/env python3
"""Shared smoke CLI regressions, using a fake engine (no media/GPU required)."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).with_name("run_smoke.py")
PROBE = "ERROR: Attempt to get non-existent interface function: 'classdb_construct_object3'."


@unittest.skipIf(os.name == "nt", "fake engine uses a POSIX executable script")
class SmokeRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gnv-smoke-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.godot = self.root / "godot"
        self.godot.write_text(f"#!{sys.executable}\n" + '''import json, os, sys, time
print("Godot Engine v" + os.environ.get("TEST_VERSION", "4.7.2") + ".stable", flush=True)
print(os.environ.get("TEST_BANNER", "Vulkan 1.4 - Forward+ - Using Device #0: llvmpipe"), flush=True)
print(os.environ.get("TEST_MESSAGE", "SMOKE: PASS"), flush=True)
print("FAKE_ARGS " + json.dumps(sys.argv[1:]), flush=True)
print("FAKE_PID " + str(os.getpid()), flush=True)
time.sleep(float(os.environ.get("TEST_SLEEP", "0")))
sys.exit(int(os.environ.get("TEST_STATUS", "0")))
''')
        self.godot.chmod(0o755)
        self.log = self.root / "logs/smoke.log"

    def run_smoke(self, expected=0, driver="vulkan", timeout="5", **env):
        result = subprocess.run([
            sys.executable, str(RUNNER), "--godot", str(self.godot),
            "--driver", driver, "--log", str(self.log), "--timeout", timeout,
            "--", "--display-driver", "x11",
        ], env=dict(os.environ, **env), text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertTrue(self.log.is_file())
        return result

    def test_common_invocation_runs_only_synthetic_rendered_smoke(self):
        result = self.run_smoke()
        line = next(line for line in self.log.read_text().splitlines() if line.startswith("FAKE_ARGS "))
        args = json.loads(line.removeprefix("FAKE_ARGS "))
        self.assertEqual(args[-2:], ["--", "--smoke"])
        for option, value in (("--rendering-method", "forward_plus"),
                              ("--rendering-driver", "vulkan"),
                              ("--audio-driver", "Dummy"),
                              ("--display-driver", "x11")):
            self.assertEqual(args[args.index(option) + 1], value)
        self.assertNotIn("--headless", args)
        self.assertNotIn("--file", " ".join(args))
        self.assertIn("LINUX_VALIDATION_LOG_PASS", result.stdout)

    def test_mac_keeps_default_driver_and_accepts_metal(self):
        for api in ("Metal 3.0", "Metal 3.1"):
            with self.subTest(api=api):
                self.run_smoke(driver="default", TEST_BANNER=f"{api} - Forward+ - Using Device #0: Apple - Apple M1")
                self.assertNotIn('"--rendering-driver"', self.log.read_text())

    def test_windows_requires_d3d12_rendering_device(self):
        # Godot's D3D12 get_api_version() uses an underscore feature level.
        for api in ("D3D12 12_0", "D3D12 12_1"):
            with self.subTest(api=api):
                self.run_smoke(driver="d3d12", TEST_BANNER=f"{api} - Forward+ - Using Device #0: Microsoft - Microsoft Basic Render Driver")
        self.run_smoke(expected=1, driver="d3d12")  # Vulkan is not D3D12 proof.

    def test_rejects_missing_or_partial_pass_marker(self):
        for message in ("SMOKE: FAIL", "prefix SMOKE: PASS suffix"):
            with self.subTest(message=message):
                self.run_smoke(expected=1, TEST_MESSAGE=message)

    def test_rejects_engine_and_script_errors_even_after_pass(self):
        for error in ("ERROR: Extension failed", "SCRIPT ERROR: Assertion failed"):
            with self.subTest(error=error):
                self.run_smoke(expected=1, TEST_MESSAGE="SMOKE: PASS\n" + error)

    def test_reuses_exact_46_probe_allowlist(self):
        self.run_smoke(TEST_VERSION="4.6.3", TEST_MESSAGE=PROBE + "\nSMOKE: PASS")
        self.run_smoke(expected=1, TEST_MESSAGE=PROBE + "\nSMOKE: PASS")

    def test_rejects_headless_or_compatibility_banner_even_with_pass(self):
        for banner in ("", "OpenGL API 4.5 - Compatibility - Using Device: llvmpipe",
                       "Vulkan 1.4 - Mobile - Using Device #0: llvmpipe"):
            with self.subTest(banner=banner):
                self.run_smoke(expected=1, TEST_BANNER=banner)

    def test_rejects_nonzero_exit_even_with_pass(self):
        self.run_smoke(expected=1, TEST_STATUS="7")

    def test_timeout_preserves_log_and_reaps_engine_even_after_pass(self):
        result = self.run_smoke(expected=1, timeout="0.5", TEST_SLEEP="30")
        self.assertIn("SMOKE_TIMEOUT", result.stderr)
        text = self.log.read_text()
        self.assertIn("SMOKE: PASS", text)
        pid = int(next(line for line in text.splitlines() if line.startswith("FAKE_PID ")).split()[1])
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main()
