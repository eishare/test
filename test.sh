#!/usr/bin/env bash
set -e

### ===== 基础 =====
WORKDIR=/etc/sing-box
mkdir -p $WORKDIR
cd $WORKDIR

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "不支持架构"; exit 1 ;;
esac

UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
TUIC_PORT=$(shuf -i20000-40000 -n1)

### ===== 安装依赖 =====
if command -v apk >/dev/null; then
  apk add --no-cache curl ca-certificates openssl
else
  apt update -y
  apt install -y curl ca-certificates openssl
fi

### ===== 下载 sing-box / cloudflared =====
curl -L -o sing-box https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-$ARCH
curl -L -o cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
chmod +x sing-box cloudflared

### ===== 证书 =====
openssl ecparam -genkey -name prime256v1 -out key.pem
openssl req -new -x509 -days 3650 -key key.pem -out cert.pem -subj "/CN=www.bing.com"

### ===== sing-box 配置 =====
cat > config.json <<EOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 8001,
      "users": [{ "uuid": "$UUID" }],
      "transport": {
        "type": "ws",
        "path": "/vless"
      }
    },
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [{
        "uuid": "$UUID",
        "password": "$PASSWORD"
      }],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$WORKDIR/cert.pem",
        "key_path": "$WORKDIR/key.pem"
      }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

### ===== 启动 sing-box =====
pkill sing-box || true
nohup $WORKDIR/sing-box run -c $WORKDIR/config.json >/dev/null 2>&1 &

sleep 1

### ===== 启动 Argo（WS 必须 http）=====
pkill cloudflared || true
nohup $WORKDIR/cloudflared tunnel \
  --url http://127.0.0.1:8001 \
  --no-autoupdate \
  --loglevel info \
  --logfile $WORKDIR/argo.log >/dev/null 2>&1 &

### ===== 等待域名 =====
echo "等待 Argo 域名生成..."
for i in $(seq 1 15); do
  DOMAIN=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' $WORKDIR/argo.log | tail -n1 | sed 's@https://@@')
  [ -n "$DOMAIN" ] && break
  sleep 1
done

IP=$(curl -s ip.sb)

### ===== 输出 =====
echo
echo "========= 部署完成 ========="
echo
echo "【TUIC v5】"
echo "tuic://$UUID:$PASSWORD@$IP:$TUIC_PORT?alpn=h3&allow_insecure=1#TUIC"
echo
echo "【VLESS WS TLS（Argo）】"
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&path=/vless&host=$DOMAIN&sni=$DOMAIN#ARGO"
echo
echo "============================"
