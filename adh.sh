#!/usr/bin/env bash
# x-ui-adguard.sh — AdGuard Home as a private DNS-over-HTTPS resolver,
#                   published on the existing 3x-ui panel domain.
#
# For servers built by vr.sh: nginx SNI dispatcher on :443 sends the Reality
# domain to xray on :8443 and the panel domain to nginx on :7443.  This adds
# a DoH endpoint and the AdGuard Home UI to the panel vhost.
#
# WHY DoH AND NOT DoT
#   DoT is identified by its port number alone (853) — one firewall rule kills
#   it, no DPI needed.  DoH on :443 at a random path looks like ordinary HTTPS
#   to the same host: same port, same ALPN, same certificate.  It also leaves
#   nginx as the sole owner of the TLS certificate, so certbot renewal needs no
#   extra hook and AdGuard Home never restarts for a new cert.
#
# WHY A RANDOM PATH
#   AdGuard Home serves DoH at /dns-query.  Publishing that well-known path
#   turns the domain into a scannable open resolver.  nginx publishes
#   /<random>/dns-query and rewrites it to /dns-query internally.
#
# LOOPBACK ONLY
#   AdGuard Home binds 127.0.0.1 for both the web UI and plain DNS.  Port 53 is
#   never touched, so systemd-resolved keeps working.
#
# ABSOLUTE PATHS
#   If AdGuard Home cannot find its config it does not fail — it treats the run
#   as a first launch and serves the setup wizard on 0.0.0.0:3000, i.e. on the
#   public IP.  The service is installed with absolute -c/-w, and the script
#   refuses to finish if it ever sees that port open.
#
# MAINTENANCE
#   certificates    nothing to do — nginx owns them, certbot reloads nginx
#   AdGuard Home    agh-autoupdate.timer runs `AdGuardHome --update` weekly
#   3x-ui panel     updating the panel does not touch nginx; nothing to do
#
#   The one thing that would break this: re-running the vr.sh installer, which
#   does `rm -rf /etc/nginx/sites-available/*` and regenerates the vhosts.
#   That is a one-time bootstrap script, but if you ever do re-run it, just run
#   this script again afterwards — it restores the include and keeps your
#   settings, password, paths and ports.
#
# Usage:
#   bash x-ui-adguard.sh                # install / repair (safe to re-run)
#   bash x-ui-adguard.sh -uninstall y   # remove everything this script added
#
set -Eeuo pipefail

XUIDB="/etc/x-ui/x-ui.db"
AGH_DIR="/opt/AdGuardHome"
AGH_BIN="${AGH_DIR}/AdGuardHome"
AGH_YAML="${AGH_DIR}/AdGuardHome.yaml"
AGH_STATE="${AGH_DIR}/.install-state"
AGH_SNIPPET="/etc/nginx/snippets/adguard.conf"
AGH_SERVICE="AdGuardHome"
NGINX_SITES="/etc/nginx/sites-available"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m[*] %s\033[0m\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

uninstall=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -uninstall|--uninstall) uninstall="${2:-}"; shift 2;;
        *) die "Unknown argument: $1 (supported: -uninstall y)";;
    esac
done

# ── uninstall ─────────────────────────────────────────────────────────────────
if [[ "$uninstall" == "y" ]]; then
    blue "Removing AdGuard Home and everything this script installed..."
    systemctl disable --now agh-autoupdate.timer 2>/dev/null || true
    rm -f /etc/systemd/system/agh-autoupdate.{service,timer}
    systemctl daemon-reload 2>/dev/null || true

    systemctl stop "$AGH_SERVICE" 2>/dev/null || true
    [[ -x "$AGH_BIN" ]] && "$AGH_BIN" -s uninstall 2>/dev/null || true
    rm -rf "$AGH_DIR" "$AGH_SNIPPET"

    shopt -s nullglob
    for f in "$NGINX_SITES"/*; do
        [[ -f "$f" ]] && sed -i '\|snippets/adguard.conf|d' "$f"
    done
    shopt -u nullglob

    if nginx -t &>/dev/null; then systemctl reload nginx; fi
    green "Removed."
    exit 0
fi

# ── prerequisites ─────────────────────────────────────────────────────────────
[[ -f "$XUIDB" ]] || die "x-ui.db not found at $XUIDB — install the panel first"
command -v nginx &>/dev/null || die "nginx not found"

blue "Installing packages..."
apt-get update -qq
# apache2-utils provides htpasswd (bcrypt).  Without it the admin password hash
# comes out empty and the UI is left unprotected, so it is mandatory.
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
    curl tar ca-certificates sqlite3 apache2-utils
command -v htpasswd &>/dev/null || die "htpasswd missing after installing apache2-utils"

rand_str() { tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$1" || true; }
free_port() {
    local p
    while true; do
        p=$(( ((RANDOM<<15)|RANDOM) % 45000 + 20000 ))
        ss -Hln "sport = :$p" 2>/dev/null | grep -q . || { echo "$p"; return; }
    done
}

# ── locate the panel vhost ────────────────────────────────────────────────────
blue "Detecting panel domain..."

# The panel's own certificate path in x-ui.db is authoritative.  Do not select
# the vhost by "listen 7443" alone: hy2.sh creates a Nextcloud-masquerade vhost
# on that same port for a different domain, so on a server where it has run the
# directory order could pick the wrong file.
domain=""
web_cert="$(sqlite3 "$XUIDB" "SELECT value FROM settings WHERE key='webCertFile';" 2>/dev/null || true)"
if [[ "$web_cert" =~ ^/root/cert/([^/]+)/ || "$web_cert" =~ ^/etc/letsencrypt/live/([^/]+)/ ]]; then
    domain="${BASH_REMATCH[1]}"
fi

vhost=""
if [[ -n "$domain" ]]; then
    esc="${domain//./\\.}"
    shopt -s nullglob
    for f in "$NGINX_SITES"/*; do
        [[ -f "$f" ]] || continue
        grep -q 'listen 7443' "$f" 2>/dev/null || continue
        grep -qE "^[[:space:]]*server_name[[:space:]]+${esc}[[:space:]]*;" "$f" || continue
        vhost="$f"; break
    done
    shopt -u nullglob
fi

# Fallback: unrecognised certificate layout — fall back to the port, and take
# whichever vhost carries it.
if [[ -z "$vhost" ]]; then
    shopt -s nullglob
    for f in "$NGINX_SITES"/*; do
        [[ -f "$f" ]] || continue
        if grep -q 'listen 7443' "$f" 2>/dev/null; then vhost="$f"; break; fi
    done
    shopt -u nullglob
    [[ -n "$vhost" ]] && domain="$(awk '/server_name/{print $2; exit}' "$vhost" | tr -d ';')"
fi

[[ -n "$vhost"  ]] || die "Could not find the panel vhost in $NGINX_SITES"
[[ -n "$domain" ]] || die "Could not determine the panel domain"
printf "    domain = %s\n    vhost  = %s\n" "$domain" "$vhost"

# ── reuse previous parameters on re-run ───────────────────────────────────────
doh_path="" admin_path="" web_port="" dns_port=""
# shellcheck disable=SC1090
[[ -f "$AGH_STATE" ]] && source "$AGH_STATE"
if [[ -z "$doh_path" && -f "$AGH_SNIPPET" ]]; then
    doh_path="$(grep -oP 'location /\K[a-zA-Z0-9]+(?=/dns-query)' "$AGH_SNIPPET" | head -1 || true)"
    admin_path="$(grep -oP 'location /\Kadg-[a-zA-Z0-9]+' "$AGH_SNIPPET" | head -1 || true)"
fi
if [[ -z "$web_port" && -f "$AGH_YAML" ]]; then
    web_port="$(grep -oP '^\s*address:\s*127\.0\.0\.1:\K\d+' "$AGH_YAML" | head -1 || true)"
    dns_port="$(awk '/^dns:/{d=1} d&&/^\s+port:/{print $2; exit}' "$AGH_YAML" || true)"
fi
[[ -n "$doh_path"   ]] || doh_path="$(rand_str 12)"
[[ -n "$admin_path" ]] || admin_path="adg-$(rand_str 12)"
[[ -n "$web_port"   ]] || web_port="$(free_port)"
[[ -n "$dns_port"   ]] || dns_port="$(free_port)"

# ── download ──────────────────────────────────────────────────────────────────
case "$(uname -m)" in
    x86_64)  agh_arch="amd64";;
    aarch64) agh_arch="arm64";;
    armv7l)  agh_arch="armv7";;
    *) die "Unsupported architecture: $(uname -m)";;
esac

if [[ -x "$AGH_BIN" ]]; then
    blue "AdGuard Home already present — keeping it (agh-autoupdate.timer maintains it)."
else
    blue "Downloading AdGuard Home (linux_${agh_arch})..."
    curl -fsSL "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${agh_arch}.tar.gz" \
        | tar -xz -C /opt
    [[ -x "$AGH_BIN" ]] || die "Download or extract failed — $AGH_BIN missing"
fi
chmod 700 "$AGH_DIR"

# ── seed the config (never clobber an existing one) ───────────────────────────
new_credentials=0
agh_user="admin"
agh_pass=""
if [[ -f "$AGH_YAML" ]]; then
    blue "Existing AdGuardHome.yaml found — settings and credentials kept."
else
    blue "Generating AdGuardHome.yaml..."
    new_credentials=1
    agh_pass="$(rand_str 20)"
    agh_hash="$(htpasswd -nbB x "$agh_pass" | cut -d: -f2)"
    [[ "$agh_hash" == \$2* ]] || die "bcrypt hash generation failed"

    systemctl stop "$AGH_SERVICE" 2>/dev/null || true
    # schema_version 28 is migrated forward automatically by current releases.
    cat > "$AGH_YAML" <<EOF
http:
  address: 127.0.0.1:${web_port}
users:
  - name: ${agh_user}
    password: ${agh_hash}
auth_attempts: 5
block_auth_min: 15
theme: auto
dns:
  bind_hosts:
    - 127.0.0.1
  port: ${dns_port}
  upstream_dns:
    - https://dns.cloudflare.com/dns-query
    - https://dns.google/dns-query
    - https://dns.quad9.net/dns-query
  bootstrap_dns:
    - 1.1.1.1
    - 8.8.8.8
    - 9.9.9.9
  # nginx forwards over loopback, so real client IPs arrive in X-Forwarded-For.
  # This makes the Clients page useful and lets you filter per client.
  trusted_proxies:
    - 127.0.0.0/8
tls:
  enabled: false
  # nginx terminates TLS; the DoH handler must accept plain HTTP behind it.
  # It is bound to loopback and never reachable off-host.
  allow_unencrypted_doh: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
schema_version: 28
EOF
    chmod 600 "$AGH_YAML"
fi

cat > "$AGH_STATE" <<EOF
doh_path="${doh_path}"
admin_path="${admin_path}"
web_port="${web_port}"
dns_port="${dns_port}"
EOF
chmod 600 "$AGH_STATE"

# ── service ───────────────────────────────────────────────────────────────────
if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${AGH_SERVICE}\.service"; then
    blue "Restarting AdGuard Home..."
    systemctl restart "$AGH_SERVICE"
else
    blue "Installing the AdGuard Home service..."
    "$AGH_BIN" -s install -c "$AGH_YAML" -w "$AGH_DIR"
fi

blue "Waiting for AdGuard Home..."
agh_up=0
for _ in $(seq 1 30); do
    curl -fso /dev/null "http://127.0.0.1:${web_port}/" && { agh_up=1; break; }
    sleep 0.5
done
[[ $agh_up -eq 1 ]] \
    || die "AdGuard Home did not come up on 127.0.0.1:${web_port} — journalctl -u ${AGH_SERVICE}"

# If it ignored the config it is now serving the setup wizard on the public IP.
if ss -Hln 2>/dev/null | grep -qE '(0\.0\.0\.0|\[::\]):3000\b'; then
    systemctl stop "$AGH_SERVICE" 2>/dev/null || true
    die "AdGuard Home bound 0.0.0.0:3000 — it did not read its config. Service stopped."
fi

# ── nginx ─────────────────────────────────────────────────────────────────────
blue "Writing nginx snippet..."
mkdir -p /etc/nginx/snippets
cat > "$AGH_SNIPPET" <<EOF
    # AdGuard Home — DNS-over-HTTPS on a non-obvious path.  nginx rewrites
    # /${doh_path}/dns-query onto the /dns-query endpoint AdGuard Home
    # actually serves, so scanning the well-known path finds nothing here.
    location /${doh_path}/dns-query {
        proxy_pass http://127.0.0.1:${web_port}/dns-query;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        # The server block sets proxy_intercept_errors on with an error_page
        # map; left on, it would rewrite DoH wireformat error bodies.
        proxy_intercept_errors off;
        access_log off;
    }

    # Admin UI on a random path.  The UI uses relative URLs so a trailing-slash
    # proxy_pass works, but Location headers and the session cookie (Path=/)
    # still have to be rewritten onto the sub-path.
    location /${admin_path}/ {
        proxy_pass http://127.0.0.1:${web_port}/;
        proxy_redirect / /${admin_path}/;
        proxy_cookie_path / /${admin_path}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_intercept_errors off;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
    location = /${admin_path} { return 302 /${admin_path}/; }
EOF

if grep -q 'snippets/adguard.conf' "$vhost"; then
    blue "Include already present in ${vhost}"
else
    blue "Adding the include to ${vhost}..."
    backup="${vhost}.bak-$(date +%s)"
    cp -a "$vhost" "$backup"
    tmp="$(mktemp)"
    # Insert right after server_name: always inside the server block, whatever
    # the rest of the vhost looks like.
    awk -v inc="    include /etc/nginx/snippets/adguard.conf;" '
        !added && /^[[:space:]]*server_name[[:space:]]/ { print; print inc; added=1; next }
        { print }
    ' "$vhost" > "$tmp"
    grep -q 'snippets/adguard.conf' "$tmp" || { rm -f "$tmp"; die "No server_name found in ${vhost}"; }
    cat "$tmp" > "$vhost"; rm -f "$tmp"
    blue "Backup of the original vhost: ${backup}"
fi

blue "Testing nginx configuration..."
if nginx -t 2>&1 | grep -q successful; then
    systemctl reload nginx
    green "nginx reloaded."
else
    nginx -t
    die "nginx configuration test failed — vhost backup is at ${backup:-<none>}"
fi

# ── weekly self-update ────────────────────────────────────────────────────────
# AdGuard Home checks for updates and shows a button, but never installs one on
# its own.  This makes it unattended.
blue "Installing the weekly update timer..."
cat > /etc/systemd/system/agh-autoupdate.service <<EOF
[Unit]
Description=Update AdGuard Home in place
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${AGH_BIN} --update -c ${AGH_YAML} -w ${AGH_DIR}
EOF

cat > /etc/systemd/system/agh-autoupdate.timer <<EOF
[Unit]
Description=Weekly AdGuard Home update

[Timer]
OnCalendar=Sun 04:30
RandomizedDelaySec=2h
Persistent=true
Unit=agh-autoupdate.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now agh-autoupdate.timer >/dev/null 2>&1

# ── verification ──────────────────────────────────────────────────────────────
# RFC 8484 GET for www.example.com A.
DNS_Q='dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB'
blue "Verifying the public DoH endpoint..."
doh_status="$(curl -so /dev/null -w '%{http_code}' --max-time 10 \
    -H 'accept: application/dns-message' \
    "https://${domain}/${doh_path}/dns-query?${DNS_Q}" || true)"
blue "Verifying the standard path is NOT exposed..."
leak_status="$(curl -so /dev/null -w '%{http_code}' --max-time 10 \
    -H 'accept: application/dns-message' \
    "https://${domain}/dns-query?${DNS_Q}" || true)"

echo
green "══════════════════════════════════════════════════════════"
green " AdGuard Home installed"
green "══════════════════════════════════════════════════════════"
printf "\n  DNS-over-HTTPS URL for clients:\n"
printf "    https://%s/%s/dns-query\n" "$domain" "$doh_path"
printf "\n  Admin UI:  https://%s/%s/\n" "$domain" "$admin_path"
if [[ $new_credentials -eq 1 ]]; then
    printf "  Login:     %s\n  Password:  %s\n" "$agh_user" "$agh_pass"
    echo
    red   "  Save the password now — only its bcrypt hash is stored."
else
    printf "  Login:     unchanged\n"
fi
echo
if [[ "$doh_status" == "200" ]]; then
    green "  DoH endpoint:        HTTP 200 — working"
else
    red   "  DoH endpoint:        HTTP ${doh_status} (expected 200)"
fi
if [[ "$leak_status" == "200" ]]; then
    red   "  Standard /dns-query: HTTP 200 — UNEXPECTED, it should not answer"
else
    green "  Standard /dns-query: HTTP ${leak_status} — not exposed, as intended"
fi
echo
green "  Nothing to maintain:"
echo   "    certificates   nginx owns them; certbot renewal needs no action"
echo   "    AdGuard Home   agh-autoupdate.timer, weekly"
echo   "    3x-ui panel    panel updates do not touch nginx"
echo
echo   "  systemctl list-timers agh-autoupdate.timer"
echo
