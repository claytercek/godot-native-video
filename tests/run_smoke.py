#!/usr/bin/env python3
"""Run only the checked-in synthetic Godot smoke, with a deadline and strict logs.

Build the extension first. Display/software-device setup belongs to the caller;
this is a rendered Forward+ test, never a headless or Compatibility fallback.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys

REPO = Path(__file__).resolve().parent.parent


def run_smoke(godot, driver, log, timeout, display_args):
    command = [godot, "--path", str(REPO / "project"),
               "--rendering-method", "forward_plus", "--verbose",
               "--audio-driver", "Dummy", "--max-fps", "60"]
    if driver != "default":
        command.extend(["--rendering-driver", driver])
    command.extend([*display_args, "--", "--smoke"])
    log.parent.mkdir(parents=True, exist_ok=True)
    print("SMOKE_COMMAND", command, flush=True)
    with log.open("w", encoding="utf-8") as output:
        # setup-godot's Windows alias has no .exe suffix. An explicit executable
        # avoids CreateProcess appending one to that valid extensionless binary.
        process = subprocess.Popen(command, executable=godot, stdout=output,
                                   stderr=subprocess.STDOUT, start_new_session=os.name != "nt")
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Reap console-wrapper children too, rather than leaving Godot alive.
            if os.name == "nt":
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(process.pid)], check=False)
            else:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            print(f"SMOKE_TIMEOUT after {timeout}s", file=sys.stderr)
            status = 1
    text = log.read_text(encoding="utf-8", errors="replace")
    print(text, end="", flush=True)
    checked = subprocess.run([
        sys.executable, str(REPO / "tests/check_validation_log.py"),
        str(log), "--marker", "SMOKE: PASS",
    ], check=False).returncode
    # Prove an actual RenderingDevice was selected, not just a successful exit.
    banner = {"vulkan": r"Vulkan", "default": r"(?:Metal|Vulkan)",
              "d3d12": r"(?:D3D12|Direct3D 12)"}[driver]
    rendered = re.search(rf"^{banner} .* - Forward\+ - Using Device.*$", text, re.M)
    if not rendered:
        print(f"SMOKE_FAIL: no {driver} Forward+ device in engine output", file=sys.stderr)
    if "SMOKE: PASS" not in text.splitlines():
        print("SMOKE_FAIL: missing exact SMOKE: PASS line", file=sys.stderr)
        return 1
    return 0 if status == 0 and checked == 0 and rendered else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT_PATH") or os.environ.get("GODOT") or "godot")
    parser.add_argument("--driver", required=True, choices=("vulkan", "default", "d3d12"))
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=75)
    parser.add_argument("display_args", nargs=argparse.REMAINDER,
                        help="renderer/display setup flags after --")
    args = parser.parse_args()
    godot = shutil.which(args.godot, mode=os.F_OK)
    if not godot:
        parser.error(f"Godot executable not found: {args.godot}")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    display_args = args.display_args
    if display_args[:1] == ["--"]:
        display_args = display_args[1:]
    return run_smoke(godot, args.driver, args.log, args.timeout, display_args)


if __name__ == "__main__":
    sys.exit(main())
