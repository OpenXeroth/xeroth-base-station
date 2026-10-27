#!/usr/bin/env bats
# =============================================================================
# gnss_upload_worker.sh uploading with a network key (UPLOAD_KEY=), run for
# real against a local HTTP server that behaves like base.xeroth.ai/v1:
# 201 for the right key, 401 otherwise.
# =============================================================================

setup() {
    WORKER="${BATS_TEST_DIRNAME}/../../payload/scripts/gnss_upload_worker.sh"
    TMP="$(mktemp -d)"
    export GNSS_BASE_DIR="${TMP}/base"
    export GNSS_LOCK_FILE="${TMP}/lock"
    mkdir -p "${GNSS_BASE_DIR}/scripts" "${GNSS_BASE_DIR}/logs/raw" "${TMP}/received"
    PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
    python3 - "${PORT}" "${TMP}/received" <<'PY' &
import http.server, sys, pathlib
port, out = int(sys.argv[1]), pathlib.Path(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.headers.get("Authorization") != "Bearer xrx_goodid_goodsecret":
            self.send_response(401); self.end_headers(); self.wfile.write(b'{"detail":"no"}'); return
        (out / self.path.replace("/", "_")).write_bytes(body)
        self.send_response(201); self.end_headers(); self.wfile.write(b'{"stored":"ok"}')
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
    SERVER_PID=$!
    for _ in $(seq 50); do (echo > /dev/tcp/127.0.0.1/${PORT}) 2>/dev/null && break; sleep 0.1; done
    printf '     3.03           OBSERVATION DATA    M: Mixed            RINEX VERSION / TYPE\n' \
        > "${GNSS_BASE_DIR}/logs/202610271540.obs"
    printf '     3.03           N: GNSS NAV DATA    M: Mixed            RINEX VERSION / TYPE\n' \
        > "${GNSS_BASE_DIR}/logs/202610271540.nav"
}

teardown() {
    kill "${SERVER_PID}" 2>/dev/null || true
    rm -rf "${TMP}"
}

conf() {
    printf 'STATION_ID=XER7\nUPLOAD_KEY=%s\nUPLOAD_URL=http://127.0.0.1:%s\n0.0000 0.0000 0.0000\n' \
        "$1" "${PORT}" > "${GNSS_BASE_DIR}/scripts/station.conf"
}

@test "with the right key both files are PUT to the station's path and removed locally" {
    conf xrx_goodid_goodsecret
    run "${WORKER}"
    [ "$status" -eq 0 ]
    [ -s "${TMP}/received/_v1_stations_XER7_files_202610271540.obs" ]
    [ -s "${TMP}/received/_v1_stations_XER7_files_202610271540.nav" ]
    [ ! -e "${GNSS_BASE_DIR}/logs/202610271540.obs" ]
    [ ! -e "${GNSS_BASE_DIR}/logs/202610271540.nav" ]
    grep -q "Retry-uploaded 202610271540.obs" "${GNSS_BASE_DIR}/logs/automation.log"
}

@test "a refused key keeps the files for the next run and logs the HTTP status" {
    conf xrx_badid_badsecret
    run "${WORKER}"
    [ -e "${GNSS_BASE_DIR}/logs/202610271540.obs" ]
    [ -e "${GNSS_BASE_DIR}/logs/202610271540.nav" ]
    grep -q "HTTP 401" "${GNSS_BASE_DIR}/logs/automation.log"
}

@test "the key is never on curl's command line" {
    ! grep -nE 'CURL_EXEC.*UPLOAD_KEY|curl .*Bearer \$' "${WORKER}"
    grep -q -- '-K -' "${WORKER}"
}
