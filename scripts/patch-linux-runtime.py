#!/usr/bin/env python3
"""Linux-only patches applied to the extracted Grok Bot asar.

Upstream ships a Windows/macOS Electron app. On Linux the unmodified payload
boots a white window and never paints the shell:

- utilityProcess MessagePorts for the coordinator close unless the parent
  starts the main-data port before the handoff.
- Hardware acceleration is gated to darwin, so Chromium falls back to
  --use-gl=disabled and never composites the renderer.
- BrowserWindow is frameless (Windows custom titlebar path).
- The first-run gate's countAgents() hangs while EnsureSandBox is down;
  gate-unanswerable then *stays* on phase "checking", and Zns renders
  null forever. Do not put a defaultTimeoutMs on the Connect transport:
  that aborts watchSandBoxMigration and recover/reset fail mid-flight.

Strings are from the minified 0.27.x bundle. If a substitution misses,
upstream minified names moved — update the patterns, don't skip silently
for the load-bearing patches. 0.23.x is rejected by the box API
(SAND_CLIENT_UPDATE_REQUIRED).
"""
from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Callable
from pathlib import Path


class Patch:
    def __init__(
        self,
        name: str,
        relative: str,
        old: str | re.Pattern[str],
        new: str | Callable[[re.Match[str]], str],
        *,
        required: bool,
        glob: bool = False,
        applied_marker: str | None = None,
    ) -> None:
        self.name = name
        self.relative = relative
        self.old = old
        self.new = new
        self.required = required
        self.glob = glob
        self.applied_marker = applied_marker

    def already_applied(self, text: str) -> bool:
        if self.applied_marker:
            return self.applied_marker in text
        if isinstance(self.new, str) and self.new and self.new in text:
            if isinstance(self.old, re.Pattern):
                return self.old.search(text) is None
            return self.old not in text
        return False

    def substitute(self, text: str) -> str | None:
        if self.already_applied(text):
            return text
        if isinstance(self.old, re.Pattern):
            matches = list(self.old.finditer(text))
            if len(matches) != 1:
                return None
            return self.old.sub(self.new, text, count=1)
        if text.count(self.old) != 1:
            return None
        return text.replace(self.old, self.new, 1)


PATCHES = [
    Patch(
        name="coordinator-main-data-port-start",
        relative="dist/electron-main/main.cjs",
        old=(
            "t.port2.start(),e.postMessage({bootstrap:{processConfig:n.processConfig}},"
            "[t.port1,i.port1,a.port1])"
        ),
        new=(
            "t.port2.start(),a.port2.start(),e.postMessage({bootstrap:{processConfig:n.processConfig}},"
            "[t.port1,i.port1,a.port1])"
        ),
        required=True,
    ),
    Patch(
        name="hardware-acceleration-linux",
        relative="dist/electron-main/main.cjs",
        old='function yhn(n){return n.storedPreference??n.platform==="darwin"}',
        new='function yhn(n){return n.storedPreference??(n.platform==="darwin"||n.platform==="linux")}',
        required=False,
    ),
    Patch(
        name="linux-window-frame",
        relative="dist/electron-main/main.cjs",
        old=':{frame:!1,titleBarStyle:"default"}',
        new=':{frame:!0,titleBarStyle:"default"}',
        required=False,
    ),
    Patch(
        name="first-run-gate-fail-open",
        relative="dist/renderer/assets/index-*.js",
        old='case"gate-unanswerable":return t;case"signed-out":return cE(t,{forced:!1,signedIn:!1,owedShell:null})',
        new=(
            'case"gate-unanswerable":return e.sessionFact===!0?'
            '{kind:"shell",runId:t.runId,resolveSeq:t.resolveSeq,provisional:!0}:t;'
            'case"signed-out":return cE(t,{forced:!1,signedIn:!1,owedShell:null})'
        ),
        required=True,
        glob=True,
        applied_marker='case"gate-unanswerable":return e.sessionFact===!0',
    ),
    Patch(
        name="checking-splash",
        relative="dist/renderer/assets/index-*.js",
        old='if(n==="checking")return null;',
        new='if(n==="checking")return m.jsx(l3,{});',
        required=False,
        glob=True,
    ),
    # Connect-ES node HTTP/1.1 client: flushHeaders() runs before the
    # 'socket'/'response' listeners. On Electron 42 Linux a keep-alive socket
    # is often assigned synchronously, so the body is never written and
    # EnsureSandBox hangs after auth. Attach listeners first; write the body
    # after on('response').
    Patch(
        name="connect-http1-listeners-before-flush",
        relative="dist/electron-main/main.cjs",
        old=(
            'n.catch(u=>a.destroy(hg(u))),a.flushHeaders(),a.on("error",n.reject),'
            'a.on("socket",s(function(l){function c(){l.off("connect",c),i(a)}'
            's(c,"onSocketConnect"),l.readyState==="open"?i(a):l.on("connect",c)},'
            '"onRequestSocket"))'
        ),
        new=(
            'n.catch(u=>a.destroy(hg(u))),a.on("error",n.reject);'
            "function o(l){function c(){l.off(\"connect\",c),i(a)}"
            's(c,"onSocketConnect"),l.readyState==="open"?i(a):l.on("connect",c)}'
            'a.socket?o(a.socket):a.on("socket",s(o,"onRequestSocket")),a.flushHeaders()'
        ),
        required=True,
    ),
    Patch(
        name="connect-http1-response-before-body",
        relative="dist/electron-main/main.cjs",
        old='l=>{zGt(t,l,i),l.on("response",c=>{',
        new='l=>{l.on("response",c=>{',
        required=True,
    ),
    Patch(
        name="connect-http1-write-body-after-response",
        relative="dist/electron-main/main.cjs",
        old='body:_Mn(i,c,m),trailer:m})})})})},"request")}function wMn',
        new='body:_Mn(i,c,m),trailer:m})}),zGt(t,l,i)})})},"request")}function wMn',
        required=True,
    ),
]


def _files_for(root: Path, patch: Patch) -> list[Path]:
    path = root / patch.relative
    if patch.glob:
        return sorted(root.glob(patch.relative))
    return [path] if path.is_file() else []


def apply_patch(root: Path, patch: Patch) -> bool:
    files = _files_for(root, patch)
    applied = 0
    for path in files:
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        updated = patch.substitute(text)
        if updated is None:
            continue
        if updated == text and patch.already_applied(text):
            print(f"  already {patch.name} -> {path.relative_to(root)}", file=sys.stderr)
            applied += 1
            continue
        path.write_text(updated, encoding="utf-8", errors="surrogateescape")
        applied += 1
        print(f"  applied {patch.name} -> {path.relative_to(root)}", file=sys.stderr)
    return applied == 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("asar_root", type=Path, help="extracted app.asar directory")
    args = parser.parse_args()
    root = args.asar_root.resolve()
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 1

    print(f"Patching Linux runtime in {root}", file=sys.stderr)
    missing_required = []
    for patch in PATCHES:
        ok = apply_patch(root, patch)
        if not ok:
            msg = f"  skipped {patch.name} (pattern not unique in {patch.relative})"
            print(msg, file=sys.stderr)
            if patch.required:
                missing_required.append(patch.name)

    if missing_required:
        print(
            "error: required Linux runtime patches did not apply: "
            + ", ".join(missing_required),
            file=sys.stderr,
        )
        print(
            "hint: upstream minified names likely changed; update scripts/patch-linux-runtime.py",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
