#!/usr/bin/env python3
"""Print an xcodebuild -destination for an iPhone simulator that exists here.

CI runner images change their simulator line-up with every Xcode bump, so
pinning a model name ("iPhone 17 Pro") breaks on the next image. This picks the
newest iOS runtime with an available iPhone and prints a destination for it.

"Newest" is capped at the selected Xcode's own simulator SDK. An image that
carries several Xcodes — a release and the next betas — can list runtimes the
selected one cannot drive, and xcodebuild rejects such a destination as
ineligible rather than falling back.
"""
import json
import subprocess
import sys


def sdk_version() -> tuple:
    raw = subprocess.run(
        ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return tuple(int(p) for p in raw.split(".") if p.isdigit())


def main() -> int:
    ceiling = sdk_version()
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True, text=True, check=True,
    ).stdout
    devices = json.loads(raw)["devices"]

    best = None
    for runtime, entries in devices.items():
        if "iOS" not in runtime:
            continue
        # "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> (26, 5)
        version = tuple(int(p) for p in runtime.rsplit(".", 1)[-1].split("-")[1:] if p.isdigit())
        if version > ceiling:
            continue
        for device in entries:
            if device.get("isAvailable") and "iPhone" in device["name"]:
                if best is None or version > best[0]:
                    best = (version, device["udid"], device["name"])

    if best is None:
        print(f"no iPhone simulator available at or below iOS {'.'.join(map(str, ceiling))}", file=sys.stderr)
        return 1

    version, udid, name = best
    print(f"selected {name} on iOS {'.'.join(map(str, version))}", file=sys.stderr)
    print(f"platform=iOS Simulator,id={udid}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
