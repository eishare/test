#!/bin/sh
set -e

BASE=/etc/sing-box
mkdir -p "$BASE"
cd "$BASE"

UUID=$(cat /proc/sys/kernel/random/uuid)
PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
WS_PORT=3000
TUIC_PORT=$(shuf -i20000-45000 -n1)

################################
# 依赖
################################
if [ -f /etc/alpine-release ]; then
  apk add --no-cache curl ca-certificates openssl
else
  apt update -y
  apt install -y curl ca-certificates openssl
fi

################################
# 架构
################################
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported arch"; exit 1 ;;
esac

################################
# sing-box
################################
if [ ! -x "$BASE/sing-box" ]; then
  curl -L -o sb.tgz \
    https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-$ARCH.tar.gz
  tar -xzf sb.tgz
  mv sing-box-*/sing-box sing-box
  chmod +x sing-box
fi

################################
# cloudflared
################################
if [ ! -x "$BASE/cloudflared" ]; then
  curl -L -o cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
  chmod +x cloudflared
fi

################################
# 证书（TUIC）
################################
openssl ecparam -genkey -name prime256v1 -out key.pem
openssl req -new -x509 -days 3650 \
  -key key.pem -out cert.pem \
  -subj "/CN=www.bing.com"

################################
# sing-box config（printf，避免 EOF）
################################
printf '{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": %s,
      "users": [{ "uuid": "%s" }],
      "transport": { "type": "ws", "path": "/ws" }
    },
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": %s,
      "users": [{
        "uuid": "%s",
        "password": "%s"
      }],
      "tls": {
        "enabled": true,
        "certificate_path": "cert.pem",
        "key_path": "key.pem",
        "alpn": ["h3"]
      },
      "congestion_control": "bbr"
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
' "$WS_PORT" "$UUID" "$TUIC_PORT" "$UUID" "$PASS" > config.json

################################
# 启动 sing-box
################################
pkill sing-box 2>/dev/null || true
nohup "$BASE/sing-box" run -c "$BASE/config.json" >/dev/null 2>&1 &

sleep 1

################################
# 启动 Argo（VLESS WS）
################################
pkill cloudflared 2>/dev/null || true
nohup "$BASE/cloudflared" tunnel \
  --url http://127.0.0.1:$WS_PORT \
  --no-autoupdate \
  --logfile "$BASE/argo.log" >/dev/null 2>&1 &

################################
# 获取 Argo 域名
################################
DOMAIN=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  DOMAIN=$(strings "$BASE/argo.log" 2>/dev/null \
    | grep -oE 'https://[a-z0-9.-]+\.trycloudflare\.com' \
    | tail -n1 \
    | sed 's#https://##')
  [ -n "$DOMAIN" ] && break
  sleep 1
done

IP=$(curl -s ip.sb || echo "VPS_IP")

################################
# 输出
################################
echo
echo "========== 部署完成 =========="
echo "UUID       : $UUID"
echo "TUIC 密码 : $PASS"
echo "TUIC 端口 : $TUIC_PORT"
echo
echo "【TUIC v5】"
echo "tuic://$UUID:$PASS@$IP:$TUIC_PORT?alpn=h3&allow_insecure=1&sni=www.bing.com#TUIC"
echo
echo "【VLESS WS TLS（Argo）】"
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&path=%2Fws&host=$DOMAIN&sni=$DOMAIN&allowInsecure=1#Argo"
echo "=============================="
