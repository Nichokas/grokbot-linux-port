#!/usr/bin/env python3
"""Extract the Grok Bot app icon from a packed Electron asar archive.

The PNG lives at dist/renderer/assets/app-icon-*.png inside app.asar.
It is not present in app.asar.unpacked, so a filesystem hunt of the staged
tree finds nothing. This helper is used by port.sh (to plant grok-bot.png
in the tarball) and by the AUR/RPM package() steps (so already-published
tarballs still get an icon).

Usage: extract-asar-icon.py <app.asar> <dest.png>
Exit 0 on success, 1 if no matching icon is found.
"""
from __future__ import annotations

import json
import pathlib
import struct
import sys


def walk(node: dict, prefix: str = ""):
    for name, meta in node.get("files", {}).items():
        path = f"{prefix}/{name}" if prefix else name
        if "files" in meta:
            yield from walk(meta, path)
        else:
            yield path, meta


def extract(asar_path: str, dest_path: str) -> None:
    with open(asar_path, "rb") as fh:
        # Chromium pickle: uint32 payload size (always 4), then uint32
        # size of the header pickle, then the header pickle itself.
        pickle_payload_size = struct.unpack("<I", fh.read(4))[0]
        if pickle_payload_size != 4:
            raise SystemExit(
                f"error: unexpected asar pickle size {pickle_payload_size}"
            )
        header_size = struct.unpack("<I", fh.read(4))[0]
        header_pickle = fh.read(header_size)
        # Header pickle: uint32 payload size, uint32 string length, JSON.
        str_len = struct.unpack_from("<I", header_pickle, 4)[0]
        header = json.loads(header_pickle[8 : 8 + str_len])
        data_offset = 8 + header_size
        hits = [
            (path, meta)
            for path, meta in walk(header)
            if path.rsplit("/", 1)[-1].startswith("app-icon")
            and path.endswith(".png")
            and "offset" in meta
        ]
        if not hits:
            raise SystemExit("error: no app-icon*.png inside asar")
        path, meta = max(hits, key=lambda item: int(item[1]["size"]))
        fh.seek(data_offset + int(meta["offset"]))
        blob = fh.read(int(meta["size"]))
        if len(blob) != int(meta["size"]):
            raise SystemExit(f"error: {path} is truncated")
        if blob[:8] != b"\x89PNG\r\n\x1a\n":
            raise SystemExit(f"error: {path} is not a PNG")
        dest = pathlib.Path(dest_path)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(blob)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: extract-asar-icon.py <app.asar> <dest.png>")
    # Best-effort helper: callers print their own warn and carry on, so any
    # malformed-asar / IO failure must stay a one-line error, not a traceback.
    try:
        extract(sys.argv[1], sys.argv[2])
    except Exception as exc:
        raise SystemExit(f"error: {exc}")


if __name__ == "__main__":
    main()
