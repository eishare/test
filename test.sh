#!/bin/sh
set -e

### ===== 基本变量 =====
UUID=$(cat /proc/sys/kernel/random/uuid)
BASE=/etc/sing-box
BIN=/usr/bin/sing-box
ARGO_LOG=/tmp/argo.log
WEB=/var/www/html

mkdir -p $BASE $WEB

### ===== 系统检测 =====
if [ -f /etc/alpine-release ]; then
  PKG="apk add --no-cache"
  WEB_SVC="lighttpd"
else
  PKG="apt-get update && apt-get install -y"
  WEB_SVC="nginx"
fi

$PKG curl ca-certificates $WEB_SVC >/dev/null 2>&1

### ===== 安装 sing-box =====
if [ ! -f "$BIN" ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) A=amd64 ;;
    aarch64) A=arm64 ;;
  esac
  curl -L -o /tmp/sb.tgz \
    https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-$A.tar.gz
  tar -xzf /tmp/sb.tgz -C /tmp
  mv /tmp/sing-box-*/sing-box $BIN
  chmod +x $BIN
fi

### ===== 安装 cloudflared =====
if [ ! -f /usr/bin/cloudflared ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) A=amd64 ;;
    aarch64) A=arm64 ;;
  esac
  curl -L -o /usr/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$A
  chmod +x /usr/bin/cloudflared
fi

### ===== 生成 TUIC 端口 =====
TUIC_PORT=$(shuf -i20000-60000 -n1)

### ===== sing-box 配置 =====
cat > $BASE/config.json <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [{ "uuid": "$UUID" }],
      "congestion_control": "bbr",
      "zero_rtt_handshake": true
    },
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 3000,
      "users": [{ "uuid": "$UUID" }],
      "transport": {
        "type": "ws",
        "path": "/$UUID"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

pkill sing-box || true
nohup sing-box run -c $BASE/config.json >/dev/null 2>&1 &

### ===== 启动 Argo =====
pkill cloudflared || true
nohup cloudflared tunnel --url http://127.0.0.1:3000 \
  --no-autoupdate > $ARGO_LOG 2>&1 &

sleep 2

ARGO_DOMAIN=$(grep -o 'https://.*trycloudflare.com' $ARGO_LOG | head -n1 | sed 's#https://##')

### ===== 发布查询接口 =====
echo "$ARGO_DOMAIN" > $WEB/$UUID

### ===== 输出信息 =====
echo
echo "===================================="
echo " TUIC + Argo 双协议节点部署完成"
echo "===================================="
echo "UUID           : $UUID"
echo "TUIC Port      : $TUIC_PORT"
echo "WS Path        : /$UUID"
echo "Argo Domain    : $ARGO_DOMAIN"
echo
echo "查询接口："
echo "http://<VPS_IP>/$UUID"
echo "===================================="
