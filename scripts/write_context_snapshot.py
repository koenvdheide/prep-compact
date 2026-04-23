#!/usr/bin/env python3
"""
prep-compact v2.2.0 status-line companion.

Reads Claude Code's status-line JSON payload on stdin, computes the current
main-session context-token count from context_window, and writes a per-session
snapshot file that the UserPromptSubmit hook uses as an opportunistic fast
path (freshness-gated against the current transcript's mtime_ns + size).

Configure as a statusLine command in ~/.claude/settings.json. Runs reliably
in terminal Claude Code (CLI TUI); IDE extensions (VSCode, JetBrains) may
not drive statusLine renders at all — in those environments the plugin
silently falls back to the transcript tail-scan (no snapshot written, hook
behavior identical to v2.1.0 when the snapshot dir is empty).

Exits 0 on every error path (status-line stderr spams the user's UI).

Token-source waterfall:
  1. context_window.current_usage.{input,cache_creation_input,cache_read_input}_tokens
     (preferred; output_tokens is deliberately excluded — it's per-turn output,
     not context size).
  2. round(context_window.used_percentage / 100 * context_window.context_window_size)
     (fallback when current_usage is null or malformed).
  3. Neither populated OR transcript cannot be stat'd: delete any stale
     snapshot, print placeholder, exit without writing a new one.

Snapshot schema (3 fields, all integers; filename is <safe_sid>.json where
safe_sid is the hook-side regex/SHA-1 sanitization):
  current_context_tokens  int  (derived per the waterfall above)
  transcript_mtime_ns     int  (os.stat(transcript_path).st_mtime_ns)
  transcript_size         int  (os.stat(transcript_path).st_size)
"""
import sys
import os
import json
import hashlib
import re
import tempfile


def to_native_path(path):
    """Best-effort Git Bash -> Windows native conversion for os.stat calls.
    No-op on non-Windows platforms. On Windows:
      /X/rest    -> X:\\rest         (drive letter form)
      /tmp/rest  -> %TEMP%\\rest     (Git Bash /tmp is alias for TEMP)
    Other forms are returned as-is; the caller treats stat failure as a
    cache miss."""
    if sys.platform != "win32" or not path:
        return path
    if len(path) >= 2 and path[1] == ":":
        return path  # already native
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


def snapshot_dir():
    return os.path.join(os.path.expanduser("~"), ".claude", "cache", "prep-compact-snapshots")


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
    except FileNotFoundError:
        pass
    except OSError:
        pass


def main():
    try:
        raw = sys.stdin.read()
    except Exception:
        return

    try:
        payload = json.loads(raw) if raw else None
    except Exception:
        return
    if not isinstance(payload, dict):
        return

    sid = payload.get("session_id") or ""
    sid_safe = safe_sid(sid)
    if not sid_safe:
        return

    try:
        snap_dir = snapshot_dir()
        os.makedirs(snap_dir, exist_ok=True)
    except Exception:
        return
    snap_path = os.path.join(snap_dir, sid_safe + ".json")

    transcript_path_raw = payload.get("transcript_path") or ""
    transcript_path_native = to_native_path(transcript_path_raw)
    tokens = compute_tokens(payload.get("context_window"))

    if tokens is None or not transcript_path_native:
        delete_if_exists(snap_path)
        print("ctx —", end="")  # em-dash placeholder
        return

    try:
        st = os.stat(transcript_path_native)
    except OSError:
        delete_if_exists(snap_path)
        print("ctx —", end="")
        return

    record = {
        "current_context_tokens": int(tokens),
        "transcript_mtime_ns": int(st.st_mtime_ns),
        "transcript_size": int(st.st_size),
    }

    try:
        atomic_write_json(snap_path, record)
    except Exception:
        return

    size_field = payload.get("context_window", {}).get("context_window_size") if isinstance(payload.get("context_window"), dict) else None
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
