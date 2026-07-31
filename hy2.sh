#!/bin/bash
set -e
#################### Hysteria2 on top of x-ui + Reality + Nextcloud ####################
# Assumes x-ui-pro is already installed (nginx stream with SNI routing on 443/tcp)
# along with Nextcloud from snap. Hysteria takes 443/udp and masquerades
# as the local Nextcloud instance.

NGINX_STREAM="/etc/nginx/stream-enabled/stream.conf"
NGINX_80="/etc/nginx/sites-available/80.conf"
HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"

msg() { echo -e "\e[1;34m>>> $1\e[0m"; }
err() { echo -e "\e[1;41m $1 \e[0m"; }

[[ $EUID -ne 0 ]] && err "Run as root!" && exit 1

#################### Environment checks ####################
msg "Checking environment..."

for f in "$NGINX_STREAM" "$NGINX_80"; do
    [[ -f "$f" ]] || { err "$f not found - is x-ui-pro installed?"; exit 1; }
done

systemctl is-active --quiet nginx || { err "nginx is not running."; exit 1; }

WWW_PORT=$(grep -oP 'upstream\s+www\s*\{\s*server\s+127\.0\.0\.1:\K[0-9]+' "$NGINX_STREAM" || true)
[[ -z "$WWW_PORT" ]] && { err "Could not parse the www upstream in $NGINX_STREAM."; exit 1; }

NC_PORT=$(snap get nextcloud ports.http 2>/dev/null || true)
[[ -z "$NC_PORT" ]] && { err "Could not read the Nextcloud port from snap."; exit 1; }

MASQ_URL="http://127.0.0.1:${NC_PORT}"
echo "    nginx www upstream: 127.0.0.1:${WWW_PORT}"
echo "    Nextcloud:          ${MASQ_URL}"

#################### Domain input ####################
echo
read -rp "Domain for Hysteria2 (e.g. cdn.example.com): " DOMAIN
DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')
[[ -z "$DOMAIN" ]] && err "No domain provided." && exit 1

echo
echo "    Domain:      $DOMAIN"
echo "    Masquerade:  $MASQ_URL (rewriteHost: false)"
echo
read -rp "Is this correct? Continue? [y/N]: " CONFIRM
[[ ! "$CONFIRM" =~ ^[yY]$ ]] && echo "Cancelled." && exit 0
echo

#################### Preflight checks ####################
msg "Checking that 443/UDP is free..."
if ss -ulnp | grep -q ':443 '; then
    err "Port 443/UDP is already in use:"
    ss -ulnp | grep ':443 '
    exit 1
fi

msg "Checking DNS..."
SERVER_IP=$(curl -4 -s ifconfig.me)
DOMAIN_IP=$(dig +short "$DOMAIN" | tail -n1)
echo "    Server IP: $SERVER_IP"
echo "    Domain IP: $DOMAIN_IP"
[[ "$SERVER_IP" != "$DOMAIN_IP" ]] && err "Domain does not point to this server." && exit 1

msg "Checking Nextcloud..."
CODE=$(curl -s -o /dev/null --max-time 8 -w '%{http_code}' "$MASQ_URL" 2>/dev/null || echo "000")
[[ "$CODE" == "000" ]] && err "$MASQ_URL is not responding. Try: snap services nextcloud" && exit 1
echo "    OK (HTTP $CODE)"

#################### Install ####################
msg "Installing Hysteria2..."
bash <(curl -fsSL https://get.hy2.sh/)

PASSWORD=$(openssl rand -base64 16)

#################### Certificate via the nginx plugin ####################
msg "Adding the domain to 80.conf..."
grep -q "$DOMAIN" "$NGINX_80" || sed -i "/server_name/ s/;\$/ ${DOMAIN};/" "$NGINX_80"
nginx -t && systemctl reload nginx

msg "Issuing certificate..."
certbot certonly --nginx --non-interactive --agree-tos \
    --register-unsafely-without-email -d "$DOMAIN"

[[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]] || { err "Certificate was not issued."; exit 1; }

msg "Copying certificates for the hysteria user..."
mkdir -p /etc/hysteria/certs
cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" /etc/hysteria/certs/
cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem"   /etc/hysteria/certs/
chmod 644 /etc/hysteria/certs/fullchain.pem
chmod 600 /etc/hysteria/certs/privkey.pem
chown hysteria:hysteria /etc/hysteria/certs/*.pem

#################### Config ####################
msg "Writing server config..."
cat > /etc/hysteria/config.yaml <<EOF
listen: :443

tls:
  cert: /etc/hysteria/certs/fullchain.pem
  key: /etc/hysteria/certs/privkey.pem

auth:
  type: password
  password: "$PASSWORD"

masquerade:
  type: proxy
  proxy:
    url: $MASQ_URL
    rewriteHost: false
EOF

#################### Deploy hook ####################
msg "Installing certbot deploy hook..."
sed -i '/renew_hook/d' "/etc/letsencrypt/renewal/$DOMAIN.conf" 2>/dev/null || true

mkdir -p "$HOOK_DIR"
cat > "$HOOK_DIR/hysteria-${DOMAIN}.sh" <<EOF
#!/bin/bash
[[ "\$RENEWED_LINEAGE" != "/etc/letsencrypt/live/$DOMAIN" ]] && exit 0
cp "\$RENEWED_LINEAGE/fullchain.pem" /etc/hysteria/certs/
cp "\$RENEWED_LINEAGE/privkey.pem"   /etc/hysteria/certs/
chmod 644 /etc/hysteria/certs/fullchain.pem
chmod 600 /etc/hysteria/certs/privkey.pem
chown hysteria:hysteria /etc/hysteria/certs/*.pem
systemctl restart hysteria-server
EOF
chmod +x "$HOOK_DIR/hysteria-${DOMAIN}.sh"

#################### TCP/443: SNI map + server block ####################
msg "Configuring TCP/443 for the domain..."

grep -q "$DOMAIN" "$NGINX_STREAM" || \
    sed -i "/^\s*default\s\+xray;/i\\    ${DOMAIN}      www;" "$NGINX_STREAM"

if [[ ! -f "/etc/nginx/sites-available/$DOMAIN" ]]; then
    cat > "/etc/nginx/sites-available/$DOMAIN" <<EOF
server {
    server_tokens off;
    server_name ${DOMAIN};
    listen ${WWW_PORT} ssl proxy_protocol;
    listen [::]:${WWW_PORT} ssl proxy_protocol;
    http2 on;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass ${MASQ_URL};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 10G;
        proxy_read_timeout 3600;
    }
}
EOF
    ln -sf "/etc/nginx/sites-available/$DOMAIN" /etc/nginx/sites-enabled/
fi

if nginx -t 2>/dev/null; then
    systemctl reload nginx
else
    err "nginx -t failed, rolling back the domain block."
    rm -f "/etc/nginx/sites-enabled/$DOMAIN"
    nginx -t && systemctl reload nginx
fi

#################### Start ####################
msg "Opening 443/udp..."
ufw allow 443/udp 2>/dev/null || true

msg "Starting service..."
systemctl enable --now hysteria-server.service
systemctl restart hysteria-server.service
sleep 2

#################### Summary ####################
echo
echo "====================================================================="
if systemctl is-active --quiet hysteria-server.service; then
    echo "  Hysteria2 is running on $DOMAIN:443 (UDP)"
else
    err "Service failed to start: journalctl -u hysteria-server -n 30"
fi

SUBJ=$(echo | openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null \
       | openssl x509 -noout -subject 2>/dev/null || echo "no response")
echo "  TCP/443 serves: $SUBJ"
echo "  (expected CN=$DOMAIN)"
echo "====================================================================="
echo
echo "Client block for Mihomo/Clash.Meta:"
echo
cat <<EOF
  - name: LV-hy2
    type: hysteria2
    server: $DOMAIN
    port: 443
    password: "$PASSWORD"
    sni: $DOMAIN
    skip-cert-verify: false
    udp: true
EOF
echo
echo "Password (save this!): $PASSWORD"
echo "====================================================================="
