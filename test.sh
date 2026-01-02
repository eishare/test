#!/bin/sh
set -e

MODE="$*"
UUID="$(cat /proc/sys/kernel/random/uuid)"
BASE=/etc/sing-box
BIN=/usr/bin/sing-box
ARGO_LOG=/tmp/argo.log
WWW=/var/www/html

mkdir -p "$BASE" "$WWW"

################################
# Swap（低内存兼容）
################################
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
DISK_KB=$(df --output=avail / | tail -1)

if [ "$MEM_KB" -lt 524288 ] && [ "$DISK_KB" -gt 131072 ]; then
  if ! swapon --show | grep -q /swapfile; then
    echo "检测到低内存，尝试创建 swap..."
    SWAP_MB=256
    [ "$DISK_KB" -lt 524288 ] && SWAP_MB=128

    if command -v fallocate >/dev/null 2>&1; then
      fallocate -l ${SWAP_MB}M /swapfile 2>/dev/null || true
    fi

    if [ ! -s /swapfile ]; then
      dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_MB 2>/dev/null || true
    fi

    chmod 600 /swapfile || true
    mkswap /swapfile >/dev/null 2>&1 || true
    swapon /swapfile >/dev/null 2>&1 || true
  fi
fi

################################
# 依赖安装（系统识别）
################################
if [ -f /etc/alpine-release ]; then
  apk add --no-cache curl ca-certificates busybox-extras >/dev/null
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl ca-certificates busybox >/dev/null
fi

################################
# sing-box
################################
if [ ! -x "$BIN" ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) A=amd64 ;;
    aarch64) A=arm64 ;;
    *) echo "不支持的架构"; exit 1 ;;
  esac

  curl -L -o /tmp/sb.tgz \
    https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-$A.tar.gz

  tar -xzf /tmp/sb.tgz -C /tmp
  mv /tmp/sing-box-*/sing-box "$BIN"
  chmod +x "$BIN"
fi

################################
# cloudflared（可选）
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
# TUIC
################################
TUIC_JSON=""
if echo "$MODE" | grep -q tuic; then
  PORT=$(shuf -i20000-60000 -n1)
  TUIC_JSON=$(cat <<EOF
,{
  "type":"tuic",
  "listen":"::",
  "listen_port":$PORT,
  "users":[{"uuid":"$UUID"}],
  "congestion_control":"bbr",
  "skip_cert_verify": true
}
EOF
)
fi

################################
# sing-box 配置
################################
cat > "$BASE/config.json" <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    {
      "type":"vless",
      "listen":"127.0.0.1",
      "listen_port":3000,
      "users":[{"uuid":"$UUID"}],
      "transport":{"type":"ws","path":"/$UUID"}
    }
    $TUIC_JSON
  ],
  "outbounds":[{"type":"direct"}]
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

  cloudflared tunnel \
    --url http://127.0.0.1:3000 \
    --no-autoupdate >"$ARGO_LOG" 2>&1 &

  sleep 3
  DOMAIN=$(grep -o 'https://[^ ]*trycloudflare.com' "$ARGO_LOG" | head -n1 | sed 's#https://##')
  echo "$DOMAIN" > "$WWW/$UUID"
fi

################################
# 本地 HTTP 查询接口
################################
busybox httpd -p 127.0.0.1:8080 -h "$WWW" >/dev/null 2>&1 &

################################
# 输出
################################
echo
echo "========== 部署完成 =========="
echo "UUID        : $UUID"
[ -n "$PORT" ] && echo "TUIC Port   : $PORT"
[ -n "$DOMAIN" ] && echo "Argo 域名   : $DOMAIN"
[ -n "$DOMAIN" ] && echo "查询接口   : http://127.0.0.1:8080/$UUID"
echo "=============================="
