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
  gate-unanswerable then *stays* on phase "checking", and the root renderer
  returns null forever. Do not put a defaultTimeoutMs on the Connect transport:
  that aborts watchSandBoxMigration and recover/reset fail mid-flight.

Strings are from the minified 0.30.0 bundle (identifiers moved from the 0.27.x
patterns in laptopcomputer-user/grokbot-linux-port#5). If a substitution
misses, upstream minified names moved — update the patterns, don't skip
silently for the load-bearing patches. 0.23.x is rejected by the box API
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
        # Never infer "applied" from a short `new` substring. required=True
        # patches must carry an applied_marker (validated at module load).
        if self.applied_marker:
            return self.applied_marker in text
        return False

    def _match_count(self, text: str) -> int:
        if isinstance(self.old, re.Pattern):
            return len(list(self.old.finditer(text)))
        return text.count(self.old)

    def substitute(self, text: str) -> str | None:
        if self.already_applied(text):
            return text
        count = self._match_count(text)
        if count == 0:
            return text  # not this file; caller treats unchanged+not-applied as skip
        if count != 1:
            return None  # not unique — unsafe
        if isinstance(self.old, re.Pattern):
            return self.old.sub(self.new, text, count=1)
        return text.replace(self.old, self.new, 1)


PATCHES = [
    Patch(
        name="coordinator-main-data-port-start",
        relative="dist/electron-main/main.cjs",
        # 0.27.x used [t.port1,i.port1,a.port1]; 0.30.0 renamed i→s.
        # a is still mainDataPort (return{rendererDataPort:s.port2,mainDataPort:a.port2}).
        old=(
            "t.port2.start(),e.postMessage({bootstrap:{processConfig:n.processConfig}},"
            "[t.port1,s.port1,a.port1])"
        ),
        new=(
            "t.port2.start(),a.port2.start(),e.postMessage({bootstrap:{processConfig:n.processConfig}},"
            "[t.port1,s.port1,a.port1])"
        ),
        required=True,
        applied_marker="a.port2.start(),e.postMessage({bootstrap:{processConfig:n.processConfig}}",
    ),
    Patch(
        name="hardware-acceleration-linux",
        relative="dist/electron-main/main.cjs",
        # 0.27.x: function yhn. 0.30.0: function BPn (i(BPn,"resolveHardwareAccelerationEnabled")).
        old='function BPn(n){return n.storedPreference??n.platform==="darwin"}',
        new='function BPn(n){return n.storedPreference??(n.platform==="darwin"||n.platform==="linux")}',
        required=True,
        applied_marker='n.platform==="darwin"||n.platform==="linux"',
    ),
    Patch(
        name="linux-window-frame",
        relative="dist/electron-main/main.cjs",
        old=':{frame:!1,titleBarStyle:"default"}',
        new=':{frame:!0,titleBarStyle:"default"}',
        required=False,
        applied_marker=':{frame:!0,titleBarStyle:"default"}',
    ),
    Patch(
        name="first-run-gate-fail-open",
        relative="dist/renderer/assets/index-*.js",
        # 0.27.x used reducer helper cE; 0.30.0 renamed it RC. Fail-open when
        # EnsureSandBox is down so the shell paints instead of staying on
        # phase "checking".
        old='case"gate-unanswerable":return t;case"signed-out":return RC(t,{forced:!1,signedIn:!1,owedShell:null})',
        new=(
            'case"gate-unanswerable":return e.sessionFact===!0?'
            '{kind:"shell",runId:t.runId,resolveSeq:t.resolveSeq,provisional:!0}:t;'
            'case"signed-out":return RC(t,{forced:!1,signedIn:!1,owedShell:null})'
        ),
        required=True,
        glob=True,
        applied_marker='case"gate-unanswerable":return e.sessionFact===!0',
    ),
    Patch(
        name="checking-splash",
        relative="dist/renderer/assets/index-*.js",
        # 0.27.x: m.jsx(l3,{}). 0.30.0 jsx runtime is p; l3→Ax (first child of
        # the sand_client_pause overlay: p.jsx(Ax,{}),p.jsx(v_e,{})).
        old='if(n==="checking")return null;',
        new='if(n==="checking")return p.jsx(Ax,{});',
        required=False,
        glob=True,
        applied_marker='if(n==="checking")return p.jsx(Ax,{})',
    ),
    # Connect-ES node HTTP/1.1 client: flushHeaders() runs before the
    # 'socket'/'response' listeners. On Electron 42 Linux a keep-alive socket
    # is often assigned synchronously, so the body is never written and
    # EnsureSandBox hangs after auth. Attach listeners first; write the body
    # after on('response').
    Patch(
        name="connect-http1-listeners-before-flush",
        relative="dist/electron-main/main.cjs",
        # 0.27.x: hg/s/l/i  →  0.30.0: sA/i/u/s. Catch param is o; extracted
        # onSocket helper is l (o is taken).
        old=(
            'n.catch(o=>a.destroy(sA(o))),a.flushHeaders(),a.on("error",n.reject),'
            'a.on("socket",i(function(u){function c(){u.off("connect",c),s(a)}'
            'i(c,"onSocketConnect"),u.readyState==="open"?s(a):u.on("connect",c)},'
            '"onRequestSocket"))'
        ),
        new=(
            'n.catch(o=>a.destroy(sA(o))),a.on("error",n.reject);'
            "function l(u){function c(){u.off(\"connect\",c),s(a)}"
            'i(c,"onSocketConnect"),u.readyState==="open"?s(a):u.on("connect",c)}'
            'a.socket?l(a.socket):a.on("socket",i(l,"onRequestSocket")),a.flushHeaders()'
        ),
        required=True,
        applied_marker='a.socket?l(a.socket):a.on("socket"',
    ),
    # Atomic: move zXt (0.27.x: zGt) to after on("response"). Splitting this
    # into two substitutions left a window where the body is never written if
    # only the first applied.
    Patch(
        name="connect-http1-write-body-after-response",
        relative="dist/electron-main/main.cjs",
        # 0.27.x: l=>{zGt(t,l,i),...body:_Mn(i,c,m)...}function wMn
        # 0.30.0: u=>{zXt(t,u,s),...body:por(s,c,m)...}function dor
        old=(
            'u=>{zXt(t,u,s),u.on("response",c=>{var d;c.on("error",s.reject),'
            's.catch(f=>c.destroy(sA(f)));let m=new Headers;a({status:(d=c.statusCode)'
            '!==null&&d!==void 0?d:0,header:vMe(c.headers),body:por(s,c,m),trailer:m})'
            '})})})},"request")}function dor'
        ),
        new=(
            'u=>{u.on("response",c=>{var d;c.on("error",s.reject),'
            's.catch(f=>c.destroy(sA(f)));let m=new Headers;a({status:(d=c.statusCode)'
            '!==null&&d!==void 0?d:0,header:vMe(c.headers),body:por(s,c,m),trailer:m})'
            '}),zXt(t,u,s)})})},"request")}function dor'
        ),
        required=True,
        applied_marker='}),zXt(t,u,s)})})},"request")}function dor',
    ),
]


def _validate_patches() -> None:
    for patch in PATCHES:
        if patch.required and not patch.applied_marker:
            raise SystemExit(
                f"error: required patch {patch.name} must set applied_marker "
                "(do not infer already-applied from a short `new` substring)"
            )
        if (
            patch.applied_marker
            and isinstance(patch.new, str)
            and patch.applied_marker not in patch.new
        ):
            raise SystemExit(
                f"error: applied_marker for {patch.name} is not a substring of `new`"
            )


def _files_for(root: Path, patch: Patch) -> list[Path]:
    path = root / patch.relative
    if patch.glob:
        return sorted(root.glob(patch.relative))
    return [path] if path.is_file() else []


def apply_patch(root: Path, patch: Patch) -> tuple[bool, str]:
    files = _files_for(root, patch)
    if not files:
        return False, f"no files matched {patch.relative}"
    applied = 0
    non_unique = 0
    for path in files:
        text = path.read_text(encoding="utf-8", errors="surrogateescape")
        if patch.already_applied(text):
            print(f"  already {patch.name} -> {path.relative_to(root)}", file=sys.stderr)
            applied += 1
            continue
        updated = patch.substitute(text)
        if updated is None:
            non_unique += 1
            print(
                f"  not unique {patch.name} -> {path.relative_to(root)}",
                file=sys.stderr,
            )
            continue
        if updated == text:
            continue
        path.write_text(updated, encoding="utf-8", errors="surrogateescape")
        applied += 1
        print(f"  applied {patch.name} -> {path.relative_to(root)}", file=sys.stderr)
    if non_unique:
        return False, f"pattern not unique in {non_unique} file(s) matching {patch.relative}"
    if applied >= 1:
        return True, "ok"
    return False, f"pattern not found in {len(files)} file(s) matching {patch.relative}"


def main() -> int:
    _validate_patches()
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
        ok, reason = apply_patch(root, patch)
        if not ok:
            print(f"  skipped {patch.name} ({reason})", file=sys.stderr)
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
