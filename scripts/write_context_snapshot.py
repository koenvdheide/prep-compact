#!/usr/bin/env python3
"""
prep-compact v2.2.0 status-line companion. See README.md for setup and
PRIVACY.md for what's persisted. Fails silent on every error path —
status-line stderr spams the user's UI.

Token-source waterfall (first that yields an int wins):
  1. sum of current_usage.{input,cache_creation_input,cache_read_input}_tokens
     (output_tokens is per-turn output, not context size — excluded)
  2. round(used_percentage / 100 * context_window_size)
  3. neither available OR transcript cannot be stat'd → delete stale snapshot,
     print placeholder, exit without writing
"""
import sys
import os
import json
import hashlib
import re
import tempfile


def to_native_path(path):
    """Best-effort Git Bash -> Windows native conversion for os.stat calls.
    No-op on non-Windows. On Windows: /X/rest -> X:\\rest (drive letter form);
    /tmp/rest -> %TEMP%\\rest (Git Bash /tmp is alias for TEMP). Other forms
    returned as-is; the caller treats stat failure as a cache miss."""
    if sys.platform != "win32" or not path:
        return path
    if len(path) >= 2 and path[1] == ":":
        return path
    m = re.match(r"^/([a-zA-Z])(/.*)?$", path)
    if m:
        drive = m.group(1).upper()
        rest = (m.group(2) or "").replace("/", "\\")
        return f"{drive}:{rest}"
    if path == "/tmp" or path.startswith("/tmp/"):
        temp = os.environ.get("TEMP") or os.environ.get("TMP")
        if temp:
            rest = path[5:] if path.startswith("/tmp/") else ""
            return os.path.join(temp, rest.replace("/", os.sep))
    return path


def safe_sid(raw):
    """Sanitize session_id for use as a filename. Mirror of the hook's logic."""
    if not raw:
        return ""
    if re.fullmatch(r"[A-Za-z0-9_-]{1,64}", raw):
        return raw
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def compute_tokens(context_window):
    """Run the token-source waterfall. Returns int or None."""
    if not isinstance(context_window, dict):
        return None

    cu = context_window.get("current_usage")
    if isinstance(cu, dict):
        it = cu.get("input_tokens")
        if isinstance(it, int):
            cc = cu.get("cache_creation_input_tokens") or 0
            cr = cu.get("cache_read_input_tokens") or 0
            if isinstance(cc, int) and isinstance(cr, int):
                return it + cc + cr

    pct = context_window.get("used_percentage")
    size = context_window.get("context_window_size")
    if isinstance(pct, (int, float)) and isinstance(size, int) and size > 0:
        return round(pct / 100.0 * size)

    return None


def atomic_write_json(path, obj):
    # Unique temp name so two concurrent renders for the same session
    # (possible despite Claude Code's 300ms debounce) cannot stomp each
    # other's in-flight temp file.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".snap-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def delete_if_exists(path):
    try:
        os.remove(path)
    except OSError:
        pass


def main():
    raw = sys.stdin.read()
    payload = json.loads(raw) if raw else None
    if not isinstance(payload, dict):
        return

    sid_safe = safe_sid(payload.get("session_id") or "")
    if not sid_safe:
        return

    snap_dir = os.path.join(os.path.expanduser("~"), ".claude", "cache", "prep-compact-snapshots")
    os.makedirs(snap_dir, exist_ok=True)
    snap_path = os.path.join(snap_dir, sid_safe + ".json")

    transcript_path = to_native_path(payload.get("transcript_path") or "")
    tokens = compute_tokens(payload.get("context_window"))

    if tokens is None or not transcript_path:
        delete_if_exists(snap_path)
        print("ctx —", end="")
        return

    try:
        st = os.stat(transcript_path)
    except OSError:
        delete_if_exists(snap_path)
        print("ctx —", end="")
        return

    atomic_write_json(snap_path, {
        "current_context_tokens": int(tokens),
        "transcript_mtime_ns": int(st.st_mtime_ns),
        "transcript_size": int(st.st_size),
    })

    cw = payload.get("context_window") if isinstance(payload.get("context_window"), dict) else {}
    size_field = cw.get("context_window_size")
    if isinstance(size_field, int) and size_field > 0:
        def fmt(n):
            if n >= 1_000_000:
                return f"{n / 1_000_000:.1f}M"
            if n >= 1_000:
                return f"{n // 1_000}k"
            return str(n)
        print(f"ctx {fmt(tokens)}/{fmt(size_field)}", end="")
    else:
        print(f"ctx {tokens}", end="")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
