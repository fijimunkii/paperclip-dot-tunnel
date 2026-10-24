#!/bin/sh
# Store the OpenAI runtime API key for the tunnel in the macOS Keychain, from the clipboard.
#
# Why the clipboard: macOS's hidden password prompt (used by `security ... -w` with no value)
# silently truncates input at 128 characters. Project keys (sk-proj-...) are longer, so a key
# pasted at that prompt is stored cut short and OpenAI answers 401 invalid_api_key.
#
# Usage: copy the key, then run ./scripts/store-key.sh
set -eu
SERVICE="${TUNNEL_KEY_SERVICE:-openai-tunnel-paperclip}"

key="$(pbpaste | tr -d '[:space:]')"
case "$key" in
  sk-*) ;;
  *) echo "The clipboard doesn't hold an OpenAI key (expected sk-...)." >&2; exit 1 ;;
esac
if [ "${#key}" -le 128 ]; then
  echo "Warning: the key is only ${#key} characters. Project keys are usually longer; check it was copied in full." >&2
fi

# The key is briefly visible in the process list while this command runs.
security add-generic-password -U -a "$USER" -s "$SERVICE" -w "$key"
pbcopy </dev/null
echo "Stored a ${#key}-character key in Keychain item '$SERVICE'. Clipboard cleared."
