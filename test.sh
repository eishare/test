#!/usr/bin/env bash
set -e

export LANG=en_US.UTF-8
WORKDIR=/etc/sing-box
UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)
WS_PORT=8001
TUIC_PORT=$(shuf -i 20000-40000 -n 1)

mkdir -p $WORKDIR
cd $WORKDIR

# ===== 安装依赖 =====
apt update -y
apt install -y curl ca-certificates openssl

# ===== 下载 sing-box + cloudflared =====
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Unsupported arch"; exit 1 ;;
esac

curl -Lo sing-box https://$ARCH.ssss.nyc.mn/sbx
curl -Lo argo https://$ARCH.ssss.nyc.mn/bot
chmod +x sing-box argo

# ===== 证书（自签）=====
openssl ecparam -genkey -name prime256v1 -out private.key
openssl req -new -x509 -days 3650 \
  -key private.key -out cert.pem \
  -subj "/CN=bing.com"

# ===== sing-box 配置 =====
cat > config.json <<EOF
{
  "log": { "level": "error" },

  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": $WS_PORT,
      "users": [{ "uuid": "$UUID" }],
      "transport": {
        "type": "ws",
        "path": "/vless"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [{
        "uuid": "$UUID",
        "password": "$PASSWORD"
      }],
      "tls": {
        "enabled": true,
        "certificate_pa_
