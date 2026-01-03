#!/bin/sh
set -e

VPS_IP=$(curl -s ifconfig.me || echo "未知IP")

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
# 安装 cloudflare
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
  PASS=$(cat /proc/sys/kernel/random/uuid | cut -d- -f1)  # 随机短 password
  TUIC_JSON=$(cat <<EOF
,{
  "type":"tuic",
  "listen":"::",
  "listen_port":$PORT,
  "users":[{"uuid":"$UUID", "password":"$PASS"}],
  "congestion_control":"bbr",
  \"tls\": {\"enabled\": true, \"alpn\": [\"h3\"], \"certificate_path\": \"${FILE_PATH}/cert.pem\", \"key_path\": \"${FILE_PATH}/private.key\"}
    },"; \
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
  rm -rf ~/.cloudflared/  # 清理旧配置
  echo "启动 Argo 隧道（兼容 2026 outage，重试 5 次）..."

  # 加重试参数 + 强制 HTTP2/IPv4
  RETRY_COUNT=0
  MAX_RETRIES=5
  while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ -z "$DOMAIN" ]; do
    cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate --no-tls-verify --protocol http2 --edge-ip-version 4 --loglevel info --logfile /dev/stdout >"$ARGO_LOG" 2>&1 &
    PID=$!
    
    # 无限等待直到域名出现或超时 120 秒
    echo "等待 Argo 域名生成（第 $((RETRY_COUNT+1)) 次尝试）..."
    for i in $(seq 1 120); do
      if strings "$ARGO_LOG" 2>/dev/null | grep -iq 'trycloudflare.com.*https'; then
        DOMAIN=$(strings "$ARGO_LOG" 2>/dev/null | grep -i 'https://.*trycloudflare.com' | head -n1 | awk '{print $NF}' | sed 's/https:\/\///' | sed 's/|$//')
        if [ -n "$DOMAIN" ]; then
          echo "Argo 域名生成成功: $DOMAIN"
          echo "$DOMAIN" > "$WWW/$UUID"
          break 2  # 跳出外层循环
        fi
      fi
      sleep 1
    done
    
    # 超时，重试
    kill $PID
    RETRY_COUNT=$((RETRY_COUNT+1))
    echo "超时，重试 ($RETRY_COUNT/$MAX_RETRIES)..."
    sleep 5
  done

  if [ -z "$DOMAIN" ]; then
    echo "Argo 生成失败（可能 outage 或网络问题）"
    echo "手动查看: strings $ARGO_LOG | grep -i trycloudflare"
    echo "建议: 检查 VPS 网络/DNS，或换用正式 Cloudflare Tunnel (需账号)"
  fi
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
echo
echo "========== 部署完成 =========="
echo "UUID : $UUID"
[ -n "$PASS" ] && echo "TUIC Password : $PASS"
[ -n "$PORT" ] && echo "TUIC Port : $PORT"
[ -n "$DOMAIN" ] && echo "Argo 域名 : $DOMAIN"
[ -n "$DOMAIN" ] && echo "查询接口 : http://127.0.0.1:8080/$UUID"
echo

if [ -n "$PORT" ]; then
  echo "=== TUIC v5 直连节点链接（推荐使用）==="
  echo "tuic://$UUID:$PASS@$VPS_IP:$PORT?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=www.bing.com#TUIC-Bing-SNI"
  echo
  echo "直接复制到 v2rayN 导入（确保 v2rayN 是最新版，支持 TUIC v5）"
  echo "如果导入失败/显示 hysteria2: 手动添加 → 类型 TUIC v5, UUID: $UUID, Password: $PASS, 端口 $PORT, 允许不安全连接, SNI: www.bing.com"
  echo "连通测试: telnet $VPS_IP $PORT (应连接成功); ufw allow $PORT/udp (开放端口)"
fi

if [ -n "$DOMAIN" ]; then
  echo "=== Argo VLESS + WS + TLS 节点链接 ==="
  echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=www.bing.com&sni=$DOMAIN&fp=chrome&alpn=h3#Argo-VLESS-Bing"
  echo
fi

echo "VPS 公网 IP : $VPS_IP"
echo "=============================="
