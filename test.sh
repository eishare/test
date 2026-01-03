#!/usr/bin/env bash
set -e

# ========= 基础 =========
WORKDIR=/etc/sing-box
mkdir -p $WORKDIR
cd $WORKDIR

ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "不支持架构"; exit 1 ;;
esac

TUIC_ARG="$1"
ARGO_ARG="$2"

UUID=$(cat /proc/sys/kernel/random/uuid)
PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
TUIC_PORT=${TUIC_ARG:-$(shuf -i20000-40000 -n1)}

# ========= 安装依赖 =========
apt update -y
apt install -y curl ca-certificates openssl

# ========= 下载 =========
curl -L -o sing-box https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-$ARCH
curl -L -o argo https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH
chmod +x sing-box argo

# ========= TLS 证书 =========
openssl ecparam -genkey -name prime256v1 -out key.pem
openssl req -new -x509 -days 3650 -key key.pem -out cert.pem -subj "/CN=www.bing.com"

# ========= sing-box 配置 =========
cat > config.json <<EOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "type": "vless",
      "listen": "::",
      "listen_port": 8001,
      "users": [{ "uuid": "$UUID" }],
      "transport": {
        "type": "ws",
        "path": "/vless"
      },
      "tls": {
        "enabled": true,
        "certificate_path": "$WORKDIR/cert.pem",
        "key_path": "$WORKDIR/key.pem"
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

# ========= systemd =========
cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=$WORKDIR/sing-box run -c $WORKDIR/config.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/argo.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=$WORKDIR/argo tunnel --url https://localhost:8001 --no-autoupdate --loglevel info --logfile $WORKDIR/argo.log
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box argo
systemctl restart sing-box argo

# ========= 获取 Argo 域名 =========
echo "等待 Argo 域名生成..."
for i in {1..10}; do
  DOMAIN=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' argo.log | tail -n1 | sed 's@https://@@')
  [ -n "$DOMAIN" ] && break
  sleep 2
done

echo "$DOMAIN" > argo_domain

IP=$(curl -s ip.sb)

# ========= 输出 =========
cat <<EOF

========= 部署完成 =========

【TUIC v5】
tuic://$UUID:$PASSWORD@$IP:$TUIC_PORT?alpn=h3&allow_insecure=1#TUIC

【VLESS WS TLS（Argo）】
vless://$UUID@$DOMAIN:443?encryption=none&security=
