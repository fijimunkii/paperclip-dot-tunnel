# Paperclip Dot over Secure MCP Tunnel

**Connect ChatGPT's Dot to a self-hosted Paperclip without opening it to the internet.**

This guide connects OpenAI Dot to a [Paperclip](https://github.com/paperclipai/paperclip) instance running on your own Mac. Nothing listens on the public internet: Paperclip stays on `127.0.0.1`, Tailscale Serve gives it an HTTPS name that only your tailnet can reach, and OpenAI's **Secure MCP Tunnel** carries ChatGPT's MCP traffic over an outbound connection from your machine.

> **Status:** Dot support in Paperclip is experimental (shipped in `2026.1023.0`). This guide was written from a working macOS setup on Paperclip `2026.1023.0`, tunnel-client `0.0.11` and Tailscale `1.104.1`.

This is an independent community guide. It is not affiliated with or endorsed by Paperclip, OpenAI or Tailscale Inc.

## Why this shape

The usual way to connect Dot is to give Paperclip a public HTTPS URL (for example with Tailscale Funnel). That works, but it puts Paperclip's sign-in and API on the internet.

| Approach | Who can reach Paperclip | Inbound ports |
| --- | --- | --- |
| Public URL (Funnel, reverse proxy) | Anyone on the internet | Yes |
| **This guide** (Serve + Secure MCP Tunnel) | Your tailnet, plus ChatGPT through your tunnel | None |

## Architecture

```text
ChatGPT / Dot
     |
     | MCP over OpenAI Secure MCP Tunnel
     v
tunnel-client on your Mac  (outbound connection only)
     |
     | https://<machine>.<tailnet>.ts.net/mcp/runner
     v
Tailscale Serve  (tailnet only, not Funnel)
     |
     v
Paperclip on 127.0.0.1:3100

Your browser ---- sign-in and pairing pages ----> https://<machine>.<tailnet>.ts.net
                  (direct, not through the tunnel: the browser must be on your tailnet)
```

The tunnel carries MCP calls and the OAuth registration and token requests. **The sign-in and pairing pages open in your browser directly**, so do those steps on a device that is on your tailnet.

## Requirements

- Paperclip `2026.1023.0` or later, running locally on macOS.
- Tailscale on the same Mac, with MagicDNS and HTTPS certificates enabled for your tailnet.
- An OpenAI organization with Secure MCP Tunnel access. Your account needs **Tunnels: Read and Use**.
- A ChatGPT plan where you can add custom MCP servers.
- OpenAI's [`tunnel-client`](https://platform.openai.com/settings/organization/tunnels) on your `PATH` or at `~/.local/bin/tunnel-client`.

Clone this repo for the helper scripts:

```sh
git clone https://github.com/fijimunkii/paperclip-dot-tunnel.git
cd paperclip-dot-tunnel
```

In the steps below, replace `<machine>.<tailnet>.ts.net` with your Mac's Tailscale name (`tailscale status --self` shows it).

## 1. Give Paperclip a tailnet-only HTTPS name

```sh
tailscale serve --bg http://127.0.0.1:3100
tailscale serve status
```

You should see `https://<machine>.<tailnet>.ts.net (tailnet only)`. Use **Serve**, not Funnel: Funnel makes the name public.

## 2. Tell Paperclip its URL

Stop Paperclip, then edit `<data-dir>/instances/default/config.json`:

```jsonc
{
  "server": {
    "exposure": "private",            // keep private (see note below)
    "host": "127.0.0.1",
    "port": 3100,
    "allowedHostnames": ["<machine>.<tailnet>.ts.net"]
  },
  "auth": {
    "baseUrlMode": "explicit",
    "publicBaseUrl": "https://<machine>.<tailnet>.ts.net",
    "disableSignUp": true             // recommended: no new accounts from the tailnet
  }
}
```

Add the same URL to `<data-dir>/instances/default/.env`:

```sh
PAPERCLIP_PUBLIC_URL=https://<machine>.<tailnet>.ts.net
```

Start Paperclip again.

> **Keep `exposure` set to `private`.** `public` requires an external `DATABASE_URL` and refuses to start with Paperclip's embedded Postgres ("authenticated public deployments require DATABASE_URL"). The explicit `publicBaseUrl` is all Dot needs.

## 3. Turn on Dot in Paperclip

In Paperclip, open **Instance settings → Experimental** and enable both:

- **Assistant connections (MCP)**
- **OpenAI Dot**

## 4. Create the tunnel and an API key

On the OpenAI Platform:

1. **Tunnels** (https://platform.openai.com/settings/organization/tunnels): create a tunnel and copy its ID (`tunnel_...`).
2. **API keys** (https://platform.openai.com/settings/organization/api-keys): create a key in the **same organization and project** as the tunnel. This is a normal runtime key, not an admin key. Restricting it to **Tunnels: Read and Use** is enough.

## 5. Store the key in Keychain

Copy the key, then:

```sh
./scripts/store-key.sh
```

It reads the key from the clipboard, stores it in the Keychain item `openai-tunnel-paperclip`, and clears the clipboard.

> **Don't paste the key at `security`'s password prompt.** macOS's hidden prompt silently cuts input off at 128 characters. Project keys (`sk-proj-...`) are longer, so the stored key is truncated and OpenAI returns `401 invalid_api_key` even though everything looks right.

## 6. Create the tunnel-client profile

```sh
tunnel-client init \
  --profile paperclip-dot \
  --sample sample_mcp_with_dcr \
  --tunnel-id tunnel_... \
  --mcp-server-url https://<machine>.<tailnet>.ts.net/mcp/runner \
  --health-listen-addr 127.0.0.1:8091
```

`sample_mcp_with_dcr` is the template for MCP servers with OAuth and dynamic client registration, which is what Paperclip provides. The profile reads the key from `env:CONTROL_PLANE_API_KEY`; the run script fills that in from Keychain.

Point the tunnel at the `ts.net` URL, not `127.0.0.1`: Paperclip's OAuth metadata names the `ts.net` address, and the two need to match.

## 7. Start the tunnel and check everything

```sh
nohup ./scripts/run-tunnel.sh >> tunnel.log 2>&1 &
./scripts/check.sh https://<machine>.<tailnet>.ts.net
```

`check.sh` checks each link in turn without printing the key:

```text
Paperclip
  ok    server answers on http://127.0.0.1:3100
Tailscale Serve
  ok    https://<machine>.<tailnet>.ts.net/mcp/runner asks for sign-in (401)
  ok    sign-in metadata points at https://<machine>.<tailnet>.ts.net
OpenAI API key
  ok    Keychain item 'openai-tunnel-paperclip' holds a 1xx-character key
  ok    OpenAI accepts the key (403)
Tunnel
  ok    tunnel-client is up (http://127.0.0.1:8091)
        Note: 'ready' does not prove OpenAI accepted the key; look for 'poll failed' 401s in its log.

All checks passed.
```

A **403** from OpenAI is the expected result for a Tunnels-only key: the key is real but can't list models. A **401** means OpenAI doesn't recognise the key at all.

The tunnel log will show one `failed to connect to mcp ... Unauthorized` error at startup. That's expected: the tunnel probes Paperclip without signing in. It has no "poll failed" lines once the key is accepted.

The tunnel's status page is at http://127.0.0.1:8091/ui.

## 8. Add the connector in ChatGPT

With the tunnel running, open ChatGPT **Settings → Connectors** (https://chatgpt.com/#settings/Connectors) and add a **custom MCP server**:

- **Connection:** Tunnel, then choose your `tunnel_...` ID. No URL is needed.
- **Authentication:** OAuth. Leave client ID and secret blank; Paperclip lets ChatGPT register itself.

Save. ChatGPT opens Paperclip's connection page on `https://<machine>.<tailnet>.ts.net`, which asks for a pairing code.

If Tunnel isn't offered, check that your ChatGPT account has **Tunnels: Use** in the tunnel's organization, and turn on Developer mode in the connectors' advanced settings if your plan requires it.

## 9. Pair Dot

1. In Paperclip, choose **New Agent → Invite an external agent → Dot**. Paperclip creates the Dot agent and shows a setup prompt containing a **one-time pairing code** (valid for 15 minutes).
2. On the connection page from step 8, enter the code. Paperclip shows the company, agent and permissions; previewing doesn't grant anything.
3. Click **Connect Dot with pairing code**.
4. Paste the whole setup prompt into your Dot conversation in ChatGPT. Dot runs a test event, and Paperclip marks it ready once the round trip succeeds. If Dot can't see the Paperclip tools, attach the connector to the conversation.

If the code expires, reopening setup in Paperclip issues a new one.

## Keeping it running

The tunnel must be running for every Dot call. `run-tunnel.sh` doesn't restart itself after a reboot. To start it at login, a launchd agent along these lines works (adjust the paths; this template hasn't been tested as-is):

```xml
<!-- ~/Library/LaunchAgents/local.paperclip-dot-tunnel.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.paperclip-dot-tunnel</string>
  <key>ProgramArguments</key><array><string>/path/to/paperclip-dot-tunnel/scripts/run-tunnel.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/path/to/paperclip-dot-tunnel/tunnel.log</string>
  <key>StandardErrorPath</key><string>/path/to/paperclip-dot-tunnel/tunnel.log</string>
</dict></plist>
```

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.paperclip-dot-tunnel.plist
```

The first Keychain read from launchd may ask for permission; choose **Always Allow**.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Tunnel log: `poll failed ... 401 invalid_api_key`, but `/readyz` says `ready` | `/readyz` only reflects the local side; OpenAI is rejecting the key | Run `check.sh`; fix the key |
| `tunnel-client doctor` passes, tunnel still gets 401 | `doctor` checks that a key is set, not that OpenAI accepts it | Use `check.sh`, which calls OpenAI |
| Key looks right, OpenAI still says 401 | Key truncated to 128 characters by the password prompt | Re-store with `./scripts/store-key.sh` |
| 401 with a fresh key from the right page | Key is in a different organization or project than the tunnel, or was revoked | Create the key alongside the tunnel |
| Paperclip won't start: `authenticated public deployments require DATABASE_URL` | `server.exposure` set to `public` with embedded Postgres | Set it back to `private`; keep `publicBaseUrl` |
| Sign-in or pairing page won't load | The browser isn't on your tailnet | Open it on a device signed in to Tailscale |
| `check.sh`: sign-in metadata points elsewhere | `PAPERCLIP_PUBLIC_URL` or `auth.publicBaseUrl` not set to the `ts.net` URL | Set both and restart Paperclip |
| Tunnel option missing in ChatGPT | Account lacks **Tunnels: Use**, or custom MCP needs Developer mode | Grant the role / enable Developer mode |

## Security notes

- Nothing new listens on the internet. The tunnel connects out to OpenAI, and Serve is tailnet-only.
- Anyone on your tailnet can reach Paperclip's web UI. Keep `disableSignUp: true` and review who is on the tailnet.
- The API key lives in Keychain. It never goes into the tunnel profile, a `.env` file or shell history.
- Revoke Dot's access in Paperclip if you stop using it. Revoking or rotating the API key stops the tunnel.
- On macOS, Paperclip gives Dot file tools only; running commands is disabled.
- Task text, files and anything Dot reads are untrusted model input. Scope Dot's agent permissions in Paperclip accordingly.

## Files

| File | Purpose |
| --- | --- |
| `scripts/store-key.sh` | Stores the API key in Keychain from the clipboard, avoiding the 128-character prompt limit |
| `scripts/run-tunnel.sh` | Runs tunnel-client with the key from Keychain |
| `scripts/check.sh` | Checks Paperclip, Tailscale Serve, the key and the tunnel |

Environment overrides: `TUNNEL_KEY_SERVICE` (Keychain item, default `openai-tunnel-paperclip`), `TUNNEL_PROFILE` (default `paperclip-dot`), `TUNNEL_HEALTH` (default `http://127.0.0.1:8091`), `PAPERCLIP_LOCAL` (default `http://127.0.0.1:3100`).

## Related

- [chatgpt-plugin-tailscale](https://github.com/fijimunkii/chatgpt-plugin-tailscale): the same Tailscale + Secure MCP Tunnel pattern, for giving ChatGPT bounded access to machines on your tailnet.
