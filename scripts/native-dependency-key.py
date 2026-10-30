#!/usr/bin/env python3
"""Fingerprint only native build inputs, not Luna source/export packaging pins."""
import hashlib
import json
from pathlib import Path
import sys

NATIVE_FILES = (
    "packaging/coreelec-ng/package.mk",
    "packaging/coreelec-ng/build-stage.sh",
    "packaging/coreelec-ng/fix-rtmpdump-source.sh",
    "packaging/coreelec-ng/vfm/build-ffmpeg.sh",
    "packaging/coreelec-ng/vfm/build-module.sh",
    "packaging/coreelec-ng/vfm/driver-package.mk",
    "packaging/coreelec-ng/vfm/ffmpeg-nonblocking.patch",
    "packaging/coreelec-ng/vfm/ffmpeg-package.mk",
    "packaging/coreelec-ng/vfm/prepare-build.sh",
    "kernel/moonlight-vfm/Makefile",
)
SOURCE_KEYS = ("CoreELEC", "linux-amlogic", "media_modules-aml",
               "FFmpeg", "FFmpeg_sha256")


def fingerprint(root):
    root = Path(root)
    paths = [root / name for name in NATIVE_FILES]
    kernel = root / "kernel/moonlight-vfm"
    paths += sorted(kernel.glob("*.c")) + sorted(kernel.glob("*.h"))
    if not all(path.is_file() for path in paths):
        missing = [str(path) for path in paths if not path.is_file()]
        raise ValueError("Missing native dependency sources: " + ", ".join(missing))
    pins = json.loads((root / "packaging/coreelec-ng/vfm/sources.json").read_text())
    selected = {key: pins[key] for key in SOURCE_KEYS}
    digest = hashlib.sha256(b"luna-native-deps-key-v1\0")
    for path in paths:
        digest.update(path.relative_to(root).as_posix().encode() + b"\0")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    digest.update(json.dumps(selected, sort_keys=True,
                             separators=(",", ":")).encode())
    return digest.hexdigest()[:24]


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: native-dependency-key.py MOONLIGHT_ROOT")
    print(fingerprint(sys.argv[1]))
