#!/usr/bin/env sh
set -e

### ========= 参数解析 =========
for arg in "$@"; do
  case "$arg" in
    tuic=*) tuic="${arg#tuic=}" ;;
    argo=*) argo="${arg#argo=}" ;;
  esac
done

### ========= 基础 =========
WORK=/etc/sing-box
UUID=$(cat /proc/sys/kernel/random/uuid)
PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 24)
SERVER_IP=$(curl -s ip.sb || curl -s ifconfig.me)
RAND_PORT=$(shuf -i 20000-40000 -n 1)

mkdir -p "$WORK"
cd "$WORK"

### ========= TUIC 端口 =========
[ -z "$tuic" ] && TUIC_PORT="$RAND_PORT" || TUIC_PORT="$tuic"

### ========= 架构 =========
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) A=amd64 ;;
  aarch64) A=arm64 ;;
  *) echo "unsupported arch"; exit 1 ;;
esac

### ========= 下载 =========
curl -fsSL https://$A.ssss.nyc.mn/sbx -o sing-box
curl -fsSL https://$A.ssss.nyc.mn/bot -o argo-bin
chmod +x sing-box argo-bin

### ========= TLS =========
openssl ecparam -genkey -name prime256v1 -out key.pem
openssl req -new -x509 -days 3650 -key key.pem -out cert.pem -subj "/CN=www.bing.com"

### ========= sing-box =========
cat > config.json <<EOF
{
  "log": { "disabled": true },
  "inbounds": [
    {
      "type": "tuic",
      "listen": "::",
      "listen_port": $TUIC_PORT,
      "users": [{ "uuid": "$UUID", "password": "$PASS" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "cert.pem",
        "key_path": "key.pem"
      }
    },
    {
      "type": "vless",
      "listen": "127.0.0.1",
      "listen_port": 8080,
      "users": [{ "uuid": "$UUID" }],
      "transport": { "type": "ws", "path": "/argo" }
    }
  ],
  "outbounds": [{ "type": "direct" }]
}
EOF

### ========= 系统判断 =========
if [ -x /sbin/openrc-run ]; then
  INIT=alpine
else
  INIT=systemd
fi

### ========= Argo 行为 =========
ARGO_LOG="$WORK/argo.log"

if [ "$argo" = "0" ]; then
  ARGO_CMD="$WORK/argo-bin tunnel --url http://127.0.0.1:8080 --protocol http2"
  NEED_REFRESH=1
else
  ARGO_CMD="$WORK/argo-bin tunnel --protocol http2 --hostname $argo"
  NEED_REFRESH=0
fi

### ========= systemd =========
if [ "$INIT" = "systemd" ]; then

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
After=network.target

[Service]
ExecStart=$WORK/sing-box run -c $WORK/config.json
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/argo.service <<EOF
[Unit]
After=network.target

[Service]
ExecStart=$ARGO_CMD
StandardOutput=append:$ARGO_LOG
StandardError=append:$ARGO_LOG
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now sing-box argo

if [ "$NEED_REFRESH" = "1" ]; then
cat > /etc/systemd/system/argo-refresh.timer <<EOF
[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/argo-refresh.service <<EOF
[Service]
Type=oneshot
ExecStart=/bin/systemctl restart argo
EOF

systemctl enable --now argo-refresh.timer
fi

else
### ========= Alpine =========

cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
command="$WORK/sing-box"
command_args="run -c $WORK/config.json"
command_background=true
EOF

cat > /etc/init.d/argo <<EOF
#!/sbin/openrc-run
command="$ARGO_CMD"
command_background=true
EOF

chmod +x /etc/init.d/sing-box /etc/init.d/argo
rc-update add sing-box default
rc-update add argo default
rc-service sing-box start
rc-service argo start

if [ "$NEED_REFRESH" = "1" ]; then
( crontab -l 2>/dev/null; echo "0 * * * * rc-service argo restart" ) | crontab -
fi

fi

### ========= 解析域名（关键修复点） =========
sleep 6

if [ "$argo" = "0" ]; then
  DOMAIN=$(grep -oE '[a-z0-9-]+\.trycloudflare.com' "$ARGO_LOG" | tail -1)
else
  DOMAIN="$argo"
fi

### ========= 输出订阅 =========
cat > sub.txt <<EOF
tuic://$UUID:$PASS@$SERVER_IP:$TUIC_PORT?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#TUIC
vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&path=/argo#ARGO
EOF

echo "========== 订阅 =========="
cat sub.txt
