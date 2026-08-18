# session-broker

**Let an AI agent run commands on your machine, as you, with your privileges.**

An agent connecting over SSH lands in the wrong user context — a service account, not the logged-in desktop session — so it cannot see or control anything your session owns. On Windows that's not even fixable: OpenSSH cannot mint S4U tokens for Entra ID accounts ([Win32-OpenSSH #1787](https://github.com/PowerShell/Win32-OpenSSH/issues/1787)). The broker bridges that gap.

## What can you do with it?

Point Claude, Hermes, or any MCP-capable agent at it and ask things like:

- *"Update everything with winget and show me the log"*
- *"Restart the SQL Server service"* — real admin rights, no elevation dance
- *"Run the build and tell me when it finishes"* — jobs outlive the conversation
- *"Open a terminal and step through this interactive installer"*

## How does it work?

A small Node service runs inside your logged-in session. Agents reach it three ways — all backed by one implementation, so behaviour is identical:

| Interface | For |
|---|---|
| **MCP** (`/mcp`) | AI agents. 13 typed tools, hosted by the broker — nothing to install on the agent. |
| **CLI** (`/client`) | Scripts, humans, cron. Self-contained, downloaded from the broker itself. |
| **HTTP** | Anything else. `GET /help` documents every route with working examples. |

Jobs run asynchronously with structured logs, survive client disconnects, and can be killed by id. Real terminal sessions (ConPTY on Windows, pty on Linux) are available for TUIs and anything that checks `isatty`.

## Install

**Windows** — open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/mepapps/caldwell-session-broker-releases/main/install.ps1 | iex
```

It will prompt for elevation — the scheduled task must run with highest privileges or the broker ends up on Windows' filtered token and every admin operation fails.

**Linux** — open a terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/mepapps/caldwell-session-broker-releases/main/install.sh | bash
```

Node 20+ is the only prerequisite. Dependencies are bundled — no `npm install`, no build toolchain, no registry access.

| Platform | Default location | Runs as |
|---|---|---|
| Windows | `C:\Tools\session-broker` | Scheduled task, your account, elevated |
| Linux | `~/tools/session-broker` | systemd **user** service + lingering |

Takes about 30 seconds.

## Getting started

### 1. Check it came up

```bash
curl http://127.0.0.1:7700/health
```

On Windows expect `"elevated": true` and `"integrity_level": "High"`. **If you see `Medium`, stop** — the broker is on the filtered token and admin operations will fail; re-run the installer from an elevated prompt.

On Linux `"elevated": false` is correct — a user service is meant to be unprivileged.

### 2. Turn on the token

Auth ships **off** so you can confirm it works first. Anything that can reach the port runs commands as you, so don't leave it off on a shared network.

**Windows**

```powershell
cd C:\Tools\session-broker\broker
[Convert]::ToBase64String((1..32|%{Get-Random -Max 256})) | Set-Content token.txt -NoNewline
'{"port":7700,"auth":"token","bind":"auto"}' | Set-Content config.json
.\broker.ps1 restart
```

**Linux**

```bash
cd ~/tools/session-broker/broker
head -c 32 /dev/urandom | base64 > token.txt
printf '{"port":7700,"auth":"token","bind":"auto"}' > config.json
systemctl --user restart session-broker
```

### 3. Connect an agent

```bash
claude mcp add --transport http session-broker http://<host>:7700/mcp \
  --header "Authorization: Bearer $TOKEN"
```

Or grab the CLI:

```bash
curl -s http://<host>:7700/client -o broker.mjs
export BROKER_URL=http://<host>:7700 BROKER_TOKEN=<token>
node broker.mjs status
node broker.mjs run "hostname"
```

## What's included

| Capability | What it does |
|---|---|
| **Command execution** | Sync or async, any shell, full output, no size cap, no default timeout |
| **Job management** | List, inspect, tail logs, stream via SSE, kill the whole process tree |
| **Terminal sessions** | Real PTY — full-screen TUIs, resize, `isatty` true |
| **MCP server** | 13 tools over streamable HTTP, hosted by the broker |
| **Self-served CLI** | `GET /client`, zero dependencies, never contains a token |
| **Self-describing API** | `GET /help` — enough for a cold agent to use every endpoint |

## Network scope

The broker binds loopback, RFC1918 LAN, and CGNAT/Tailscale addresses. **A public address is refused at startup** — it is not designed to face the internet.

## Updating

Re-run the same install command. It stops the service, extracts over the install, and restarts. `config.json`, `token.txt` and `logs/` are not in the archive, so they survive untouched.

## Uninstall

**Windows:** `cd C:\Tools\session-broker; .\install.ps1 -Uninstall`
**Linux:** `cd ~/tools/session-broker; ./install.sh --uninstall`

Both remove the service and leave your files in place.

## Links

- [All releases](https://github.com/mepapps/caldwell-session-broker-releases/releases)
- Full documentation, architecture, and the requirements this was built against ship inside the release as `README.md` and `session-broker-prd.md`.
