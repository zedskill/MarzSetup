#!/bin/bash
set -e

[[ $EUID -ne 0 ]] && { echo "Run as root: sudo bash install.sh"; exit 1; }

DASH_PORT=3169
XRAY_PORT=8080
ADMIN_USER=adm$(openssl rand -hex 4)
ADMIN_PASS=$(openssl rand -hex 12)
HOST_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 icanhazip.com || hostname -I | awk '{print $1}')
CRED_FILE="/root/marzban-credentials.txt"

[ -z "$HOST_IP" ] && { echo "Could not detect server IP."; exit 1; }
echo "Installing on $HOST_IP ..."

if ! docker --version &>/dev/null; then
    echo "[1/6] Installing Docker ..."
    curl -fsSL https://get.docker.com | sh
    systemctl start docker && systemctl enable docker
else
    echo "[1/6] Docker OK"
fi

echo "[2/6] Installing Marzban ..."
mkdir -p /opt/marzban /var/lib/marzban

cat > /var/lib/marzban/xray_config.json << 'XEOF'
{"log":{"loglevel":"warning"},"api":{"tag":"api","services":["HandlerService","LoggerService","StatsService"]},"stats":{},"inbounds":[{"tag":"api","listen":"127.0.0.1","port":62789,"protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}}],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],"routing":{"rules":[{"inboundTag":["api"],"outboundTag":"api","type":"field"}]}}
XEOF

cat > /opt/marzban/.env << ENVEOF
UVICORN_HOST=127.0.0.1
UVICORN_PORT=${XRAY_PORT}
DASHBOARD_PATH=/dashboard/
SUDO_USERNAME=${ADMIN_USER}
SUDO_PASSWORD=${ADMIN_PASS}
MARZBAN_ADMIN_USERNAME=${ADMIN_USER}
MARZBAN_ADMIN_PASSWORD=${ADMIN_PASS}
ENVEOF

cat > /opt/marzban/docker-compose.yml << 'YMLEOF'
services:
  marzban:
    image: gozargah/marzban:latest
    container_name: marzban-marzban-1
    restart: always
    network_mode: host
    env_file: .env
    volumes:
      - /var/lib/marzban:/var/lib/marzban
      - /opt/marzban:/opt/marzban
YMLEOF

cd /opt/marzban
docker compose down >/dev/null 2>&1 || true
sleep 2
docker compose up -d

echo "[3/6] Waiting for panel ..."
for i in $(seq 1 30); do
    sleep 3
    CODE=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${XRAY_PORT}/" 2>/dev/null) || CODE=000
    [ "$CODE" = "200" ] || [ "$CODE" = "307" ] || [ "$CODE" = "404" ] && break
done

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
[ -z "$TOKEN" ] && sleep 5 && TOKEN=$(token_req)
[ -n "$TOKEN" ] || { echo "Failed to get admin token."; exit 1; }

echo "[5/6] Setting up Nginx ..."
which nginx &>/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null 2>&1; }
systemctl enable nginx
systemctl start nginx 2>/dev/null || systemctl restart nginx
cat > /etc/nginx/sites-available/marzban << NGEOF
server {
    listen ${DASH_PORT} default_server;
    listen [::]:${DASH_PORT} default_server;
    location /statics/ { proxy_pass http://127.0.0.1:${XRAY_PORT}/statics/; proxy_http_version 1.1; proxy_set_header Host \$host; }
    location /sub/ { proxy_pass http://127.0.0.1:${XRAY_PORT}/sub/; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_buffering off; }
    location /dashboard/ {
        proxy_pass http://127.0.0.1:${XRAY_PORT}/dashboard/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location /dashboard { return 301 /dashboard/; }
    location /api/ {
        proxy_pass http://127.0.0.1:${XRAY_PORT}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }
}
NGEOF
ln -sf /etc/nginx/sites-available/marzban /etc/nginx/sites-enabled/marzban
rm -f /etc/nginx/sites-enabled/default
nginx -t 2>/dev/null && systemctl restart nginx

echo "[6/6] Creating inbounds (all Marzban variants) ..."
RAW=$(docker exec marzban-marzban-1 xray x25519)
PRIV=$(printf '%s\n' "$RAW" | awk -F': ' 'BEGIN{IGNORECASE=1} /Private key/{print $2}')
PUB=$(printf '%s\n' "$RAW" | awk -F': ' 'BEGIN{IGNORECASE=1} /Public key/{print $2}')
SID=$(openssl rand -hex 8)

python3 - "$PRIV" "$PUB" "$SID" << 'PY'
import json, sys
pk, pub, sid = sys.argv[1:4]
sniff = {"enabled": True, "destOverride": ["http", "tls", "quic"]}
real = {
    "show": False, "dest": "www.cloudflare.com:443", "xver": 0,
    "serverNames": ["www.cloudflare.com", "www.microsoft.com"],
    "privateKey": pk, "publicKey": pub, "shortIds": [sid, ""], "spiderX": "/",
}

def st(net, sec="none", path=None, svc=None):
    ss = {"network": net, "security": sec}
    if net == "tcp" and sec == "none":
        ss["tcpSettings"] = {"header": {"type": "none"}}
    elif net == "tcp" and sec == "reality":
        ss = {"network": "tcp", "tcpSettings": {}, "security": "reality", "realitySettings": real}
    elif net == "ws":
        ss["wsSettings"] = {"path": path or "/ws"}
    elif net == "grpc":
        ss["grpcSettings"] = {"serviceName": svc or "grpc"}
        if sec == "reality":
            ss["realitySettings"] = real
    elif net == "xhttp":
        ss["xhttpSettings"] = {"path": path or "/xhttp", "mode": "auto"}
        if sec == "reality":
            ss["realitySettings"] = real
    elif net == "httpupgrade":
        ss["httpupgradeSettings"] = {"path": path or "/hu", "host": ""}
    return ss

def vless(tag, port, net, sec="none", **kw):
    return {"tag": tag, "listen": "0.0.0.0", "port": port, "protocol": "vless",
            "settings": {"clients": [], "decryption": "none", "fallbacks": []},
            "streamSettings": st(net, sec, **kw), "sniffing": sniff}

def vmess(tag, port, net, **kw):
    return {"tag": tag, "listen": "0.0.0.0", "port": port, "protocol": "vmess",
            "settings": {"clients": []}, "streamSettings": st(net, **kw), "sniffing": sniff}

def trojan(tag, port, net, **kw):
    return {"tag": tag, "listen": "0.0.0.0", "port": port, "protocol": "trojan",
            "settings": {"clients": []}, "streamSettings": st(net, **kw), "sniffing": sniff}

cfg = {
    "log": {"loglevel": "warning"},
    "api": {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]},
    "stats": {},
    "policy": {"levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
               "system": {"statsInboundUplink": True, "statsInboundDownlink": True,
                          "statsOutboundUplink": True, "statsOutboundDownlink": True}},
    "routing": {"domainStrategy": "IPIfNonMatch",
                "rules": [{"inboundTag": ["api"], "outboundTag": "api", "type": "field"}]},
    "inbounds": [
        {"tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door",
         "settings": {"address": "127.0.0.1"}},
        vless("VLESS TCP", 5000, "tcp"),
        vless("VLESS WS", 5004, "ws", path="/ws"),
        vless("VLESS gRPC", 5005, "grpc", svc="grpc"),
        vless("VLESS XHTTP", 5006, "xhttp", path="/xhttp"),
        vless("VLESS HTTPUpgrade", 5007, "httpupgrade", path="/hu"),
        vless("VLESS TCP REALITY", 443, "tcp", "reality"),
        vless("VLESS gRPC REALITY", 8443, "grpc", "reality", svc="grpc"),
        vless("VLESS XHTTP REALITY", 8444, "xhttp", "reality", path="/xhttp"),
        vmess("VMess TCP", 5001, "tcp"),
        vmess("VMess WS", 5008, "ws", path="/vmess"),
        vmess("VMess gRPC", 5009, "grpc", svc="vmess"),
        trojan("Trojan TCP", 5002, "tcp"),
        trojan("Trojan WS", 5010, "ws", path="/trojan"),
        trojan("Trojan gRPC", 5011, "grpc", svc="trojan"),
        {"tag": "Shadowsocks TCP", "listen": "0.0.0.0", "port": 5003, "protocol": "shadowsocks",
         "settings": {"method": "chacha20-ietf-poly1305", "network": "tcp,udp", "clients": []},
         "sniffing": sniff},
    ],
    "outbounds": [
        {"tag": "api", "protocol": "freedom"},
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
    ],
}
open("/tmp/xray_cfg.json", "w").write(json.dumps(cfg))
print("inbounds", len(cfg["inbounds"]) - 1)
PY

PUT=$(curl -s -o /tmp/xray_put.out -w '%{http_code}' -X PUT "http://127.0.0.1:${XRAY_PORT}/api/core/config" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer ${TOKEN}" -d @/tmp/xray_cfg.json)
echo "core config HTTP $PUT"
[ "$PUT" = "200" ] || cat /tmp/xray_put.out
cp /tmp/xray_cfg.json /var/lib/marzban/xray_config.json
rm -f /tmp/xray_cfg.json /tmp/xray_put.out

PATH=/usr/sbin:/sbin:$PATH
for P in 443 3169 5000 5001 5002 5003 5004 5005 5006 5007 5008 5009 5010 5011 8443 8444; do
    iptables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$P" -j ACCEPT
done
iptables -C INPUT -p udp --dport 5003 -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport 5003 -j ACCEPT
netfilter-persistent save 2>/dev/null || true

PANEL_URL="http://${HOST_IP}:${DASH_PORT}/dashboard/"
cat > "$CRED_FILE" << CREOF
Marzban Panel Credentials
========================
Panel URL  : ${PANEL_URL}
Username   : ${ADMIN_USER}
Password   : ${ADMIN_PASS}

Reality
-------
publicKey  : ${PUB}
shortId    : ${SID}
dest/SNI   : www.cloudflare.com

Protocols
---------
VLESS TCP            ${HOST_IP}:5000
VLESS WS             ${HOST_IP}:5004  path=/ws
VLESS gRPC           ${HOST_IP}:5005  svc=grpc
VLESS XHTTP          ${HOST_IP}:5006  path=/xhttp
VLESS HTTPUpgrade    ${HOST_IP}:5007  path=/hu
VLESS TCP REALITY    ${HOST_IP}:443
VLESS gRPC REALITY   ${HOST_IP}:8443
VLESS XHTTP REALITY  ${HOST_IP}:8444
VMess TCP            ${HOST_IP}:5001
VMess WS             ${HOST_IP}:5008
VMess gRPC           ${HOST_IP}:5009
Trojan TCP           ${HOST_IP}:5002
Trojan WS            ${HOST_IP}:5010
Trojan gRPC          ${HOST_IP}:5011
Shadowsocks          ${HOST_IP}:5003
CREOF
chmod 600 "$CRED_FILE"

echo ""
echo "============================="
echo "Panel: ${PANEL_URL}"
echo "Username: ${ADMIN_USER}"
echo "Password: ${ADMIN_PASS}"
echo "Credentials: ${CRED_FILE}"
echo "VLESS REALITY :443  gRPC :8443  XHTTP :8444"
echo "============================="
