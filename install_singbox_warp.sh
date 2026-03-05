#!/bin/bash
# ==============================================================================
# Script 1: install_singbox_warp.sh
# 核心功能：Sing-box 五协议共存 + WARP 虚拟 IPv6 (Proxy模式) 分流
# 特性：支持幂等性（重复运行不会导致密码或密钥变化，防止客户端掉线）
# ==============================================================================

set -e

# --- 1. 基础环境与依赖 ---
echo "=> [1/6] 更新系统并安装基础依赖..."
apt-get update -yq
apt-get install -yq curl jq openssl uuid-runtime systemd lsb-release gnupg iproute2 qrencode

# --- 2. 安装 Cloudflare WARP 并配置 Proxy 模式 ---
echo "=> [2/6] 安装 Cloudflare WARP 客户端..."
if ! command -v warp-cli &> /dev/null; then
    curl -fsSl https://pkg.cloudflareclient.com/pubkey.gpg | sudo gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
    apt-get update -yq
    apt-get install -yq cloudflare-warp
fi

echo "=> 配置 WARP Proxy 模式 (端口: 40000)..."
# 幂等处理：如果未注册则注册，避免重复报错
if ! warp-cli --accept-tos account | grep -q "Account type"; then
    warp-cli --accept-tos registration new || true
fi
warp-cli --accept-tos mode proxy || true
warp-cli --accept-tos proxy port 40000 || true
warp-cli --accept-tos connect || true
sleep 3
if curl -sx socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep -q "warp="; then
    echo "=> WARP Proxy 连接成功!"
else
    echo "=> WARP Proxy 连接状态未知，继续执行..."
fi

# --- 3. 安装 Sing-box ---
echo "=> [3/6] 安装 Sing-box 最新版..."
SB_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
SB_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.assets[] | select(.name | contains("linux-amd64.tar.gz")) | .browser_download_url')
wget -qO sing-box.tar.gz "$SB_URL"
tar -xzf sing-box.tar.gz
mv sing-box-*/sing-box /usr/local/bin/
rm -rf sing-box*
chmod +x /usr/local/bin/sing-box

# --- 4. 生成或加载凭证 (核心幂等逻辑) ---
echo "=> [4/6] 配置协议凭证与证书..."
mkdir -p /etc/sing-box
mkdir -p /etc/s-box

CRED_FILE="/etc/s-box/.credentials"
if [ -f "$CRED_FILE" ]; then
    echo "=> 检测到历史凭证，加载旧配置 (保证客户端不掉线)..."
    source "$CRED_FILE"
else
    echo "=> 初次运行，生成全新协议凭证并保存..."
    UUID=$(uuidgen)
    SHORT_ID=$(openssl rand -hex 8)
    KEYPAIR=$(sing-box generate reality-keypair)
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep Private | awk '{print $3}')
    PUBLIC_KEY=$(echo "$KEYPAIR" | grep Public | awk '{print $3}')
    
    cat > "$CRED_FILE" <<EOF
UUID="$UUID"
SHORT_ID="$SHORT_ID"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
EOF
fi

if [ ! -f /etc/sing-box/cert.pem ]; then
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/sing-box/key.pem -out /etc/sing-box/cert.pem -subj "/CN=bing.com" 2>/dev/null
fi

IP=$(curl -s -4 icanhazip.com || curl -s ipv4.ip.sb)
DOMAIN="www.microsoft.com"

# --- 5. 生成 Sing-box 配置文件 ---
echo "=> [5/6] 生成 Sing-box 核心配置..."
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": 443,
      "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$DOMAIN", "server_port": 443 },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-ws",
      "listen": "::",
      "listen_port": 8080,
      "users": [{"uuid": "$UUID", "alterId": 0}],
      "transport": { "type": "ws", "path": "/vmess" }
    },
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": 8443,
      "users": [{"password": "$UUID"}],
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "/etc/sing-box/cert.pem", "key_path": "/etc/sing-box/key.pem" }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "::",
      "listen_port": 9443,
      "users": [{"uuid": "$UUID", "password": "$UUID"}],
      "congestion_control": "bbr",
      "tls": { "enabled": true, "alpn": ["h3"], "certificate_path": "/etc/sing-box/cert.pem", "key_path": "/etc/sing-box/key.pem" }
    },
    {
      "type": "trojan",
      "tag": "trojan",
      "listen": "::",
      "listen_port": 10443,
      "users": [{"password": "$UUID"}],
      "tls": { "enabled": true, "certificate_path": "/etc/sing-box/cert.pem", "key_path": "/etc/sing-box/key.pem" }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "socks", "tag": "warp-out", "server": "127.0.0.1", "server_port": 40000 },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      { "domain_suffix": ["cloudflare.com", "openai.com", "bing.com"], "outbound": "warp-out" },
      { "ip_is_private": true, "outbound": "block" }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF

cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=Sing-box Service
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now sing-box
systemctl restart sing-box

# --- 6. 生成客户端订阅配置 (兼容 vps-sub-meter) ---
echo "=> [6/6] 生成 Clash Meta 与 Sing-box 客户端订阅文件..."

HOSTNAME=$(hostname)

# 6.1 生成 Clash Meta YAML
cat > /etc/s-box/clash_meta_client.yaml <<EOF
port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
global-client-fingerprint: chrome

proxies:
  - name: VLESS-Reality-$HOSTNAME
    type: vless
    server: $IP
    port: 443
    uuid: $UUID
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $DOMAIN
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: chrome

  - name: VMess-WS-$HOSTNAME
    type: vmess
    server: $IP
    port: 8080
    uuid: $UUID
    alterId: 0
    cipher: auto
    udp: true
    tls: false
    network: ws
    ws-opts:
      path: "/vmess"

  - name: Hysteria2-$HOSTNAME
    type: hysteria2
    server: $IP
    port: 8443
    password: $UUID
    alpn: [h3]
    sni: bing.com
    skip-cert-verify: true

  - name: TUIC5-$HOSTNAME
    type: tuic
    server: $IP
    port: 9443
    uuid: $UUID
    password: $UUID
    alpn: [h3]
    disable-sni: true
    udp-relay-mode: native
    congestion-controller: bbr
    sni: bing.com
    skip-cert-verify: true
    
  - name: Trojan-$HOSTNAME
    type: trojan
    server: $IP
    port: 10443
    password: $UUID
    udp: true
    sni: bing.com
    skip-cert-verify: true

proxy-groups:
  - name: 🚀 Proxy
    type: select
    proxies:
      - VLESS-Reality-$HOSTNAME
      - VMess-WS-$HOSTNAME
      - Hysteria2-$HOSTNAME
      - TUIC5-$HOSTNAME
      - Trojan-$HOSTNAME

rules:
  - MATCH,🚀 Proxy
EOF

# 6.2 生成 Sing-box JSON
cat > /etc/s-box/sing_box_client.json <<EOF
{
  "log": { "level": "info" },
  "outbounds": [
    {
      "type": "vless",
      "tag": "VLESS-Reality",
      "server": "$IP",
      "server_port": 443,
      "uuid": "$UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "$DOMAIN",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": { "enabled": true, "public_key": "$PUBLIC_KEY", "short_id": "$SHORT_ID" }
      }
    },
    {
      "type": "vmess",
      "tag": "VMess-WS",
      "server": "$IP",
      "server_port": 8080,
      "uuid": "$UUID",
      "alter_id": 0,
      "transport": { "type": "ws", "path": "/vmess" }
    },
    {
      "type": "hysteria2",
      "tag": "Hysteria2",
      "server": "$IP",
      "server_port": 8443,
      "password": "$UUID",
      "tls": { "enabled": true, "server_name": "bing.com", "insecure": true }
    },
    {
      "type": "tuic",
      "tag": "TUIC",
      "server": "$IP",
      "server_port": 9443,
      "uuid": "$UUID",
      "password": "$UUID",
      "tls": { "enabled": true, "server_name": "bing.com", "insecure": true }
    },
    {
      "type": "trojan",
      "tag": "Trojan",
      "server": "$IP",
      "server_port": 10443,
      "password": "$UUID",
      "tls": { "enabled": true, "server_name": "bing.com", "insecure": true }
    }
  ]
}
EOF

echo "==========================================================="
echo " Sing-box 与 WARP 代理安装完成！(已应用幂等保护)"
echo " 五协议核心已启动。WARP (SOCKS5 40000) 负责接管 Cloudflare 流量。"
echo " 客户端订阅已生成至 /etc/s-box/ 目录下。"
echo " 请继续运行 Script 2 搭建订阅与流量统计后端。"
echo "==========================================================="
