#!/usr/bin/env python3
"""snareSAR GNSS Base Station — Health HTTP endpoint (continuous-capture).

Binds to the Tailscale IP only (100.64.0.0/10) on TCP/8080 and returns
JSON describing capture health, upload-worker freshness, disk free,
uptime, and upload log state.

Protect with Tailscale ACLs — binding to a CGNAT address prevents
accidental exposure over the WAN even if the host is dual-homed.

Architecture model (post-2026-04-21):
  Capture is continuous. gnss-capture.service runs str2str as a
  resident process, writing UBX into /home/xeroth/base_station/logs/raw/
  %Y%m%d%h%M.ubx with a 10-minute rotation aligned to UTC :00/:10/:20/
  :30/:40/:50 boundaries. str2str's -f 30 swap margin pre-opens the
  next file 30 s before the rotation instant so the boundary crossing
  is atomic — no bytes are lost at the seam.

  gnss_upload_worker.sh runs every minute from cron and processes
  any closed rotation files (anything that is NOT the currently-writing
  slot). It runs convbin -> injects PPP -> uploads to GCS -> verifies
  -> deletes local copy. It writes upload.heartbeat on every invocation.

Freshness signals (authoritative):
  - gnss-capture.service  : systemctl is-active ; must be 'active'
  - current slot file     : raw/${CURRENT_SLOT}.ubx must exist and have
                            grown within the last ~15 s (F9P at 1 Hz
                            produces continuous UBX)
  - upload heartbeat      : state/upload.heartbeat must be < 300 s old
  - upload log            : last 'Uploaded ...' in automation.log
  - rinex backlog         : leftover .obs/.nav in LOG_DIR = upload failing
  - raw backlog           : leftover closed raw/*.ubx older than one
                            rotation period = worker falling behind

Status is 'degraded' (HTTP 503) if any of:
  - gnss-capture.service is not active
  - current slot raw file missing or mtime > CAPTURE_STALL_S old
  - upload heartbeat missing or > STALE_UPLOAD_HB_S old
  - rinex backlog > MAX_RINEX_BACKLOG
  - raw backlog > MAX_RAW_BACKLOG
  - gcs auth inactive
  - disk free < MIN_FREE_MB
HTTP 200 when status == 'ok'.

Systemd unit: gnss-health.service
"""
from __future__ import annotations

import calendar
import ipaddress
import json
import os
import re
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG_DIR = "/home/xeroth/base_station/logs"
RAW_DIR = "/home/xeroth/base_station/logs/raw"
STATE_DIR = "/home/xeroth/base_station/state"
UPLOAD_HEARTBEAT_FILE = os.path.join(STATE_DIR, "upload.heartbeat")
AUTOMATION_LOG = os.path.join(LOG_DIR, "automation.log")
BAUD_FILE = "/home/xeroth/base_station/scripts/baud.conf"
STATION_CONF = "/home/xeroth/base_station/scripts/station.conf"
CAPTURE_UNIT = "gnss-capture.service"
PORT = 8080

# --- OTA / release state files (written by gnss_update_agent.sh and install.sh) ---
VERSION_FILE = os.path.join(STATE_DIR, "version")
CHANNEL_FILE = os.path.join(STATE_DIR, "channel")
TARGET_VERSION_FILE = os.path.join(STATE_DIR, "target_version")
UPDATE_ATTEMPT_FILE = os.path.join(STATE_DIR, "last_update_attempt")
UPDATE_RESULT_FILE = os.path.join(STATE_DIR, "last_update_result")

# --- Thresholds (seconds / counts / megabytes) ---
CAPTURE_STALL_S = 30              # current raw file mtime older than this = stalled
STALE_UPLOAD_HB_S = 300           # upload worker runs every minute
MIN_FREE_MB = 2048                # matches gnss-disk-guard.sh threshold
MAX_RINEX_BACKLOG = 3             # .obs/.nav awaiting retry
MAX_RAW_BACKLOG = 3               # closed raw UBX not yet processed
LOG_TAIL_BYTES = 65536            # size of automation.log to scan
# Update agent runs every 10 min from cron. If last_update_attempt is
# older than this, the agent has been failing to execute — report it.
STALE_UPDATE_ATTEMPT_S = 1800

# --- Rotation period (must match gnss-capture.service's S=0.16667 h = 600 s) ---
ROTATION_PERIOD_S = 600

# --- Log line pattern: "2026-04-20 09:18:16 UTC [MY_STATION] message" ---
LOG_LINE_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) UTC \[[A-Z0-9_]+\] (.*)$"
)


def tailscale_ipv4() -> str | None:
    """Return the 100.64.0.0/10 address bound on this host, if any."""
    cgnat = ipaddress.ip_network("100.64.0.0/10")
    try:
        out = subprocess.check_output(
            ["ip", "-4", "-o", "addr"], text=True, timeout=5
        )
    except Exception:
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            addr = ipaddress.ip_interface(parts[3]).ip
        except ValueError:
            continue
        if addr in cgnat:
            return str(addr)
    return None


def station_id() -> str:
    try:
        with open(STATION_CONF) as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("STATION_ID"):
                    _, _, v = line.partition("=")
                    return v.strip().strip('"')
    except FileNotFoundError:
        pass
    return socket.gethostname().upper()


def read_upload_heartbeat() -> dict:
    try:
        with open(UPLOAD_HEARTBEAT_FILE) as fh:
            raw = fh.read().strip()
    except FileNotFoundError:
        return {"present": False}
    parts = raw.split(None, 1)
    if not parts:
        return {"present": False}
    try:
        ts = int(parts[0])
    except ValueError:
        return {"present": True, "raw": raw}
    state = parts[1] if len(parts) > 1 else ""
    return {
        "present": True,
        "epoch": ts,
        "iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts)),
        "age_seconds": int(time.time()) - ts,
        "state": state,
    }


def disk_free() -> dict:
    try:
        st = os.statvfs(LOG_DIR)
    except Exception as e:
        return {"error": str(e)}
    free_bytes = st.f_bavail * st.f_frsize
    total_bytes = st.f_blocks * st.f_frsize
    return {
        "free_bytes": free_bytes,
        "total_bytes": total_bytes,
        "free_mb": free_bytes // (1024 * 1024),
        "total_mb": total_bytes // (1024 * 1024),
        "percent_used": round((1 - free_bytes / total_bytes) * 100, 1)
        if total_bytes
        else None,
    }


def uptime() -> dict:
    try:
        with open("/proc/uptime") as fh:
            up = float(fh.read().split()[0])
    except Exception:
        return {}
    return {"seconds": int(up)}


def load_avg() -> dict:
    try:
        one, five, fifteen = os.getloadavg()
    except Exception:
        return {}
    return {"1m": one, "5m": five, "15m": fifteen}


def baud() -> int | None:
    try:
        with open(BAUD_FILE) as fh:
            return int(fh.read().strip())
    except Exception:
        return None


def systemd_is_active(unit: str) -> bool | None:
    """True if unit is 'active', False if 'inactive'/'failed', None if
    systemctl is unreachable."""
    try:
        out = subprocess.run(
            ["/usr/bin/systemctl", "is-active", unit],
            capture_output=True, text=True, timeout=5,
        )
    except FileNotFoundError:
        return None
    except Exception:
        return None
    return out.stdout.strip() == "active"


def gcs_auth_active() -> bool | None:
    """True if any ACTIVE gcloud account is present. Returns None if gcloud
    is not available, which should not happen on a provisioned station."""
    try:
        out = subprocess.check_output(
            [
                "/usr/bin/gcloud", "auth", "list",
                "--filter=status:ACTIVE",
                "--format=value(account)",
            ],
            text=True, timeout=5,
        )
    except FileNotFoundError:
        return None
    except Exception:
        return False
    return bool(out.strip())


def current_slot_id(now_epoch: int) -> str:
    """YYYYMMDDHHMM identifier of the current canonical 10-min UTC rotation
    slot. Note: str2str names its first-after-start file by the current
    minute at file-open time, not by the 10-min boundary, so the filename
    stem may not equal this canonical id until the next rotation. Use
    newest_ubx_stem() for the actual current-writing filename."""
    slot_epoch = now_epoch - (now_epoch % ROTATION_PERIOD_S)
    return time.strftime("%Y%m%d%H%M", time.gmtime(slot_epoch))


def newest_ubx() -> tuple[str, os.stat_result] | None:
    """Return (path, stat) of the most-recently-modified .ubx file in
    RAW_DIR, or None if the directory is empty/missing. This is the file
    str2str is currently appending to, regardless of its filename."""
    try:
        names = os.listdir(RAW_DIR)
    except FileNotFoundError:
        return None
    best = None
    for name in names:
        if not name.endswith(".ubx"):
            continue
        path = os.path.join(RAW_DIR, name)
        try:
            st = os.stat(path)
        except FileNotFoundError:
            continue
        if best is None or st.st_mtime > best[1].st_mtime:
            best = (path, st)
    return best


def newest_ubx_stem() -> str | None:
    """Filename stem (YYYYMMDDHHMM) of the current-writing .ubx, or None."""
    nu = newest_ubx()
    if nu is None:
        return None
    return os.path.basename(nu[0])[:-4]


def current_slot_file_status(now_epoch: int) -> dict:
    """Status of the .ubx file str2str is currently writing to. Reports
    the newest .ubx in RAW_DIR regardless of whether its filename matches
    the canonical 10-min-boundary slot — str2str names files by
    file-open-minute, not by rotation-boundary-minute, so the two only
    coincide at rotation boundaries. The `slot` field reflects the
    actual filename stem; the `canonical_slot` field reflects the
    10-min-boundary id for the current time."""
    canonical = current_slot_id(now_epoch)
    nu = newest_ubx()
    if nu is None:
        return {
            "present": False,
            "slot": canonical,
            "canonical_slot": canonical,
            "path": os.path.join(RAW_DIR, canonical + ".ubx"),
        }
    path, st = nu
    stem = os.path.basename(path)[:-4]
    age = now_epoch - int(st.st_mtime)
    return {
        "present": True,
        "slot": stem,
        "canonical_slot": canonical,
        "path": path,
        "size": st.st_size,
        "mtime_epoch": int(st.st_mtime),
        "mtime_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime)),
        "age_seconds": age,
    }


def raw_backlog() -> dict:
    """Count closed rotation files still in raw/ (excluding the
    current-writing file). The current-writing file is identified by
    newest-mtime, not by canonical slot name, because str2str may be
    writing to a filename that doesn't match the canonical 10-min
    boundary id."""
    now = int(time.time())
    current_stem = newest_ubx_stem()
    try:
        names = os.listdir(RAW_DIR)
    except FileNotFoundError:
        return {"count": 0, "oldest": None}
    closed = []
    for name in names:
        if not name.endswith(".ubx"):
            continue
        stem = name[:-4]
        if current_stem is not None and stem == current_stem:
            continue
        try:
            st = os.stat(os.path.join(RAW_DIR, name))
        except FileNotFoundError:
            continue
        closed.append((name, int(st.st_mtime), st.st_size))
    closed.sort(key=lambda x: x[1])
    if not closed:
        return {"count": 0, "oldest": None}
    oldest = closed[0]
    return {
        "count": len(closed),
        "oldest": {
            "name": oldest[0],
            "mtime_epoch": oldest[1],
            "mtime_iso": time.strftime(
                "%Y-%m-%dT%H:%M:%SZ", time.gmtime(oldest[1])
            ),
            "age_seconds": now - oldest[1],
            "size": oldest[2],
        },
    }


def rinex_backlog_count() -> int:
    """Count .obs/.rnx/.nav files in LOG_DIR awaiting upload retry. In a
    healthy station this is 0; it rises when uploads fail."""
    try:
        names = os.listdir(LOG_DIR)
    except FileNotFoundError:
        return 0
    n = 0
    for name in names:
        if name.endswith(".obs") or name.endswith(".rnx") or name.endswith(".nav"):
            n += 1
    return n


def _parse_log_timestamp(s: str) -> int | None:
    """'2026-04-20 09:18:16' -> UTC epoch."""
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%d %H:%M:%S"))
    except ValueError:
        return None


def upload_log_signals() -> dict:
    """Derive last_upload, last_slot_complete, last_error from the tail of
    automation.log written by gnss_upload_worker.sh."""
    result = {
        "last_upload": None,
        "last_slot_complete": None,
        "last_error": None,
    }
    try:
        st = os.stat(AUTOMATION_LOG)
        with open(AUTOMATION_LOG, "rb") as f:
            if st.st_size > LOG_TAIL_BYTES:
                f.seek(-LOG_TAIL_BYTES, os.SEEK_END)
                f.readline()
            data = f.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return result
    except Exception:
        return result

    now = int(time.time())
    last_upload_epoch = None
    last_upload_file = None
    last_slot_epoch = None
    last_slot_id = None
    last_err_epoch = None
    last_err_msg = None
    for raw_line in data.splitlines():
        m = LOG_LINE_RE.match(raw_line)
        if not m:
            continue
        ts = _parse_log_timestamp(m.group(1))
        if ts is None:
            continue
        msg = m.group(2)
        if msg.startswith("Uploaded ") or msg.startswith("Retry-uploaded "):
            # "Uploaded 202604211210.obs to gs://..."
            if msg.startswith("Retry-uploaded "):
                head = "Retry-uploaded "
            else:
                head = "Uploaded "
            fname = msg[len(head):].split(" to ", 1)[0]
            last_upload_epoch = ts
            last_upload_file = fname
        elif msg.startswith("Slot ") and msg.endswith(" complete"):
            # "Slot 202604211210 complete"
            sid = msg[len("Slot "):-len(" complete")]
            last_slot_epoch = ts
            last_slot_id = sid
        elif msg.startswith("ERROR:"):
            last_err_epoch = ts
            last_err_msg = msg

    def _full(epoch):
        if epoch is None:
            return None
        return {
            "epoch": epoch,
            "iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch)),
            "age_seconds": now - epoch,
        }

    if last_upload_epoch is not None:
        result["last_upload"] = {**_full(last_upload_epoch), "file": last_upload_file}
    if last_slot_epoch is not None:
        result["last_slot_complete"] = {
            **_full(last_slot_epoch), "slot": last_slot_id
        }
    if last_err_epoch is not None:
        result["last_error"] = {**_full(last_err_epoch), "message": last_err_msg}
    return result


def _read_text_strip(path: str) -> str | None:
    try:
        with open(path) as fh:
            return fh.read().strip()
    except FileNotFoundError:
        return None
    except Exception:
        return None


def release_state() -> dict:
    """Return version/channel/OTA state for the fleet control plane."""
    now = int(time.time())
    version = _read_text_strip(VERSION_FILE)
    channel = _read_text_strip(CHANNEL_FILE) or "stable"
    target = _read_text_strip(TARGET_VERSION_FILE)
    last_attempt_iso = _read_text_strip(UPDATE_ATTEMPT_FILE)
    last_result = _read_text_strip(UPDATE_RESULT_FILE)

    last_attempt_age = None
    last_attempt_epoch = None
    if last_attempt_iso:
        try:
            last_attempt_epoch = calendar.timegm(
                time.strptime(last_attempt_iso, "%Y-%m-%dT%H:%M:%SZ")
            )
            last_attempt_age = now - last_attempt_epoch
        except ValueError:
            pass

    update_pending = bool(target) and bool(version) and target != version

    return {
        "version": version,
        "channel": channel,
        "target_version": target,
        "update_pending": update_pending,
        "last_update_attempt_iso": last_attempt_iso,
        "last_update_attempt_age_seconds": last_attempt_age,
        "last_update_result": last_result,
    }


def snapshot() -> dict:
    now = int(time.time())
    capture_active = systemd_is_active(CAPTURE_UNIT)
    upload_hb = read_upload_heartbeat()
    current_slot = current_slot_file_status(now)
    raw_bk = raw_backlog()
    rinex_bk = rinex_backlog_count()
    auth_active = gcs_auth_active()
    free = disk_free()
    log_sig = upload_log_signals()
    release = release_state()

    status = "ok"
    reasons: list[str] = []

    # --- Capture service must be active ---
    if capture_active is False:
        status = "degraded"
        reasons.append(f"{CAPTURE_UNIT} is not active")
    elif capture_active is None:
        status = "degraded"
        reasons.append("unable to query systemctl for capture service state")

    # --- Current slot file must exist and be fresh (str2str is writing) ---
    if not current_slot.get("present"):
        status = "degraded"
        reasons.append(
            f"current slot file missing: {current_slot.get('path')}"
        )
    else:
        age = current_slot.get("age_seconds", 0)
        if age > CAPTURE_STALL_S:
            status = "degraded"
            reasons.append(
                f"current slot file stale "
                f"(mtime {age}s old, > {CAPTURE_STALL_S}s)"
            )

    # --- Upload worker heartbeat must be fresh ---
    if not upload_hb.get("present"):
        status = "degraded"
        reasons.append("no upload heartbeat file (worker never ran)")
    else:
        age = upload_hb.get("age_seconds")
        if age is not None and age > STALE_UPLOAD_HB_S:
            status = "degraded"
            reasons.append(
                f"stale upload heartbeat ({age}s > {STALE_UPLOAD_HB_S}s)"
            )

    # --- Raw backlog (closed UBX not yet processed) ---
    if raw_bk["count"] > MAX_RAW_BACKLOG:
        status = "degraded"
        reasons.append(
            f"{raw_bk['count']} closed raw UBX files awaiting processing "
            f"(> {MAX_RAW_BACKLOG})"
        )

    # --- RINEX backlog (failed uploads) ---
    if rinex_bk > MAX_RINEX_BACKLOG:
        status = "degraded"
        reasons.append(
            f"{rinex_bk} RINEX files awaiting upload retry in LOG_DIR "
            f"(> {MAX_RINEX_BACKLOG})"
        )

    # --- GCS auth ---
    if auth_active is False:
        status = "degraded"
        reasons.append("no ACTIVE gcloud service account (uploads will fail)")
    elif auth_active is None:
        status = "degraded"
        reasons.append("gcloud CLI not found at /usr/bin/gcloud")

    # --- Disk free ---
    if isinstance(free, dict) and "free_mb" in free and free["free_mb"] < MIN_FREE_MB:
        status = "degraded"
        reasons.append(
            f"low disk ({free['free_mb']} MB free, min {MIN_FREE_MB})"
        )

    # --- Update agent liveness (does NOT gate status=ok; informational only
    # because a station with no network will naturally skip attempts and we
    # don't want offline stations to flap to degraded purely for that). But
    # we DO surface an extended signal so the fleet console can highlight
    # stations whose update agent hasn't run.
    update_agent_stale = False
    if release.get("last_update_attempt_iso") is None:
        update_agent_stale = True
    else:
        age = release.get("last_update_attempt_age_seconds")
        if age is not None and age > STALE_UPDATE_ATTEMPT_S:
            update_agent_stale = True

    return {
        "station_id": station_id(),
        "status": status,
        "reasons": reasons,
        "server_time_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "uptime": uptime(),
        "load_avg": load_avg(),
        "disk": free,
        "baud_conf": baud(),
        "capture_service_active": capture_active,
        "current_slot": current_slot,
        "raw_backlog": raw_bk,
        "rinex_backlog_count": rinex_bk,
        "gcs_auth_active": auth_active,
        "upload_heartbeat": upload_hb,
        "last_upload": log_sig.get("last_upload"),
        "last_slot_complete": log_sig.get("last_slot_complete"),
        "last_error": log_sig.get("last_error"),
        "release": release,
        "update_agent_stale": update_agent_stale,
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        if getattr(self, "path", "") not in ("/health", "/", "/healthz"):
            super().log_message(fmt, *args)

    def do_GET(self):
        if self.path in ("/", "/health", "/healthz"):
            snap = snapshot()
            body = json.dumps(snap, indent=2, sort_keys=True).encode()
            http_status = 200 if snap.get("status") == "ok" else 503
            self.send_response(http_status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()


def main() -> int:
    bind_ip = tailscale_ipv4()
    if bind_ip is None:
        print("ERROR: no Tailscale IPv4 address found (100.64.0.0/10)", file=sys.stderr)
        return 2
    server = HTTPServer((bind_ip, PORT), Handler)
    print(f"gnss-health listening on {bind_ip}:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
