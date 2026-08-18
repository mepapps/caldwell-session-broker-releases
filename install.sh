#!/usr/bin/env bash
# ============================================================================
# session-broker - Linux installer
# ============================================================================
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/mepapps/caldwell-session-broker-releases/main/install.sh | bash
#
# Installs as a systemd USER service, running as YOU - not root, not a system
# account - and enables lingering so it survives reboot without you logging in.
#
# Options:
#   --install-dir /path   default: ~/tools/session-broker
#   --channel beta        install the latest prerelease
#   --port N              default: 7700
#   --no-linger           skip loginctl enable-linger
#
# Re-running updates in place. config.json, token.txt and logs/ are not in the
# archive, so they survive the overwrite.
# ============================================================================

set -euo pipefail

REPO="mepapps/caldwell-session-broker-releases"
INSTALL_DIR="${HOME}/tools/session-broker"
CHANNEL="latest"
PORT="${BROKER_PORT:-7700}"
DO_LINGER="yes"
UNIT_NAME="session-broker.service"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --channel)     CHANNEL="$2";     shift 2 ;;
        --port)        PORT="$2";        shift 2 ;;
        --no-linger)   DO_LINGER="no";   shift ;;
        --help|-h)
            echo "Usage: install.sh [--install-dir PATH] [--channel latest|beta] [--port N] [--no-linger]"
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

info() { printf '  %s\n' "$*"; }
good() { printf '  \033[32m%s\033[0m\n' "$*"; }
warn() { printf '  \033[33m%s\033[0m\n' "$*"; }
bad()  { printf '  \033[31m%s\033[0m\n' "$*"; }
die()  { bad "ERROR: $*"; exit 1; }

echo
echo "  ============================================================"
echo "   session-broker - Installer"
echo "  ============================================================"
echo

# --- preflight ---------------------------------------------------------------
[ "$(id -u)" -eq 0 ] && die "do not run as root - this installs a USER service so the broker runs as you"

for c in curl tar; do command -v "$c" >/dev/null || die "'$c' is required"; done
command -v node >/dev/null || die "Node.js not found. Install Node 20+ and re-run."

NODE_MAJOR="$(node --version | sed 's/^v//' | cut -d. -f1)"
[ "$NODE_MAJOR" -ge 20 ] || die "Node 20+ required, found $(node --version)"

command -v systemctl >/dev/null || die "systemctl not found - this installer targets systemd"
systemctl --user show-environment >/dev/null 2>&1 \
    || die "no systemd user manager for $USER. Try: sudo loginctl enable-linger $USER, then log in again."

info "Channel:    ${CHANNEL}"
info "Install to: ${INSTALL_DIR}"
info "User:       ${USER} (uid $(id -u))"
info "Node:       $(node --version)"
echo

# --- find the release --------------------------------------------------------
info "Finding ${CHANNEL} release..."

API="https://api.github.com/repos/${REPO}/releases"
if [[ "$CHANNEL" == "latest" ]]; then
    RELEASE_JSON="$(curl -fsSL "${API}/latest" -H 'Accept: application/vnd.github+json')" \
        || die "could not fetch the latest release. See https://github.com/${REPO}/releases"
else
    ALL="$(curl -fsSL "$API" -H 'Accept: application/vnd.github+json')" || die "could not fetch releases"
    RELEASE_JSON="$(node -e '
        let d=""; process.stdin.on("data",c=>d+=c).on("end",()=>{
          const r=JSON.parse(d).find(x=>x.prerelease);
          if(!r){console.error("no prerelease found");process.exit(1)}
          console.log(JSON.stringify(r));
        })' <<< "$ALL")" || die "no prerelease found. Use --channel latest."
fi

# node is already a hard requirement, so use it instead of adding a jq dependency.
read -r TAG URL ASSET < <(node -e '
    let d=""; process.stdin.on("data",c=>d+=c).on("end",()=>{
      const r=JSON.parse(d);
      const a=(r.assets||[]).find(x=>/linux-x64\.tar\.gz$/.test(x.name));
      if(!a){console.error("NO_ASSET");process.exit(1)}
      console.log(r.tag_name, a.browser_download_url, a.name);
    })' <<< "$RELEASE_JSON") || die "no linux-x64 asset in this release. See https://github.com/${REPO}/releases"

good "Found ${TAG}"
info "Downloading ${ASSET}..."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "${TMP}/${ASSET}" "$URL" || die "download failed"
good "Downloaded ($(du -m "${TMP}/${ASSET}" | cut -f1) MB)"

# --- stop a running instance -------------------------------------------------
# Files are locked while the broker runs, and Restart=always would bring it
# straight back mid-extract.
if systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    info "Stopping running service..."
    systemctl --user stop "$UNIT_NAME"
    sleep 2
fi

# --- extract in place --------------------------------------------------------
mkdir -p "$INSTALL_DIR"
info "Extracting to ${INSTALL_DIR}..."
tar -xzf "${TMP}/${ASSET}" -C "$INSTALL_DIR"
[ -f "${INSTALL_DIR}/install.sh" ] && chmod +x "${INSTALL_DIR}/install.sh"

BROKER_DIR="${INSTALL_DIR}/broker"
[ -f "${BROKER_DIR}/index.mjs" ] || die "archive did not contain broker/index.mjs"

# The tarball is built on Linux with node-pty already compiled; fail loudly if
# the native module still will not load rather than at first PTY use.
node -e "import('${BROKER_DIR}/node_modules/node-pty/lib/index.js').then(()=>0).catch(e=>{console.error(e.message);process.exit(1)})" 2>/dev/null \
    || warn "node-pty did not load - PTY sessions will fail. Try: (cd ${BROKER_DIR} && npm rebuild node-pty)"

# --- unit --------------------------------------------------------------------
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"

if [ -f "${INSTALL_DIR}/session-broker.service" ]; then
    sed -e "s|%h/tools/session-broker/broker|${BROKER_DIR}|g" \
        "${INSTALL_DIR}/session-broker.service" > "${UNIT_DIR}/${UNIT_NAME}"
else
    cat > "${UNIT_DIR}/${UNIT_NAME}" <<UNIT
[Unit]
Description=Session Broker - execute commands as this user over HTTP/MCP
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${BROKER_DIR}
ExecStart=/usr/bin/env node ${BROKER_DIR}/index.mjs
Restart=always
RestartSec=5
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=session-broker

[Install]
WantedBy=default.target
UNIT
fi

systemctl --user daemon-reload
systemctl --user enable "$UNIT_NAME" >/dev/null
info "Unit installed: ${UNIT_DIR}/${UNIT_NAME}"

# --- survive reboot ----------------------------------------------------------
# Without lingering the user manager is torn down at logout and the broker goes
# with it - so it would NOT come back after a reboot.
if [[ "$DO_LINGER" == "yes" ]]; then
    if loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
        info "Lingering already enabled (survives reboot)"
    elif sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
        good "Lingering enabled (survives reboot)"
    else
        warn "Could not enable lingering automatically. Run:"
        warn "    sudo loginctl enable-linger $USER"
        warn "Until then the broker stops when you log out."
    fi
fi

# --- start and verify --------------------------------------------------------
systemctl --user restart "$UNIT_NAME"
info "Starting..."

HEALTH=""
for _ in $(seq 1 60); do
    sleep 0.5
    HEALTH="$(curl -fsS "http://127.0.0.1:${PORT}/health" 2>/dev/null)" && break || HEALTH=""
done

echo
if [ -z "$HEALTH" ]; then
    bad "No health response within 30s."
    info "Logs: journalctl --user -u ${UNIT_NAME} -n 50 --no-pager"
    exit 1
fi

echo "  ============================================================"
good " INSTALLED - ${TAG}"
echo "  ============================================================"
echo
node -e '
const h = JSON.parse(process.argv[1]);
console.log(`  Location  : ${process.argv[2]}`);
console.log(`  Platform  : ${h.platform}`);
console.log(`  Identity  : ${h.session_user}  elevated=${h.elevated}  ${h.integrity_level}`);
console.log(`  Auth      : ${h.auth_mode}`);
' "$HEALTH" "$INSTALL_DIR"
info "Endpoint  : http://$(hostname):${PORT}"
echo
info "Control   : systemctl --user {status,restart,stop} ${UNIT_NAME}"
info "Logs      : journalctl --user -u ${UNIT_NAME} -f"
info "API       : curl http://127.0.0.1:${PORT}/help"

if printf '%s' "$HEALTH" | grep -q '"auth_mode": *"off"'; then
    echo
    warn "Auth is OFF - anything that can reach port ${PORT} runs as ${USER}."
    info "To enable a token:"
    info "  head -c 32 /dev/urandom | base64 > ${BROKER_DIR}/token.txt"
    info "  printf '{\"port\":%s,\"auth\":\"token\",\"bind\":\"auto\"}' ${PORT} > ${BROKER_DIR}/config.json"
    info "  systemctl --user restart ${UNIT_NAME}"
fi
echo
