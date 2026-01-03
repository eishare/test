#!/usr/bin/env bash
set -e

### ===== 基础变量 =====
WORK=/etc/sing-box
BIN=$WORK/sing-box
CFG=$WORK/config.json
ARGO=$WORK/argo

mkdir -p $WORK
cd $WORK

### ===== 架构判断 =====
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  A=amd64 ;;
  aarch64) A=arm64 ;;
  *) echo "unsupported arch"; exit 1 ;;
esac

### ===== 下载二进制 =====
curl -fsSL https://$A.ssss.nyc.mn/sbx -o $BIN
curl -fsSL https://$A.ssss.nyc.mn/bot -o $ARGO
chmod +x $BIN $ARGO

### ===== 生成参数 =====
UUID=$(cat /proc/sys/kernel/random/uuid)
PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
TUIC_PORT=$(shuf -i20000-65000 -n1)

### ===== 自签证书（TUIC 用）=====
openssl ecparam -genkey -name prime256v1 -out key.pem
openssl req -new -x509 -days 3650 \
  -key key.pem -out cert.pem \
  -subj "/CN=cloudflare.com"

### ===== sing-box 配置 =====
cat > $CFG <<EOF
{
  "log": { "level": "error" },

  "inbounds": [
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 8001,
      "users": [{ "uuid": "$UUID" }],
      "transport": {
        "type": "grpc",
        "service_name": "grpc"
      },
      "tls": { "enabled": false }
    },
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [{
        "uuid": "$UUID",
        "password": "$PASS"
      }],
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

### ===== systemd =====
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=$BIN run -c $CFG
Restart=always
LimitNOFILE=51200
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/argo.service <<EOF
[Unit]
After=network.target
[Service]
ExecStart=$ARGO tunnel --url http://127.0.0.1:8001 --no-autoupdate
Restart=always
StandardOutput=append:/var/log/argo.log
StandardError=append:/var/log/argo.log
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box argo

sleep 3

### ===== 解析 Argo 临时域名 =====
ARGO_DOMAIN=$(grep -oE 'https://[-0-9a-z]+\.trycloudflare.com' /var/log/argo.log | tail -n1 | sed 's#https://##')
SERVER_IP=$(curl -fsSL https://api.ipify.org)

### ===== 输出节点 =====
echo
echo "========== 节点信息 =========="

if [[ -n "$ARGO_DOMAIN" ]]; then
  echo
  echo "[Argo - VLESS gRPC]"
  echo "vless://${UUID}@${ARGO_DOMAIN}:443?type=grpc&serviceName=grpc&security=tls#Argo-gRPC"
fi

echo
echo "[TUIC]"
echo "tuic://${UUID}:${PASS}@${SERVER_IP}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allow_insecure=1#TUIC"

echo "=============================="
