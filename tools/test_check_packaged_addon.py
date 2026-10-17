#!/usr/bin/env python3
"""Package layout regressions, independent of Godot and platform toolchains."""
import configparser
import json
import pathlib
import shutil
import tempfile
import unittest

from check_packaged_addon import check_addon

MANIFEST = pathlib.Path(__file__).resolve().parents[1] / "addon/native_video.gdextension"


class PackagedAddonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gnv-package-test-")
        self.addCleanup(self.temp.cleanup)
        self.addon = pathlib.Path(self.temp.name)
        self.manifest = self.addon / MANIFEST.name
        shutil.copyfile(MANIFEST, self.manifest)
        config = configparser.ConfigParser(interpolation=None)
        config.read(self.manifest)
        self.libraries = {key: json.loads(value) for key, value in config["libraries"].items()}
        for filename in self.libraries.values():
            (self.addon / filename).write_bytes(b"test library")

    def library(self, key):
        return self.addon / self.libraries[key]

    def test_shipped_layout_passes(self):
        check_addon(self.addon)

    def test_missing_library_fails(self):
        self.library("linux.release.x86_64").unlink()
        with self.assertRaisesRegex(ValueError, "missing or empty"):
            check_addon(self.addon)

    def test_renamed_library_fails(self):
        self.library("linux.debug.x86_64").rename(self.addon / "renamed.so")
        with self.assertRaisesRegex(ValueError, "missing or empty"):
            check_addon(self.addon)

    def test_empty_library_fails(self):
        self.library(next(iter(self.libraries))).write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "missing or empty"):
            check_addon(self.addon)

    def test_aliasing_debug_and_release_to_one_library_fails(self):
        self.manifest.write_text(self.manifest.read_text().replace(
            json.dumps(self.libraries["linux.release.x86_64"]),
            json.dumps(self.libraries["linux.debug.x86_64"]),
        ))
        with self.assertRaisesRegex(ValueError, "must select distinct"):
            check_addon(self.addon)

    def test_incorrect_linux_feature_key_fails(self):
        self.manifest.write_text(self.manifest.read_text().replace(
            "linux.release.x86_64 =", "linux.release.arm64 ="
        ))
        with self.assertRaisesRegex(ValueError, "unexpected Linux feature keys"):
            check_addon(self.addon)

    def test_development_manifest_fails(self):
        self.manifest.write_text(self.manifest.read_text().replace(
            json.dumps(self.libraries["linux.debug.x86_64"]), '"lib/libnative_video.so"'
        ))
        with self.assertRaisesRegex(ValueError, "addon-local library filename"):
            check_addon(self.addon)


if __name__ == "__main__":
    unittest.main()
