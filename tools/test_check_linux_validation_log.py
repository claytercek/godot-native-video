#!/usr/bin/env python3
"""CLI regressions for validation evidence filtering (no Godot required)."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

CHECKER = pathlib.Path(__file__).with_name("check_linux_validation_log.py")
MARKER = "LINUX_TRANSPORT_PASS"
PROBES = (
    "variant_get_type_by_name",
    "classdb_construct_object3",
    "classdb_register_extension_class6",
)


def diagnostic(probe):
    return f"ERROR: Attempt to get non-existent interface function: '{probe}'."


class ValidationLogTests(unittest.TestCase):
    def check_log(self, lines, expected, version="4.6.3", marker=True, physical=False):
        with tempfile.TemporaryDirectory(prefix="gnv-log-test-") as directory:
            log = pathlib.Path(directory) / "godot.log"
            log.write_text(
                "\n".join([
                    *lines,
                    f"Godot Engine v{version}.stable - https://godotengine.org",
                    *([MARKER] if marker else []),
                ]) + "\n"
            )
            command = [sys.executable, str(CHECKER), str(log), "--marker", MARKER]
            if physical:
                command.append("--physical")
            result = subprocess.run(command, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_accepts_each_exact_known_46_probe(self):
        for probe in PROBES:
            with self.subTest(probe=probe):
                self.check_log([diagnostic(probe)], 0)

    def test_rejects_script_assertion_ending_in_known_probe(self):
        self.check_log([
            "SCRIPT ERROR: Assertion failed: Attempt to get non-existent interface function: classdb_construct_object3."
        ], 1)

    def test_rejects_script_or_user_error_with_exact_probe_suffix(self):
        for prefix in ("SCRIPT ERROR: Assertion failed: ", "USER ERROR: "):
            with self.subTest(prefix=prefix):
                self.check_log([prefix + diagnostic(PROBES[0])], 1)

    def test_rejects_arbitrary_prefix_on_known_diagnostic(self):
        self.check_log(["unrelated failure: " + diagnostic(PROBES[0])], 1)

    def test_rejects_unknown_probe(self):
        self.check_log([diagnostic("unknown_interface")], 1)

    def test_rejects_known_probe_on_47(self):
        self.check_log([diagnostic(PROBES[0])], 1, version="4.7.2")

    def test_rejects_known_probe_without_engine_version(self):
        self.check_log([diagnostic(PROBES[0])], 1, version="unknown")

    def test_version_mention_is_not_an_engine_header(self):
        self.check_log([
            "WARNING: Log refers to Godot Engine v4.6.3, not the running version",
            diagnostic(PROBES[0]),
        ], 1, version="4.7.2")

    def test_rejects_missing_success_marker(self):
        self.check_log([diagnostic(PROBES[0])], 1, marker=False)

    def test_rejects_extension_load_error_even_with_success(self):
        self.check_log(["ERROR: Error loading extension: res://native_video.gdextension"], 1)

    def test_physical_guard_rejects_software_device(self):
        self.check_log(["Vulkan 1.4 - Forward+ - Using Device #0: llvmpipe"], 1, physical=True)

    def test_accepts_clean_physical_renderer(self):
        self.check_log(["Vulkan 1.4 - Forward+ - Using Device #0: AMD Radeon RX Vega"], 0, physical=True)


if __name__ == "__main__":
    unittest.main()
