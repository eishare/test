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

# 仅在内存 < 512MB 且磁盘足够时创建 swap
if [ "$MEM_KB" -lt 524288 ] && [ "$DISK_KB" -gt 131072 ]; then
  if ! swapon --show | grep -q /swapfile; then
    echo "检测到低内存，尝试创建 swap..."
    SWAP_MB=256
    [ "$DISK_KB" -lt 524288 ] && SWAP_MB=128

    # 尝试 fallocate 创建 swap
    if command -v fallocate >/dev/null 2>&1; then
      fallocate -l ${SWAP_MB}M /swapfile 2>/dev/null || true
    fi

    # fallback 使用 dd
    if [ ! -s /swapfile ]; then
      dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_MB 2>/dev/null || true
    fi

    chmod 600 /swapfile || true
    mkswap /swapfile >/dev/null 2>&1 || true
    swapon /swapfile >/dev/null 2>&1 || true
  fi
fi

################################
# 依赖安装（系统兼容）
################################
if [ -f /etc/alpine-release ]; then
  # Alpine
  apk add --no-cache curl ca-certificates busybox-extras >/dev/null
else
  # Debian / Ubuntu
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y curl ca-certificates busybox >/dev/null
fi

################################
# 安装 sing-box
################################
if [ ! -x "$BIN" ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) A=amd64 ;;
    aarch64) A=arm64 ;;
    *) echo "不支持的架构"; exit 1 ;;
  esac

  # 获取最新版本号和精确文件名
  LATEST_JSON=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest)
  VERSION=$(echo "$LATEST_JSON" | grep '"tag_name"' | cut -d'"' -f4)
  PACKAGE=$(echo "$LATEST_JSON" | grep '"name"' | grep "sing-box-${VERSION:1}-linux-$A.tar.gz" | cut -d'"' -f4)

  if [ -z "$PACKAGE" ]; then
    echo "获取 sing-box 下载链接失败"
    exit 1
  fi

  curl -L -o /tmp/sb.tgz \
    "https://github.com/SagerNet/sing-box/releases/download/$VERSION/$PACKAGE"
  tar -xzf /tmp/sb.tgz -C /tmp
  mv /tmp/sing-box-*/sing-box "$BIN"
  chmod +x "$BIN"
  rm -rf /tmp/sb.tgz /tmp/sing-box-*
fi

################################
# 安装 cloudflared（可选）
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
# TUIC 配置
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
# sing-box 配置文件
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
# Argo 隧道配置
################################
DOMAIN=""
if echo "$MODE" | grep -q argo; then
  pkill cloudflared >/dev/null 2>&1 || true

  cloudflared tunnel \
    --url http://127.0.0.1:3000 \
    --no-autoupdate >"$ARGO_LOG" 2>&1 &

  # 等待生成临时域名
  sleep 3
  DOMAIN=$(grep -o 'https://[^ ]*trycloudflare.com' "$ARGO_LOG" | head -n1 | sed 's#https://##')
  echo "$DOMAIN" > "$WWW/$UUID"
fi

################################
# 本地 HTTP 查询接口
################################
busybox httpd -p 127.0.0.1:8080 -h "$WWW" >/dev/null 2>&1 &

################################
# 输出信息
################################
echo
echo "========== 部署完成 =========="
echo "UUID        : $UUID"
[ -n "$PORT" ] && echo "TUIC Port   : $PORT"
[ -n "$DOMAIN" ] && echo "Argo 域名   : $DOMAIN"
[ -n "$DOMAIN" ] && echo "查询接口   : http://127.0.0.1:8080/$UUID"
echo "=============================="
