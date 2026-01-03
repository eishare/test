#!/usr/bin/env bash
set -e

WORK=/etc/sing-box
CFG=$WORK/config.json

TUIC_PORT=${2:-$(shuf -i20000-65000 -n1)}
ARGO_DOMAIN=${4:-""}

mkdir -p $WORK
cd $WORK

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) A=amd64 ;;
  aarch64) A=arm64 ;;
  *) echo "unsupported arch"; exit 1 ;;
esac

curl -fsSL https://$A.ssss.nyc.mn/sbx -o sing-box
curl -fsSL https://$A.ssss.nyc.mn/bot -o argo
chmod +x sing-box argo

UUID=$(cat /proc/sys/kernel/random/uuid)
PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

openssl ecparam -genkey -name prime256v1 -out key.pem
openssl req -new -x509 -days 3650 -key key.pem -out cert.pem -subj "/CN=bing.com"

cat > $CFG <<EOF
{
  "log": { "level": "error" },

  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": 8001,
      "users": [{ "uuid": "$UUID" }],
      "transport": {
        "type": "ws",
        "path": "/vless"
      },
      "tls": {
        "enabled": true,
        "certificate_path": "$WORK/cert.pem",
        "key_path": "$WORK/key.pem"
      }
    },
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [{ "uuid": "$UUID", "password": "$PASS" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "certificate_path": "$WORK/cert.pem",
        "key_path": "$WORK/key.pem"
      }
    }
  ],

  "outbounds": [{ "type": "direct" }]
}
EOF

cat > /etc/systemd/system/sing-box.service <<EOF
[Service]
ExecStart=$WORK/sing-box run -c $CFG
Restart=always
EOF

cat > /etc/systemd/system/argo.service <<EOF
[Service]
ExecStart=$WORK/argo tunnel --url https://localhost:8001
Restart=always
EOF

systemctl daemon-reload
systemctl enable --now sing-box argo

if [[ -n "$ARGO_DOMAIN" ]]; then
  ARGO_LINK="vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${ARGO_DOMAIN}&path=${WS_PATH}#Argo-VLESS-WS"
  echo
  echo "===== Argo 节点 ====="
  echo "$ARGO_LINK"
fi

if [[ -n "$TUIC_PORT" ]]; then
  TUIC_LINK="tuic://${UUID}:@${DOMAIN}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#TUIC-${TUIC_PORT}"
  echo
  echo "===== TUIC 节点 ====="
  echo "$TUIC_LINK"
fi

