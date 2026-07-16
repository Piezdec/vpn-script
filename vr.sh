#!/bin/bash
#################### x-ui-pro lite + Nextcloud Snap (VLESS Reality only) #################################
[[ $EUID -ne 0 ]] && echo "not root!" && sudo su -

##############################INFO######################################################################
msg_ok()  { echo -e "\e[1;42m $1 \e[0m";}
msg_err() { echo -e "\e[1;41m $1 \e[0m";}
msg_inf() { echo -e "\e[1;34m$1\e[0m";}

echo
msg_inf '           ___    _   _   _  '
msg_inf ' \/ __ | |  | __ |_) |_) / \ '
msg_inf ' /\    |_| _|_   |   | \ \_/ '
msg_inf '          + Nextcloud         '
echo

##################################Variables#############################################################
XUIDB="/etc/x-ui/x-ui.db"
domain=""
reality_domain=""
UNINSTALL="x"
AUTODOMAIN="n"
NC_PORT=8181
Pak=$(type apt &>/dev/null && echo "apt" || echo "yum")

# Clean previous installation
systemctl stop x-ui 2>/dev/null
rm -rf /etc/systemd/system/x-ui.service
rm -rf /usr/local/x-ui
rm -rf /etc/x-ui
rm -rf /etc/nginx/sites-enabled/*
rm -rf /etc/nginx/sites-available/*
rm -rf /etc/nginx/stream-enabled/*

##################################Helper functions######################################################
get_port() {
    echo $(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
}

gen_random_string() {
    local length="$1"
    head -c 4096 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
    echo
}

check_free() {
    nc -z 127.0.0.1 "$1" &>/dev/null
    return $?
}

make_port() {
    while true; do
        PORT=$(get_port)
        if ! check_free $PORT; then
            echo $PORT
            break
        fi
    done
}

resolve_to_ip() {
    local host="$1"
    local a
    a=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -n "$a" ]] && [[ "$a" == "$IP4" ]]
}

##################################Generate ports & paths################################################
panel_port=$(make_port)
panel_path=$(gen_random_string 10)
config_username=$(gen_random_string 10)
config_password=$(gen_random_string 10)

################################Get arguments###########################################################
while [ "$#" -gt 0 ]; do
  case "$1" in
    -auto_domain)    AUTODOMAIN="$2"; shift 2;;
    -subdomain)      domain="$2"; shift 2;;
    -reality_domain) reality_domain="$2"; shift 2;;
    -uninstall)      UNINSTALL="$2"; shift 2;;
    *) shift 1;;
  esac
done

##############################Uninstall#################################################################
if [[ ${UNINSTALL} == *"y"* ]]; then
    printf 'y\n' | x-ui uninstall 2>/dev/null
    rm -rf "/etc/x-ui/" "/usr/local/x-ui/" "/usr/bin/x-ui/"
    $Pak -y remove nginx nginx-common nginx-core nginx-full python3-certbot-nginx
    $Pak -y purge  nginx nginx-common nginx-core nginx-full python3-certbot-nginx
    $Pak -y autoremove
    $Pak -y autoclean
    rm -rf "/var/www/html/" "/etc/nginx/" "/usr/share/nginx/" "/root/cert/"
    snap remove nextcloud 2>/dev/null
    clear && msg_ok "Completely Uninstalled!" && exit 1
fi

##################################Get server IPv4#######################################################
IP4_REGEX="^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
IP4=$(ip route get 8.8.8.8 2>&1 | grep -Po -- 'src \K\S*')
[[ $IP4 =~ $IP4_REGEX ]] || IP4=$(curl -s ipv4.icanhazip.com | tr -d '[:space:]')

if [[ ${AUTODOMAIN} == *"y"* ]]; then
    domain="${IP4}.cdn-one.org"
    reality_domain="${IP4//./-}.cdn-one.org"
fi

##############################Domain prompts############################################################
while [[ -z "$domain" ]]; do
    echo -en "Enter subdomain for PANEL (e.g. storage.s3cloud.cc): " && read domain
done
domain=$(echo "$domain" | tr -d '[:space:]')

while [[ -z "$reality_domain" ]]; do
    echo -en "Enter subdomain for REALITY / Nextcloud (e.g. s3cloud.cc): " && read reality_domain
done
reality_domain=$(echo "$reality_domain" | tr -d '[:space:]')

###############################Install packages#########################################################
ufw disable 2>/dev/null

version=$(grep -oP '(?<=VERSION_ID=")[0-9]+' /etc/os-release)
if [[ "$version" == "20" || "$version" == "22" || "$version" == "24" ]]; then
    msg_inf "Версия системы: Ubuntu $version"
fi

$Pak -y update
$Pak -y install curl wget jq bash sudo nginx-full certbot python3-certbot-nginx sqlite3 ufw snapd

systemctl daemon-reload && systemctl enable --now nginx
systemctl stop nginx
fuser -k 80/tcp 80/udp 443/tcp 443/udp 2>/dev/null

##############################AUTODOMAIN DNS check######################################################
if [[ ${AUTODOMAIN} == *"y"* ]]; then
    if ! resolve_to_ip "$domain"; then
        msg_err "Auto-domain $domain does not resolve to this server IP ($IP4). Fix DNS and retry."
        exit 1
    fi
    if ! resolve_to_ip "$reality_domain"; then
        msg_err "Auto-domain $reality_domain does not resolve to this server IP ($IP4). Fix DNS and retry."
        exit 1
    fi
fi

##############################Issue SSL certificates####################################################
certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain"
if [[ ! -d "/etc/letsencrypt/live/${domain}/" ]]; then
    systemctl start nginx >/dev/null 2>&1
    msg_err "$domain SSL could not be generated!" && exit 1
fi

certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$reality_domain"
if [[ ! -d "/etc/letsencrypt/live/${reality_domain}/" ]]; then
    systemctl start nginx >/dev/null 2>&1
    msg_err "$reality_domain SSL could not be generated!" && exit 1
fi

##############################Switch renewal to nginx plugin############################################
# Standalone был нужен только при первичном выпуске (nginx ещё не настроен).
# Переключаем renewal-конфиги на nginx-плагин, чтобы автообновление работало
# через уже запущенный nginx, без остановки веб-сервера и без конфликта на порту 80.
sed -i 's/^authenticator = standalone/authenticator = nginx/' /etc/letsencrypt/renewal/*.conf
sed -i '/^pref_challs/d' /etc/letsencrypt/renewal/*.conf

# Reload вместо restart при обновлении - без разрыва VPN-соединений
for conf in /etc/letsencrypt/renewal/*.conf; do
    if ! grep -q "^renew_hook" "$conf"; then
        echo 'renew_hook = systemctl reload nginx' >> "$conf"
    fi
done

##############################Symlinks for x-ui HTTPS panel#############################################
mkdir -p /root/cert/${domain}
chmod 755 /root/cert/*
ln -sf /etc/letsencrypt/live/${domain}/fullchain.pem /root/cert/${domain}/fullchain.pem
ln -sf /etc/letsencrypt/live/${domain}/privkey.pem   /root/cert/${domain}/privkey.pem

#################################Nginx config###########################################################
mkdir -p /etc/nginx/stream-enabled
mkdir -p /etc/nginx/snippets

cat > "/etc/nginx/stream-enabled/stream.conf" << EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}      xray;
    ${domain}              www;
    default                xray;
}

upstream xray { server 127.0.0.1:8443; }
upstream www  { server 127.0.0.1:7443; }

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen          443;
    listen         [::]:443;
    proxy_pass      \$sni_name;
    ssl_preread     on;
}
EOF

grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* || \
    echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* || \
    sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* || \
    echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf

cat > "/etc/nginx/sites-available/80.conf" << EOF
server {
    listen 80;
    server_name ${domain} ${reality_domain};
    return 301 https://\$host\$request_uri;
}
EOF

cat > "/etc/nginx/sites-available/${domain}" << EOF
server {
    server_tokens off;
    server_name ${domain};
    listen 7443 ssl http2 proxy_protocol;
    listen [::]:7443 ssl http2 proxy_protocol;
    index index.html index.htm index.nginx-debian.html;
    root /var/www/html/;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    if (\$host !~* ^(.+\.)?$(echo $domain | sed 's/\./\\./g')\$ ) { return 444; }
    if (\$scheme ~* https) { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?$(echo $domain | sed 's/\./\\./g')\$ ) { set \$safe "\${safe}0"; }
    if (\$safe = 10) { return 444; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    #X-UI Admin Panel (HTTPS upstream)
    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
        break;
    }
    location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
        break;
    }

    location / { try_files \$uri \$uri/ =404; }
}
EOF

cat > "/etc/nginx/sites-available/${reality_domain}" << EOF
server {
    server_tokens off;
    server_name ${reality_domain};
    listen 9443 ssl http2;
    listen [::]:9443 ssl http2;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/$reality_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$reality_domain/privkey.pem;

    if (\$host !~* ^(.+\.)?$(echo $reality_domain | sed 's/\./\\./g')\$ ) { return 444; }
    if (\$scheme ~* https) { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?$(echo $reality_domain | sed 's/\./\\./g')\$ ) { set \$safe "\${safe}0"; }
    if (\$safe = 10) { return 444; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location / {
        proxy_pass http://127.0.0.1:${NC_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 10G;
        proxy_read_timeout    3600;
        proxy_connect_timeout 3600;
        proxy_send_timeout    3600;
    }

    #X-UI Admin Panel (HTTPS upstream)
    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
        break;
    }
    location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
        break;
    }
}
EOF

##################################Enable nginx sites####################################################
unlink "/etc/nginx/sites-enabled/default" >/dev/null 2>&1
rm -f "/etc/nginx/sites-enabled/default" "/etc/nginx/sites-available/default"
ln -s "/etc/nginx/sites-available/${domain}"         "/etc/nginx/sites-enabled/" 2>/dev/null
ln -s "/etc/nginx/sites-available/${reality_domain}" "/etc/nginx/sites-enabled/" 2>/dev/null
ln -s "/etc/nginx/sites-available/80.conf"           "/etc/nginx/sites-enabled/" 2>/dev/null

if [[ $(nginx -t 2>&1 | grep -o 'successful') != "successful" ]]; then
    msg_err "nginx config is not ok!" && exit 1
else
    systemctl start nginx
fi

##############################Generate Reality keys#####################################################
shor=($(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) \
      $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8) $(openssl rand -hex 8))

##############################x-ui DB seeding###########################################################
UPDATE_XUIDB() {
    if [[ ! -f $XUIDB ]]; then
        msg_err "x-ui.db file not exist!" && exit 1
    fi

    x-ui stop
    output=$(/usr/local/x-ui/bin/xray-linux-amd64 x25519)
    private_key=$(echo "$output" | grep "^PrivateKey:" | awk '{print $2}')
    public_key=$(echo  "$output" | grep "^Password"   | awk '{print $3}')
    client_id=$(/usr/local/x-ui/bin/xray-linux-amd64 uuid)
    emoji_flag=$(LC_ALL=en_US.UTF-8 curl -s https://ipwho.is/ | jq -r '.flag.emoji')

    sqlite3 $XUIDB <<EOF
INSERT INTO "settings" ("key", "value") VALUES ("timeLocation", 'Europe/Moscow');
INSERT INTO "settings" ("key", "value") VALUES ("subEnable",    'false');

INSERT INTO "client_traffics" ("inbound_id","enable","email","up","down","expiry_time","total","reset")
VALUES ('1','1','first','0','0','0','0','0');

INSERT INTO "inbounds" ("user_id","up","down","total","remark","enable","expiry_time","listen","port","protocol","settings","stream_settings","tag","sniffing")
VALUES (
'1','0','0','0',
'${emoji_flag} reality','1','0','',
'8443','vless',
'{
  "clients": [
    {
      "id": "${client_id}",
      "flow": "xtls-rprx-vision",
      "email": "first",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "first",
      "reset": 0,
      "created_at": 1756726925000,
      "updated_at": 1756726925000
    }
  ],
  "decryption": "none",
  "fallbacks": []
}',
'{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [
    { "forceTls": "same", "dest": "${domain}", "port": 443, "remark": "" }
  ],
  "realitySettings": {
    "show": false,
    "xver": 0,
    "target": "127.0.0.1:9443",
    "serverNames": ["$reality_domain"],
    "privateKey": "${private_key}",
    "minClientVer": "0",
    "maxClientVer": "",
    "maxTimediff": 0,
    "shortIds": [
      "${shor[0]}","${shor[1]}","${shor[2]}","${shor[3]}",
      "${shor[4]}","${shor[5]}","${shor[6]}","${shor[7]}"
    ],
    "settings": {
      "publicKey": "${public_key}",
      "fingerprint": "firefox",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": true,
    "header": { "type": "none" }
  }
}',
'inbound-8443',
'{
  "enabled": false,
  "destOverride": ["http","tls","quic","fakedns"],
  "metadataOnly": false,
  "routeOnly": false
}'
);
EOF

    /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" -port "${panel_port}" -webBasePath "${panel_path}"
    /usr/local/x-ui/x-ui cert -webCert "/root/cert/${domain}/fullchain.pem" -webCertKey "/root/cert/${domain}/privkey.pem"
    x-ui start
}

##############################x-ui install##############################################################
arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64)              echo 'amd64' ;;
        i*86 | x86)                        echo '386' ;;
        armv8* | armv8 | arm64 | aarch64)  echo 'arm64' ;;
        armv7* | armv7 | arm)              echo 'armv7' ;;
        armv6* | armv6)                    echo 'armv6' ;;
        armv5* | armv5)                    echo 'armv5' ;;
        s390x)                             echo 's390x' ;;
        *) echo "Unsupported CPU architecture!" && exit 1 ;;
    esac
}

config_after_install() {
    /usr/local/x-ui/x-ui setting -username "asdfasdf" -password "asdfasdf" -port "2096" -webBasePath "asdfasdf"
    /usr/local/x-ui/x-ui migrate
}

install_panel() {
    apt-get update && apt-get install -y -q wget curl tar tzdata
    cd /usr/local/

    tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$tag_version" ]]; then
        tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        [[ -z "$tag_version" ]] && echo "Failed to fetch x-ui version!" && exit 1
    fi
    echo "Got x-ui latest version: ${tag_version}"

    wget -N -O /usr/local/x-ui-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/v2.9.4/x-ui-linux-$(arch).tar.gz
    [[ $? -ne 0 ]] && echo "Downloading x-ui failed!" && exit 1

    wget -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
    [[ $? -ne 0 ]] && echo "Failed to download x-ui.sh" && exit 1

    if [[ -e /usr/local/x-ui/ ]]; then
        systemctl stop x-ui
        rm -rf /usr/local/x-ui/
    fi

    tar zxvf x-ui-linux-$(arch).tar.gz
    rm -f x-ui-linux-$(arch).tar.gz
    cd x-ui
    chmod +x x-ui x-ui.sh bin/xray-linux-$(arch)
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui

    config_after_install

    if [[ -f x-ui.service.debian ]]; then
        cp -f x-ui.service.debian /etc/systemd/system/x-ui.service
    elif [[ -f x-ui.service ]]; then
        cp -f x-ui.service /etc/systemd/system/x-ui.service
    else
        cat > /etc/systemd/system/x-ui.service << 'SVCEOF'
[Unit]
Description=x-ui Service
After=network.target
Wants=network.target
[Service]
Environment="XRAY_VMESS_AEAD_FORCED=false"
Type=simple
WorkingDirectory=/usr/local/x-ui/
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=512
[Install]
WantedBy=multi-user.target
SVCEOF
    fi

    systemctl daemon-reload
    systemctl enable x-ui
    systemctl start x-ui
}

if systemctl is-active --quiet x-ui; then
    x-ui restart
else
    install_panel
    UPDATE_XUIDB
    if ! systemctl is-enabled --quiet x-ui; then
        systemctl daemon-reload && systemctl enable x-ui.service
    fi
    x-ui restart
fi

##############################BBR + sysctl##############################################################
apt-get install -yqq --no-install-recommends ca-certificates
cat >> /etc/sysctl.conf << EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=2097152
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
sysctl -p

##############################Nextcloud Snap############################################################
msg_inf "Installing Nextcloud via Snap..."
if ! snap list nextcloud &>/dev/null; then
    snap install nextcloud
fi

msg_inf "Setting Nextcloud ports..."
snap set nextcloud ports.http=${NC_PORT}
snap set nextcloud ports.https=8182

NC_PASS=$(gen_random_string 12)
msg_inf "Installing Nextcloud admin user..."
nextcloud.manual-install admin "${NC_PASS}"

msg_inf "Waiting for Nextcloud to initialize..."
for i in $(seq 1 30); do
    if nextcloud.occ status 2>/dev/null | grep -q "installed: true"; then
        msg_ok "Nextcloud is ready!"
        break
    fi
    sleep 5
done

msg_inf "Configuring Nextcloud..."
nextcloud.occ config:system:set overwriteprotocol  --value="https"
nextcloud.occ config:system:set overwritehost      --value="${reality_domain}"
nextcloud.occ config:system:set overwrite.cli.url  --value="https://${reality_domain}"
nextcloud.occ config:system:set trusted_domains 0  --value="${reality_domain}"
nextcloud.occ config:system:set trusted_domains 1  --value="127.0.0.1"
nextcloud.occ config:system:set trusted_proxies 0  --value="127.0.0.1"
snap restart nextcloud
msg_ok "Nextcloud Snap installed and configured!"

##############################Cron######################################################################
# Обновление сертификатов идёт через systemd-таймер certbot.timer (ставится с пакетом certbot).
# Не дублируем его в cron, чтобы избежать рассинхрона и конфликтов.
crontab -l 2>/dev/null | grep -v "certbot\|x-ui" | crontab -
(crontab -l 2>/dev/null; echo '@daily x-ui restart > /dev/null 2>&1 && nginx -s reload;') | crontab -

# Убеждаемся, что systemd-таймер включён
systemctl enable --now certbot.timer

##############################UFW#######################################################################
ufw disable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

##############################Final output##############################################################
if systemctl is-active --quiet x-ui; then
    clear
    printf '0\n' | x-ui | grep --color=never -i ':'
    msg_inf "====================================================================="
    msg_inf "                      SAVE THIS SCREEN!"
    msg_inf "====================================================================="
    echo
    msg_inf "X-UI Panel: https://${domain}/${panel_path}/"
    echo -e  "Username:   ${config_username}"
    echo -e  "Password:   ${config_password}"
    msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    msg_inf "Nextcloud:        https://${reality_domain}"
    msg_inf "Nextcloud admin:  admin"
    msg_inf "Nextcloud pass:   ${NC_PASS}"
    msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    msg_inf "SSL Certificates:"
    certbot certificates 2>/dev/null | grep -i 'Domains:\|Expiry Date:'
    msg_inf "- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -"
    echo
    msg_inf "====================================================================="
    msg_inf "  CHANGE SSH PORT (recommended):"
    msg_inf "====================================================================="
    echo
    msg_inf "  1. Change SSH port (replace 2222 with your preferred port):"
    msg_inf "     sed -i 's/^#\\?Port 22/Port 2222/' /etc/ssh/sshd_config"
    echo
    msg_inf "  2. Open new port in firewall BEFORE restarting SSH:"
    msg_inf "     ufw allow 2222/tcp"
    echo
    msg_inf "  3. Restart SSH:"
    msg_inf "     systemctl restart sshd"
    echo
    msg_inf "  4. Test new port (in NEW terminal, keep old one open!):"
    msg_inf "     ssh -p 2222 root@${IP4}"
    echo
    msg_inf "  5. Only after successful login, close old port:"
    msg_inf "     ufw delete allow 22/tcp"
    msg_inf "     ufw reload"
    echo
    msg_inf "====================================================================="
    msg_inf "  SAVE THIS SCREEN!!"
    msg_inf "====================================================================="
else
    nginx -t && printf '0\n' | x-ui | grep --color=never -i ':'
    msg_err "sqlite and x-ui to be checked, try on a new clean linux!"
fi
