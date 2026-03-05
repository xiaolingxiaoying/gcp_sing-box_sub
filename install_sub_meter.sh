#!/bin/bash
# ==============================================================================
# Script 2: install_sub_meter.sh
# 流量统计与订阅管理：全自动部署，基于 vnstat 和 Python 动态分发
# 特性：支持幂等性（重复运行不会改变订阅 Token，保证链接永久有效）
# ==============================================================================

set -e

echo "=> [1/6] 安装基础依赖 (vnstat, python3)..."
apt-get update -yq
apt-get install -yq vnstat python3 python3-pip curl jq iproute2

# 自动获取主出口网卡
IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -z "$IFACE" ]; then
    IFACE=$(ip link show | grep -v "lo:" | awk -F: '/^[0-9]+:/{gsub(/ /, "", $2); print $2; exit}')
fi
echo "=> 检测到主网卡: $IFACE"

echo "=> [2/6] 配置 vnStat 监控网卡..."
if ! grep -q "^Interface \"$IFACE\"" /etc/vnstat.conf 2>/dev/null; then
    if grep -q '^Interface ' /etc/vnstat.conf 2>/dev/null; then
        sed -i "s/^Interface .*/Interface \"$IFACE\"/" /etc/vnstat.conf
    else
        echo "Interface \"$IFACE\"" >> /etc/vnstat.conf
    fi
fi
systemctl enable --now vnstat
systemctl restart vnstat

echo "=> [3/6] 创建服务隔离环境与订阅副本..."
id subsrv &>/dev/null || useradd -r -s /usr/sbin/nologin subsrv
mkdir -p /var/lib/subsrv
chown subsrv:subsrv /var/lib/subsrv
chmod 750 /var/lib/subsrv

# 检查 Script 1 是否生成了文件，若无则给空模板
if [ -f /etc/s-box/clash_meta_client.yaml ]; then
    cp -f /etc/s-box/clash_meta_client.yaml /var/lib/subsrv/client.yaml
else
    echo "# 暂无订阅内容" > /var/lib/subsrv/client.yaml
fi

if [ -f /etc/s-box/sing_box_client.json ]; then
    cp -f /etc/s-box/sing_box_client.json /var/lib/subsrv/client.json
else
    echo '{"log":{"level":"warn"},"inbounds":[],"outbounds":[]}' > /var/lib/subsrv/client.json
fi

chown subsrv:subsrv /var/lib/subsrv/client.*
chmod 640 /var/lib/subsrv/client.*

touch /var/lib/subsrv/tx_state.json
chown subsrv:subsrv /var/lib/subsrv/tx_state.json
chmod 640 /var/lib/subsrv/tx_state.json

echo "=> [4/6] 配置订阅文件实时同步 (5分钟级)..."
cat > /usr/local/bin/refresh_sub_copy.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ -f "/etc/s-box/clash_meta_client.yaml" ]; then
    cp -f "/etc/s-box/clash_meta_client.yaml" "/var/lib/subsrv/client.yaml.tmp"
    chown subsrv:subsrv "/var/lib/subsrv/client.yaml.tmp" && mv -f "/var/lib/subsrv/client.yaml.tmp" "/var/lib/subsrv/client.yaml"
fi
if [ -f "/etc/s-box/sing_box_client.json" ]; then
    cp -f "/etc/s-box/sing_box_client.json" "/var/lib/subsrv/client.json.tmp"
    chown subsrv:subsrv "/var/lib/subsrv/client.json.tmp" && mv -f "/var/lib/subsrv/client.json.tmp" "/var/lib/subsrv/client.json"
fi
SH
chmod +x /usr/local/bin/refresh_sub_copy.sh

cat > /etc/systemd/system/refresh-sub-copy.timer <<'UNIT'
[Unit]
Description=Run refresh-sub-copy every 5 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true
[Install]
WantedBy=timers.target
UNIT

cat > /etc/systemd/system/refresh-sub-copy.service <<'UNIT'
[Unit]
Description=Refresh served subscription copy
[Service]
Type=oneshot
ExecStart=/usr/local/bin/refresh_sub_copy.sh
UNIT
systemctl daemon-reload
systemctl enable --now refresh-sub-copy.timer

echo "=> [5/6] 编写 Python 流量分发服务..."

# 核心幂等逻辑：保护 Token 不丢失
TOKEN_FILE="/etc/s-box/.sub_token"
if [ -f "$TOKEN_FILE" ]; then
    echo "=> 检测到历史 Token，继续使用以免订阅链接失效..."
    source "$TOKEN_FILE"
else
    echo "=> 初次运行，生成随机安全 Token..."
    TOKEN=$(openssl rand -hex 12)
    mkdir -p /etc/s-box
    echo "TOKEN=\"$TOKEN\"" > "$TOKEN_FILE"
fi

LIMIT_GIB=1000 # 默认 1TB 流量上限
PORT=8081 # 默认服务端口

cat > /usr/local/bin/sub_server.py <<'PY'
#!/usr/bin/env python3
import json, os, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

IFACE      = os.environ.get("SUB_IFACE", "eth0")
YAML_PATH  = "/var/lib/subsrv/client.yaml"
JSON_PATH  = "/var/lib/subsrv/client.json"
LIMIT_GIB  = float(os.environ.get("SUB_LIMIT_GIB", "1000"))
TOKEN      = os.environ.get("SUB_TOKEN", "default_token")

TOTAL_BYTES = int(LIMIT_GIB * 1024 * 1024 * 1024)

def read_tx_bytes():
    try:
        with open(f"/sys/class/net/{IFACE}/statistics/tx_bytes", "r") as f:
            return int(f.read().strip())
    except:
        return 0

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        
        # 路由分发
        if path == f"/{TOKEN}/clash.yaml":
            file_path, content_type = YAML_PATH, "text/yaml; charset=utf-8"
        elif path == f"/{TOKEN}/singbox.json":
            file_path, content_type = JSON_PATH, "application/json; charset=utf-8"
        else:
            self.send_response(404)
            self.end_headers()
            return

        used_tx = read_tx_bytes()
        
        try:
            with open(file_path, "rb") as f:
                body = f.read()
        except:
            body = b"# Error reading subscription file.\n"

        header_val = f"upload=0; download={used_tx}; total={TOTAL_BYTES}; expire=2000000000"

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("subscription-userinfo", header_val)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    port = int(os.environ.get("SUB_PORT", "8081"))
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY
chmod +x /usr/local/bin/sub_server.py

cat > /etc/systemd/system/sub-server.service <<UNIT
[Unit]
Description=Dynamic subscription server with subscription-userinfo
After=network-online.target vnstat.service

[Service]
User=subsrv
Group=subsrv
Environment=SUB_IFACE=$IFACE
Environment=SUB_LIMIT_GIB=$LIMIT_GIB
Environment=SUB_PORT=$PORT
Environment=SUB_TOKEN=$TOKEN
ExecStart=/usr/local/bin/sub_server.py
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now sub-server
systemctl restart sub-server

echo "=> [6/6] 部署完成！"
IP=$(curl -s -4 icanhazip.com || curl -s ipv4.ip.sb)

echo "==========================================================="
echo " 流量统计与订阅管理后端已启动！(已应用幂等保护)"
echo ""
echo " 【 Clash / Clash Meta 订阅链接 】"
echo " http://$IP:$PORT/$TOKEN/clash.yaml"
echo ""
echo " 【 Sing-box 订阅链接 】"
echo " http://$IP:$PORT/$TOKEN/singbox.json"
echo ""
echo " 说明：链接自动携带 subscription-userinfo (默认 1TB 上限)，"
echo " Clash Verge / v2rayN 等客户端会自动识别并显示已用流量。"
echo "==========================================================="
