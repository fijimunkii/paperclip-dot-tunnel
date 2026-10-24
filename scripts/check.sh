#!/bin/sh
# Check each link in the chain: Paperclip -> Tailscale Serve -> API key -> tunnel-client.
# Never prints the key.
#
# Usage: ./scripts/check.sh https://<machine>.<tailnet>.ts.net
set -u
URL="${1:-${PAPERCLIP_PUBLIC_URL:-}}"
SERVICE="${TUNNEL_KEY_SERVICE:-openai-tunnel-paperclip}"
HEALTH="${TUNNEL_HEALTH:-http://127.0.0.1:8091}"
PAPERCLIP_LOCAL="${PAPERCLIP_LOCAL:-http://127.0.0.1:3100}"
[ -n "$URL" ] || { echo "Usage: $0 https://<machine>.<tailnet>.ts.net" >&2; exit 2; }

fails=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; fails=$((fails + 1)); }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

echo "Paperclip"
[ "$(code "$PAPERCLIP_LOCAL/api/health")" = 200 ] && ok "server answers on $PAPERCLIP_LOCAL" \
  || bad "server not answering on $PAPERCLIP_LOCAL" "Start Paperclip first."

echo "Tailscale Serve"
c="$(code -X POST "$URL/mcp/runner" -H 'Content-Type: application/json' -d '{}')"
[ "$c" = 401 ] && ok "$URL/mcp/runner asks for sign-in (401)" \
  || bad "$URL/mcp/runner returned $c (want 401)" "Check 'tailscale serve status' and that Dot + MCP are enabled in Paperclip."
meta="$(curl -s --max-time 10 "$URL/.well-known/oauth-protected-resource/mcp/runner")"
case "$meta" in
  *"\"resource\":\"$URL/mcp/runner\""*) ok "sign-in metadata points at $URL" ;;
  *) bad "sign-in metadata missing or points elsewhere" "Set PAPERCLIP_PUBLIC_URL and auth.publicBaseUrl to $URL, then restart Paperclip." ;;
esac

echo "OpenAI API key"
if key="$(security find-generic-password -a "$USER" -s "$SERVICE" -w 2>/dev/null)"; then
  [ "${#key}" -gt 128 ] && ok "Keychain item '$SERVICE' holds a ${#key}-character key" \
    || bad "stored key is only ${#key} characters" "Likely truncated by the password prompt. Re-store it with ./scripts/store-key.sh"
  # 401 = OpenAI doesn't recognise the key. 403 = real key without model access (fine for Tunnels-only).
  c="$(code https://api.openai.com/v1/models -H "Authorization: Bearer $key")"
  case "$c" in
    200|403) ok "OpenAI accepts the key ($c)" ;;
    401) bad "OpenAI rejects the key (401)" "Check it is active on the API keys page and stored in full." ;;
    *) bad "unexpected status $c from OpenAI" "Check your network." ;;
  esac
  unset key
else
  bad "no Keychain item '$SERVICE'" "Copy your key and run ./scripts/store-key.sh"
fi

echo "Tunnel"
r="$(curl -s --max-time 5 "$HEALTH/readyz")"
case "$r" in
  ready*) ok "tunnel-client is up ($HEALTH)"
          echo "        Note: 'ready' does not prove OpenAI accepted the key; look for 'poll failed' 401s in its log." ;;
  "") bad "tunnel-client not running on $HEALTH" "Start it with ./scripts/run-tunnel.sh" ;;
  *)  bad "tunnel-client not ready: $r" "See its log." ;;
esac

echo
[ "$fails" -eq 0 ] && echo "All checks passed." || echo "$fails check(s) failed."
exit "$fails"
