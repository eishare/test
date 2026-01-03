#!/bin/sh
set -e

MODE="$*"
UUID="$(cat /proc/sys/kernel/random/uuid)"
PASS="$(cat /proc/sys/kernel/random/uuid | cut -d- -f1)"
BASE=/etc/sing-box
BIN=/usr/bin/sing-box
ARGO_LOG=/tmp/argo.log
WWW=/var/www/html
VPS_IP=$(curl -s ifconfig.me || echo "YOUR_VPS_IP")

mkdir -p "$BASE" "$WWW"

################################
# 基础依赖
################################
if [ -f /etc/alpine-release ]; then
  apk add --no-cache curl ca-certificates busybox-extras
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates busybox
fi

################################
# 安装 sing-box
################################
if [ ! -x "$BIN" ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) A=amd64 ;;
    aarch64) A=arm64 ;;
    *) echo "Unsupported arch"; exit 1 ;;
  esac

  VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)

  curl -L -o /tmp/sb.tgz \
    https://github.com/SagerNet/sing-box/releases/download/$VER/sing-box-linux-$A.tar.gz

  tar -xzf /tmp/sb.tgz -C /tmp
  mv /tmp/sing-box-*/sing-box "$BIN"
  chmod +x "$BIN"
fi

################################
# 安装 cloudflared（Argo）
################################
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
fi

################################
# TUIC 端口
################################
PORT=$(shuf -i20000-60000 -n1)

################################
# sing-box 配置（重点：无 TLS）
################################
cat > "$BASE/config.json" <<EOF
{
  "log": { "disabled": true },
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
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "password": "$PASS"
        }
      ],
      "congestion_control": "bbr"
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

pkill sing-box >/dev/null 2>&1 || true
nohup sing-box run -c "$BASE/config.json" >/dev/null 2>&1 &

################################
# Argo 隧道
################################
DOMAIN=""
if echo "$MODE" | grep -q argo; then
  pkill cloudflared >/dev/null 2>&1 || true
  cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate >"$ARGO_LOG" 2>&1 &
  sleep 3
  DOMAIN=$(grep -o 'https://.*trycloudflare.com' "$ARGO_LOG" | head -n1 | sed 's#https://##')
  [ -n "$DOMAIN" ] && echo "$DOMAIN" > "$WWW/$UUID"
fi

################################
# 本地 HTTP 查询
################################
busybox httpd -p 127.0.0.1:8080 -h "$WWW" >/dev/null 2>&1 &

################################
# 输出
################################
echo
echo "========== 部署完成 =========="
echo "UUID        : $UUID"
echo "Password    : $PASS"
echo "TUIC Port   : $PORT"
[ -n "$DOMAIN" ] && echo "Argo 域名   : $DOMAIN"
[ -n "$DOMAIN" ] && echo "查询接口   : http://127.0.0.1:8080/$UUID"
echo

echo "=== v2rayN TUIC v5 手动填写 ==="
echo "地址      : $VPS_IP"
echo "端口      : $PORT"
echo "UUID      : $UUID"
echo "Password  : $PASS"
echo "ALPN      : h3"
echo "SNI       : www.bing.com"
echo "允许不安全连接 : ✔（必须勾选）"
echo "=============================="
