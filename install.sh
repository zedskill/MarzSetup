#!/bin/bash
set -e

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash install.sh"; exit 1; }

# === Config ===
DASH_PORT=3169
XRAY_PORT=8080
ADMIN_USER=adm$(openssl rand -hex 4)
ADMIN_PASS=$(openssl rand -hex 12)
HOST_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 icanhazip.com || hostname -I | awk '{print $1}')
CRED_FILE="/root/marzban-credentials.txt"

[ -z "$HOST_IP" ] && { echo "Could not detect server IP."; exit 1; }

echo "Installing on $HOST_IP ..."

# 1. Docker
if ! docker --version &>/dev/null; then
    echo "[1/6] Installing Docker ..."
    curl -fsSL https://get.docker.com | sh
    systemctl start docker && systemctl enable docker
else
    echo "[1/6] Docker OK"
fi

# 2. Marzban
echo "[2/6] Installing Marzban ..."
mkdir -p /opt/marzban /var/lib/marzban

cat > /var/lib/marzban/xray_config.json << 'XEOF'
{
  "log": {"loglevel": "info"},
  "api": {
    "tag": "api",
    "services": ["HandlerService", "LoggerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
    "system": {
      "statsInboundUplink": true, "statsInboundDownlink": true,
      "statsOutboundUplink": true, "statsOutboundDownlink": true
    }
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{"inboundTag": ["api"], "outboundTag": "api", "type": "field"}]
  },
  "inbounds": [
    {"tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}}
  ],
  "outbounds": [
    {"tag": "api", "protocol": "freedom"},
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
XEOF

cat > /opt/marzban/.env << ENVEOF
UVICORN_HOST=127.0.0.1
UVICORN_PORT=${XRAY_PORT}
UVICORN_SSL_CERTFILE=
UVICORN_SSL_KEYFILE=
DASHBOARD_PATH=/dashboard/
SUDO_USERNAME=${ADMIN_USER}
SUDO_PASSWORD=${ADMIN_PASS}
MARZBAN_ADMIN_USERNAME=${ADMIN_USER}
MARZBAN_ADMIN_PASSWORD=${ADMIN_PASS}
ENVEOF

cat > /opt/marzban/docker-compose.yml << YMLEOF
services:
  marzban:
    image: gozargah/marzban:latest
    container_name: marzban-marzban-1
    restart: always
    network_mode: host
    env_file:
      - .env
    volumes:
      - /var/lib/marzban:/var/lib/marzban
      - /opt/marzban:/opt/marzban
YMLEOF

cd /opt/marzban
docker compose down >/dev/null 2>&1 || true
sleep 2
docker compose up -d

# Wait for panel
echo "[3/6] Waiting for panel ..."
for i in $(seq 1 30); do
    sleep 3
    CODE=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${XRAY_PORT}/" 2>/dev/null) || CODE=000
    [ "$CODE" = "200" ] || [ "$CODE" = "307" ] || [ "$CODE" = "404" ] && break
done

# 4. Create admin (no TTY prompts)
echo "[4/6] Creating admin ..."
docker exec -e MARZBAN_ADMIN_PASSWORD="$ADMIN_PASS" marzban-marzban-1 \
    marzban-cli admin create -u "$ADMIN_USER" --sudo --telegram-id 0 --discord-webhook "" \
    >/dev/null 2>&1 || true
sleep 2

token_req() {
    curl -s -X POST "http://127.0.0.1:${XRAY_PORT}/api/admin/token" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "username=${ADMIN_USER}&password=${ADMIN_PASS}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true
}

TOKEN=$(token_req)
if [ -z "$TOKEN" ]; then
    echo "Retrying token in 5s..."
    sleep 5
    TOKEN=$(token_req)
fi

[ -n "$TOKEN" ] || { echo "Failed to get admin token."; exit 1; }

# 5. Nginx
echo "[5/6] Setting up Nginx ..."
which nginx &>/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null 2>&1; }
systemctl enable nginx
systemctl start nginx 2>/dev/null || systemctl restart nginx

cat > /etc/nginx/sites-available/marzban << NGEOF
server {
    listen ${DASH_PORT} default_server;
    listen [::]:${DASH_PORT} default_server;

    location /statics/ {
        proxy_pass http://127.0.0.1:${XRAY_PORT}/statics/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location /sub/ {
        proxy_pass http://127.0.0.1:${XRAY_PORT}/sub/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }

    location /dashboard/ {
        proxy_pass http://127.0.0.1:${XRAY_PORT}/dashboard/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }

    location /dashboard {
        return 301 /dashboard/;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:${XRAY_PORT}/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_redirect off;
    }
}
NGEOF

ln -sf /etc/nginx/sites-available/marzban /etc/nginx/sites-enabled/marzban
rm -f /etc/nginx/sites-enabled/default
nginx -t 2>/dev/null && systemctl restart nginx

# 6. Inbounds — 4 protocols (API inbound required)
echo "[6/6] Creating inbounds ..."
cat > /tmp/xray_cfg.json << 'INEOF'
{
  "log": {"loglevel": "info"},
  "api": {
    "tag": "api",
    "services": ["HandlerService", "LoggerService", "StatsService"]
  },
  "stats": {},
  "policy": {
    "levels": {"0": {"statsUserUplink": true, "statsUserDownlink": true}},
    "system": {
      "statsInboundUplink": true, "statsInboundDownlink": true,
      "statsOutboundUplink": true, "statsOutboundDownlink": true
    }
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{"inboundTag": ["api"], "outboundTag": "api", "type": "field"}]
  },
  "inbounds": [
    {"tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"}},
    {"tag": "vless-tcp", "listen": "0.0.0.0", "port": 5000, "protocol": "vless", "settings": {"clients": [], "decryption": "none", "fallbacks": []}, "streamSettings": {"network": "tcp", "security": "none", "tcpSettings": {"header": {"type": "none"}}}},
    {"tag": "vmess-tcp", "listen": "0.0.0.0", "port": 5001, "protocol": "vmess", "settings": {"clients": [], "disableFallback": false, "fallbacks": []}, "streamSettings": {"network": "tcp", "security": "none", "tcpSettings": {"header": {"type": "none"}}}},
    {"tag": "trojan-tcp", "listen": "0.0.0.0", "port": 5002, "protocol": "trojan", "settings": {"clients": [], "fallbacks": []}, "streamSettings": {"network": "tcp", "security": "none", "tcpSettings": {"header": {"type": "none"}}}},
    {"tag": "shadowsocks-tcp", "listen": "0.0.0.0", "port": 5003, "protocol": "shadowsocks", "settings": {"method": "chacha20-ietf-poly1305", "network": "tcp,udp", "clients": []}, "streamSettings": {"network": "tcp", "security": "none", "tcpSettings": {"header": {"type": "none"}}}}
  ],
  "outbounds": [
    {"tag": "api", "protocol": "freedom"},
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}
  ]
}
INEOF

PUT=$(curl -s -o /tmp/xray_put.out -w '%{http_code}' -X PUT "http://127.0.0.1:${XRAY_PORT}/api/core/config" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${TOKEN}" \
    -d @/tmp/xray_cfg.json)
echo "core config HTTP $PUT"
[ "$PUT" = "200" ] || cat /tmp/xray_put.out
rm -f /tmp/xray_cfg.json /tmp/xray_put.out

# 7. Firewall
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
for P in 5000 5001 5002 5003 "$DASH_PORT"; do
    iptables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$P" -j ACCEPT
done
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

# 8. Save credentials to file
PANEL_URL="http://${HOST_IP}:${DASH_PORT}/dashboard/"
cat > "$CRED_FILE" << CREOF
Marzban Panel Credentials
========================
Panel URL  : ${PANEL_URL}
Username   : ${ADMIN_USER}
Password   : ${ADMIN_PASS}

Protocols
---------
VLESS       : ${HOST_IP}:5000
VMess       : ${HOST_IP}:5001
Trojan      : ${HOST_IP}:5002
Shadowsocks : ${HOST_IP}:5003
CREOF

chmod 600 "$CRED_FILE"

echo ""
echo "============================="
echo "Panel: ${PANEL_URL}"
echo "Username: ${ADMIN_USER}"
echo "Password: ${ADMIN_PASS}"
echo "Credentials saved to: ${CRED_FILE}"
echo ""
echo "VLESS: ${HOST_IP}:5000"
echo "VMess: ${HOST_IP}:5001"
echo "Trojan: ${HOST_IP}:5002"
echo "Shadowsocks: ${HOST_IP}:5003"
echo "============================="
