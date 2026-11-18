#!/usr/bin/env bash
# Make this machine reachable through the session-broker relay with a PIN, for
# as long as this terminal stays open.
#
#   curl -fsSL https://raw.githubusercontent.com/mepapps/caldwell-session-broker-releases/main/connect.sh | bash
#
# Nothing is installed: the connect tool downloads to a temp folder, runs in
# this terminal, and is removed when it ends. Close the terminal to end the
# session, or press Ctrl+C twice - once only warns.
#
# SESSION_BROKER_CONNECT_ASSET=<url or .tar.gz>  use a specific download

set -euo pipefail

REPO=mepapps/caldwell-session-broker-releases
TMP="${TMPDIR:-/tmp}"

# Leftovers from an earlier session whose cleanup never got to run. Only
# folders a day old, so a session still running is never touched.
find "$TMP" -maxdepth 1 \( -name 'session-broker-connect-*' -o -name 'session-broker-rt-*' \) \
  -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

asset="${SESSION_BROKER_CONNECT_ASSET:-}"
if [ -z "$asset" ]; then
  echo "  Finding the latest release..."
  asset=$(curl -fsSL -H 'User-Agent: session-broker-connect' \
            "https://api.github.com/repos/$REPO/releases/latest" \
          | grep -o '"browser_download_url": *"[^"]*caldwell-session-broker-connect-[^"]*-linux-x64\.tar\.gz"' \
          | head -1 | sed 's/.*"\(http[^"]*\)"$/\1/')
  if [ -z "$asset" ]; then
    echo "  No connect download in the latest release." >&2
    exit 1
  fi
fi

dir=$(mktemp -d "$TMP/session-broker-connect-XXXXXXXX")
cleanup() { rm -rf "$dir"; }
trap cleanup EXIT HUP INT TERM

echo "  Downloading..."
case "$asset" in
  http://*|https://*) curl -fsSL "$asset" | tar -xz -C "$dir" ;;
  *)                  tar -xzf "$asset" -C "$dir" ;;
esac

# stdin from /dev/null: when this script arrives through `curl | bash`, bash is
# reading the script from stdin, and a child that read it would eat the rest.
"$dir/session-broker-connect" --ephemeral </dev/null
