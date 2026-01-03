#!/bin/sh
set -e

MODE="$*"
UUID=$(cat /proc/sys/kernel/random/uuid)
PASS=$(cat /proc/sys/kernel/random/uuid | cut -d- -f1)

BASE=/etc/sing-box
BIN=/usr/bin/sing-box
CERT_DIR=/etc/tuic-cert
WWW=/var/www/html
ARGO_LOG=/tmp/argo.log

VPS_IP=$(curl -s -4 ifconfig.me || hostname -I | awk '{print $1}')

mkdir -p "$BASE" "$CERT_DIR" "$WWW"

################################
# 依赖
################################
if [ -f /etc/alpine-release ]; then
  apk add --no-cache curl ca-certificates openssl busybox-extras
else
  apt-get update -y
  apt-get install -y curl ca-certificates openssl busybox
fi

################################
# sing-box
################################
if [ ! -x "$BIN" ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) A=amd64 ;;
    aarch64) A=arm64 ;;
    *) echo "不支持架构"; exit 1 ;;
  esac

  VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep tag_name | cut -d\" -f4)
  curl -L -o /tmp/sb.tgz \
    https://github.com/SagerNet/sing-box/releases/download/$VER/sing-box-linux-$A.tar.gz
  tar -xzf /tmp/sb.tgz -C /tmp
  mv /tmp/sing-box-*/sing-box "$BIN"
  chmod +x "$BIN"
fi

################################
# TUIC 证书（必须）
################################
if [ ! -f "$CERT_DIR/cert.pem" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$CERT_DIR/key.pem" \
    -out "$CERT_DIR/cert.pem" \
    -days 3650 \
    -subj "/CN=www.bing.com"
fi

PORT=$(shuf -i20000-60000 -n1)

################################
# sing-box 配置
################################
cat > "$BASE/config.json" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 3000,
      "users": [{ "uuid": "$UUID" }],
      "transport": { "type": "ws", "path": "/$UUID" }
    },
    {
      "type": "tuic",
      "listen": "0.0.0.0",
      "listen_port": $PORT,
      "users": [{ "uuid": "$UUID", "password": "$PASS" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "certificate_path": "$CERT_DIR/cert.pem",
        "key_path": "$CERT_DIR/key.pem",
        "alpn": ["h3"]
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

pkill sing-box 2>/dev/null || true
nohup sing-box run -c "$BASE/config.json" >/dev/null 2>&1 &

sleep 2

################################
# Argo
################################
DOMAIN=""
if echo "$MODE" | grep -q argo; then
  if [ ! -x /usr/bin/cloudflared ]; then
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64) A=amd64 ;;
      aarch64) A=arm64 ;;
    esac
    curl -L -o /usr/bin/cloudflared \
      https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$A
    chmod +x /usr/bin/cloudflared
  fi

  pkill cloudflared 2>/dev/null || true
  cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate >"$ARGO_LOG" 2>&1 &

  echo "等待 Argo 域名生成..."
  for i in $(seq 1 60); do
    DOMAIN=$(grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' "$ARGO_LOG" | head -n1 | sed 's#https://##')
    [ -n "$DOMAIN" ] && break
    sleep 1
  done

  [ -n "$DOMAIN" ] && echo "$DOMAIN" > "$WWW/$UUID"
fi

busybox httpd -p 127.0.0.1:8080 -h "$WWW" >/dev/null 2>&1 &

################################
# 输出
################################
echo
echo "=========== 部署完成 ==========="
echo "UUID      : $UUID"
echo "Password  : $PASS"
echo "TUIC Port : $PORT"
[ -n "$DOMAIN" ] && echo "Argo 域名 : $DOMAIN"
echo

echo "=== TUIC v5（可直连）==="
echo "tuic://$UUID:$PASS@$VPS_IP:$PORT?alpn=h3&congestion_control=bbr&allow_insecure=1&sni=www.bing.com#TUIC-OK"
echo

if [ -n "$DOMAIN" ]; then
  echo "=== Argo VLESS WS ==="
  echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&path=/$UUID&host=www.bing.com&sni=$DOMAIN&allowInsecure=1#Argo-OK"
fi

echo
echo "查询接口: http://127.0.0.1:8080/$UUID"
echo "================================"
