#!/bin/bash
# Install the omaclip server on a Debian/Ubuntu VPS.
#
#   sudo ./install.sh clips.example.com            # uploads over HTTPS with a token
#   sudo ./install.sh clips.example.com --tailnet  # uploads only over your Tailscale network
#
# Point the domain's DNS at this server first (an A record, not proxied), so Caddy
# can get its HTTPS certificate. Re-running is safe: the token and clips are kept.

set -euo pipefail

DOMAIN=${1:-}
MODE=public
[[ ${2:-} == --tailnet ]] && MODE=tailnet
PORT=8798
TAILNET_PORT=8446
DIR=/srv/omaclip
HERE=$(cd "$(dirname "$0")" && pwd)

if [[ -z $DOMAIN || $DOMAIN == -* ]]; then
  echo "usage: sudo $0 <domain> [--tailnet]" >&2
  exit 1
fi
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

echo "==> Packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq caddy ffmpeg python3 >/dev/null

echo "==> Service account and clip folder"
id omaclip >/dev/null 2>&1 || useradd --system --home "$DIR" --shell /usr/sbin/nologin omaclip
mkdir -p "$DIR" /opt/omaclip
chown omaclip:omaclip "$DIR"
chmod 755 "$DIR"
install -m 755 "$HERE/omaclip-server.py" /opt/omaclip/omaclip-server.py

if [[ -f /etc/omaclip.env ]] && grep -q '^OMACLIP_TOKEN=.' /etc/omaclip.env; then
  TOKEN=$(sed -n 's/^OMACLIP_TOKEN=//p' /etc/omaclip.env)
else
  TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
fi
cat >/etc/omaclip.env <<EOF
OMACLIP_URL=https://$DOMAIN
OMACLIP_TOKEN=$TOKEN
OMACLIP_DIR=$DIR
OMACLIP_BIND=127.0.0.1
OMACLIP_PORT=$PORT
OMACLIP_MAX_MB=4096
EOF
chmod 600 /etc/omaclip.env

cat >/etc/systemd/system/omaclip.service <<EOF
[Unit]
Description=omaclip upload API
After=network-online.target

[Service]
User=omaclip
EnvironmentFile=/etc/omaclip.env
ExecStart=/usr/bin/python3 /opt/omaclip/omaclip-server.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now omaclip >/dev/null
systemctl restart omaclip

echo "==> Caddy site for $DOMAIN ($MODE uploads)"
# Tailscale Serve can already hold :443 on the tailnet addresses. Caddy then has to
# bind only the public address, or it can't start.
BIND_LINE=""
if ss -ltnp 2>/dev/null | grep ':443 ' | grep -qv caddy; then
  PUBLIC_IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  BIND_LINE="	bind $PUBLIC_IP"
fi
if [[ $MODE == public ]]; then
  API="	handle /api/* {
		reverse_proxy 127.0.0.1:$PORT
	}"
else
  API="	handle /api/* {
		respond 404
	}"
fi
cat >/etc/caddy/omaclip.caddy <<EOF
# Managed by omaclip's install.sh.
$DOMAIN {
$BIND_LINE
$API
	handle {
		root * $DIR
		file_server
		header X-Robots-Tag "noindex, nofollow"
	}
}
EOF
grep -qx 'import /etc/caddy/omaclip.caddy' /etc/caddy/Caddyfile ||
  printf '\nimport /etc/caddy/omaclip.caddy\n' >>/etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl reload-or-restart caddy

UPLOAD_URL="https://$DOMAIN/api/upload"
if [[ $MODE == tailnet ]]; then
  command -v tailscale >/dev/null || { echo "--tailnet needs Tailscale installed and logged in." >&2; exit 1; }
  tailscale serve --bg --https=$TAILNET_PORT "http://127.0.0.1:$PORT" >/dev/null
  TS_NAME=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
  UPLOAD_URL="https://$TS_NAME:$TAILNET_PORT/api/upload"
fi

cat <<EOF

omaclip server is ready.

  Clips:   https://$DOMAIN/<id>/
  Uploads: $UPLOAD_URL
  Token:   $TOKEN

On your Omarchy machine, run:

  omaclip config set server https://$DOMAIN
  omaclip config set uploadUrl $UPLOAD_URL
  omaclip config set token $TOKEN
  omaclip test

(or paste the same three values into the omaclip panel in the bar).
EOF
