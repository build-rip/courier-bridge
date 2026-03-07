#!/bin/zsh
set -euo pipefail

PORT=7821
TUNNEL_NAME=courier-bridge-dev
DEBOUNCE_SECONDS=1

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log() { echo -e "${CYAN}[dev]${RESET} $1"; }
err() { echo -e "${RED}[dev]${RESET} $1"; }

# --- Cleanup on exit ---
BRIDGE_PID=""
TUNNEL_PID=""

cleanup() {
    log "Shutting down..."
    [[ -n "$BRIDGE_PID" ]] && kill "$BRIDGE_PID" 2>/dev/null && wait "$BRIDGE_PID" 2>/dev/null
    [[ -n "$TUNNEL_PID" ]] && kill -9 "$TUNNEL_PID" 2>/dev/null
    log "Done."
    exit 0
}
trap cleanup INT TERM

# --- Preflight ---
for cmd in cloudflared swift fswatch; do
    if ! command -v "$cmd" &>/dev/null; then
        err "$cmd not found. Install it with: brew install $cmd"
        exit 1
    fi
done

# --- Check tunnel exists ---
if ! cloudflared tunnel info "$TUNNEL_NAME" &>/dev/null; then
    err "Cloudflare tunnel '${TUNNEL_NAME}' not found."
    echo ""
    echo -e "${BOLD}Create it with:${RESET}"
    echo ""
    echo "  cloudflared tunnel login"
    echo "  cloudflared tunnel create ${TUNNEL_NAME}"
    echo "  cloudflared tunnel route dns ${TUNNEL_NAME} ${TUNNEL_NAME}.build.rip"
    echo ""
    exit 1
fi

# --- Start tunnel ---
log "Starting named tunnel: ${TUNNEL_NAME}..."
cloudflared tunnel --url "http://localhost:${PORT}" run "$TUNNEL_NAME" 2>&1 | sed "s/^/$(printf "${CYAN}[tunnel]${RESET}") /" &
TUNNEL_PID=$!

sleep 2
if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    err "Tunnel exited unexpectedly."
    exit 1
fi
log "Tunnel is running."

# --- Build & start server ---
start_server() {
    log "Starting bridge on port ${PORT}..."
    BRIDGE_URL="https://${TUNNEL_NAME}.build.rip" PORT=$PORT .build/debug/courier-bridge 2>&1 &
    BRIDGE_PID=$!

    for i in $(seq 1 30); do
        if lsof -iTCP:"$PORT" -sTCP:LISTEN -nP &>/dev/null; then
            echo ""
            echo -e "${BOLD}${GREEN}========================================${RESET}"
            echo -e "${BOLD}${GREEN}  Bridge running on port ${PORT}${RESET}"
            echo -e "${BOLD}${GREEN}  Tunnel: ${TUNNEL_NAME}${RESET}"
            echo -e "${BOLD}${GREEN}========================================${RESET}"
            echo ""
            return 0
        fi
        if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
            err "Bridge process exited unexpectedly."
            BRIDGE_PID=""
            return 1
        fi
        sleep 1
    done

    err "Bridge did not start listening on port ${PORT} within 30s."
    return 1
}

stop_server() {
    # Send SIGTERM (graceful — removes menu bar icon) then wait
    if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
        log "Stopping old server..."
        kill "$BRIDGE_PID" 2>/dev/null
        # Wait up to 3s for graceful exit, then SIGKILL as fallback
        for i in $(seq 1 6); do
            kill -0 "$BRIDGE_PID" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$BRIDGE_PID" 2>/dev/null; then
            kill -9 "$BRIDGE_PID" 2>/dev/null
        fi
        wait "$BRIDGE_PID" 2>/dev/null || true
        BRIDGE_PID=""
    fi
    # Kill anything still holding the port and wait for it to be free
    local stale_pid
    stale_pid=$(lsof -iTCP:"$PORT" -sTCP:LISTEN -nP -t 2>/dev/null || true)
    if [[ -n "$stale_pid" ]]; then
        log "Killing stale process on port ${PORT} (PID ${stale_pid})..."
        kill "$stale_pid" 2>/dev/null
        for i in $(seq 1 6); do
            lsof -iTCP:"$PORT" -sTCP:LISTEN -nP &>/dev/null || break
            sleep 0.5
        done
        # Fallback to SIGKILL if still alive
        if lsof -iTCP:"$PORT" -sTCP:LISTEN -nP &>/dev/null; then
            kill -9 "$stale_pid" 2>/dev/null
            sleep 1
        fi
    fi
}

rebuild() {
    log "Building courier-bridge..."
    if swift build 2>&1 | tail -20; then
        stop_server
        start_server
    else
        err "Build failed! Keeping old server running."
    fi
}

# --- Initial build ---
rebuild
if [[ -z "$BRIDGE_PID" ]]; then
    err "Initial build/start failed."
    exit 1
fi

log "Watching for changes... (press Ctrl+C to stop)"

# --- Watch for file changes (process substitution keeps while body in current shell) ---
while read -r _count; do
    echo ""
    log "Change detected, rebuilding..."
    rebuild
done < <(fswatch -o -l "$DEBOUNCE_SECONDS" Sources/ Package.swift)
