#!/usr/bin/env bash
#
# dev-auth.sh — Get a valid JWT for localhost API testing without the pairing UI.
#
# Inserts a dev device directly into bridge.db, then exchanges its refresh
# token for a JWT via POST /api/auth/token. JWT is printed to stdout;
# all diagnostics go to stderr.
#
# Usage:
#   TOKEN=$(./dev-auth.sh)
#   curl -H "Authorization: Bearer $TOKEN" http://localhost:7821/api/chats
#
#   ./dev-auth.sh --clean   # remove the dev device

set -euo pipefail

PORT="${PORT:-7821}"
BASE_URL="http://localhost:${PORT}"
DB_PATH="$HOME/.courier-bridge/bridge.db"
TOKEN_FILE="$HOME/.courier-bridge/dev-refresh-token"
DEV_DEVICE_ID="dev-claude-00000000-0000-0000-0000-000000000000"
DEV_DEVICE_NAME="dev-claude"

# ── clean mode ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--clean" ]]; then
  if [[ ! -f "$DB_PATH" ]]; then
    echo "No bridge.db found at $DB_PATH" >&2
    exit 0
  fi
  sqlite3 "$DB_PATH" "DELETE FROM paired_devices WHERE id = '$DEV_DEVICE_ID';"
  rm -f "$TOKEN_FILE"
  echo "Removed dev device and refresh token." >&2
  exit 0
fi

# ── preflight ───────────────────────────────────────────────────────────────
if [[ ! -f "$DB_PATH" ]]; then
  echo "Error: $DB_PATH not found. Start the server at least once first." >&2
  exit 1
fi

# ── ensure dev device exists ────────────────────────────────────────────────
EXISTING=$(sqlite3 "$DB_PATH" "SELECT refresh_token FROM paired_devices WHERE id = '$DEV_DEVICE_ID';")

if [[ -n "$EXISTING" ]]; then
  REFRESH_TOKEN="$EXISTING"
  echo "Using existing dev device." >&2
else
  # Generate a URL-safe base64 refresh token (matches generateRefreshToken() in AuthRoutes.swift)
  REFRESH_TOKEN=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')

  sqlite3 "$DB_PATH" "INSERT INTO paired_devices (id, name, refresh_token, created_at) VALUES ('$DEV_DEVICE_ID', '$DEV_DEVICE_NAME', '$REFRESH_TOKEN', datetime('now'));"
  echo "Created dev device." >&2

  # Persist token so we can inspect it later if needed
  echo "$REFRESH_TOKEN" > "$TOKEN_FILE"
fi

# ── exchange refresh token for JWT ──────────────────────────────────────────
if ! curl -sf "$BASE_URL/api/status" > /dev/null 2>&1; then
  echo "Warning: server not responding at $BASE_URL — printing refresh token instead." >&2
  echo "Start the server and re-run to get a JWT." >&2
  echo "$REFRESH_TOKEN"
  exit 0
fi

RESPONSE=$(curl -sf -X POST "$BASE_URL/api/auth/token" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\": \"$REFRESH_TOKEN\"}")

JWT=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['accessToken'])")

echo "JWT acquired (expires in 15 min)." >&2
echo "$JWT"
