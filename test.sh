#!/bin/sh
set -e

MODE="$*"
UUID=$(cat /proc/sys/kernel/random/uuid)
BASE=/etc/sing-box
BIN=/usr/bin/sing-box
ARGO_LOG=/tmp/argo.log
WWW=/var/www/html

mkdir -p $BASE $WWW

# ===== 内存检测与 swap =====
MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "$MEM_TOTAL" -lt 1048576 ]; then  # 小于1GB
    if ! swapon --show | grep -q swapfile; then
        echo "内存不足1GB，创建1GB swap..."
        fallocate -l 1G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
    fi
fi

# ===== OS 基础依赖 =====
if [ -f /etc/alpine-release ]; then
    PKG="apk add --no-cache"
    $PKG curl ca-certificates busybox-extras >/dev/null
else
    PKG="apt-get update && apt-get install -y"
    $PKG curl ca-certificates busybox >/dev/null
fi

# ===== sing-box 安装 =====
if [ ! -f "$BIN" ]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) A=amd64 ;;
        aarch64) A=arm64 ;;
    esac
    curl -L -o /tmp/sb.tgz https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-$A.tar.gz
    tar -xzf /tmp/sb.tgz -C /tmp
    mv /tmp/sing-box-*/sing-box $BIN
    chmod +x $BIN
fi

# ===== cloudflared 安装 =====
if echo "$MODE" | grep -q argo; then
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
fi

# ===== TUIC 节点 =====
TUIC_JSON=""
if echo "$MODE" | grep -q tuic; then
    PORT=$(echo "$MODE" | sed -n 's/.*tuic"\([^"]*\)".*/\1/p')
    [ -z "$PORT" ] && PORT=$(shuf -i20000-60000 -n1)
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

# ===== sing-box 配置 =====
cat > $BASE/config.json <<EOF
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

pkill sing-box || true
nohup sing-box run -c $BASE/config.json >/dev/null 2>&1 &

# ===== Argo 隧道 =====
DOMAIN=""
if echo "$MODE" | grep -q argo; then
    pkill cloudflared || true
    FIXED=$(echo "$MODE" | sed -n 's/.*argo"\([^"]*\)".*/\1/p')

    if [ -z "$FIXED" ]; then
        cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate > $ARGO_LOG 2>&1 &
    else
        cloudflared tunnel --hostname "$FIXED" --url http://127.0.0.1:3000 --no-autoupdate > $ARGO_LOG 2>&1 &
    fi

    # 等待 Argo 隧道生成
    sleep 3
    DOMAIN=$(grep -o 'https://.*trycloudflare.com' $ARGO_LOG | head -n1 | sed 's#https://##')
    echo "$DOMAIN" > $WWW/$UUID
fi

# ===== HTTP 查询接口（安全本地回环） =====
busybox httpd -p 127.0.0.1:8080 -h $WWW >/dev/null 2>&1 &

# ===== 输出信息 =====
echo
echo "========== 部署完成 =========="
echo "UUID        : $UUID"
[ -n "$PORT" ] && echo "TUIC Port   : $PORT"
[ -n "$DOMAIN" ] && echo "Argo 域名   : $DOMAIN"
[ -n "$DOMAIN" ] && echo "查询接口   : http://127.0.0.1:8080/$UUID"
echo "=============================="
