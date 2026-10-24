#!/bin/sh
# Run OpenAI's tunnel-client for Paperclip Dot, reading the API key from the macOS Keychain
# so it never sits in a file or in shell history.
#
# Usage: ./scripts/run-tunnel.sh            (foreground; Ctrl-C to stop)
#        nohup ./scripts/run-tunnel.sh >> tunnel.log 2>&1 &
set -eu
SERVICE="${TUNNEL_KEY_SERVICE:-openai-tunnel-paperclip}"
PROFILE="${TUNNEL_PROFILE:-paperclip-dot}"
TUNNEL_CLIENT="${TUNNEL_CLIENT:-$(command -v tunnel-client || echo "$HOME/.local/bin/tunnel-client")}"

CONTROL_PLANE_API_KEY="$(security find-generic-password -a "$USER" -s "$SERVICE" -w)" || {
  echo "No key in Keychain item '$SERVICE'. Copy your key and run ./scripts/store-key.sh" >&2
  exit 1
}
export CONTROL_PLANE_API_KEY
exec "$TUNNEL_CLIENT" run --profile "$PROFILE"
