#!/usr/bin/env python3
"""Check the assembled addon, using its shipped manifest as the file inventory."""
import configparser
import json
import pathlib
import sys


def check_addon(directory):
    directory = pathlib.Path(directory)
    manifest = configparser.ConfigParser(interpolation=None)
    manifest.optionxform = str
    with (directory / "native_video.gdextension").open() as source:
        manifest.read_file(source)
    libraries = {key: json.loads(value) for key, value in manifest["libraries"].items()}
    for key, filename in libraries.items():
        if not isinstance(filename, str) or pathlib.Path(filename).name != filename:
            raise ValueError(f"{key}: expected an addon-local library filename, got {filename!r}")
        library = directory / filename
        if not library.is_file() or library.stat().st_size == 0:
            raise ValueError(f"{key}: missing or empty packaged library: {library}")
    # These are the two actual feature combinations exercised by Linux CI.
    linux_keys = {key for key in libraries if key.startswith("linux.")}
    expected_keys = {f"linux.{mode}.x86_64" for mode in ("debug", "release")}
    if linux_keys != expected_keys:
        raise ValueError(f"unexpected Linux feature keys: {sorted(linux_keys)}")
    if len({libraries[key] for key in expected_keys}) != 2:
        raise ValueError("Linux debug and release must select distinct packaged libraries")


if __name__ == "__main__":
    try:
        check_addon(sys.argv[1])
    except (OSError, ValueError, KeyError, configparser.Error) as error:
        sys.exit(f"Packaged addon validation failed: {error}")
    print("Packaged addon manifest and libraries: PASS")
