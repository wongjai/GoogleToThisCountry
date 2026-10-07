#!/bin/bash
# =========================================================
# GoogleToThisCountry (GTTC) 管理腳本
# 支援國家/地區: 🇹🇼 台灣 | 🇨🇳 中國大陸 | 🇯🇵 日本 | 🇲🇴 澳門 | 🇺🇸 美國 | 🇬🇧 英國 (實驗性)
# 網路堆疊: 自動偵測 僅 IPv4 / 僅 IPv6 / 雙堆疊，DNS 與保活依實際堆疊調整
# 快捷指令: gttc
# =========================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

PING_SCRIPT="/usr/local/bin/gttc_ping.sh"
SERVICE_FILE_SYSTEMD="/etc/systemd/system/gttc-ping.service"
SERVICE_FILE_OPENRC="/etc/init.d/gttc-ping"
CONFIG_TAG_FILE="/etc/gttc_country.conf"

# ---------------------------------------------------------
# Network stack helpers
# probe_ip / is_warp_ip / detect_net_stack are copied verbatim (declare -f) into
# the generated keep-alive script, so they must stay self-contained and ASCII-only.
# ---------------------------------------------------------

# Print the public IP seen over one IP family ($1 = 4 or 6); print nothing if
# that family is unreachable.
probe_ip() {
    local fam="$1" first url ip
    if [ "$fam" = "6" ]; then first="https://api6.ipify.org"; else first="https://api.ipify.org"; fi
    for url in "$first" "https://ifconfig.me"; do
        ip=$(curl -s "-$fam" --connect-timeout 5 --max-time 10 "$url" 2>/dev/null) || ip=""
        if [ "$fam" = "6" ]; then
            [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:* ]] || ip=""
        else
            [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || ip=""
        fi
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    return 0
}

# Cloudflare WARP egress: 104.28.0.0/16 (IPv4, as upstream) and 2a09:bac0::/29 (IPv6).
is_warp_ip() {
    local ip="${1,,}"
    case "$ip" in
        104.28.*|2a09:bac[0-7]:*) return 0 ;;
    esac
    return 1
}

# Sets NET_IP4, NET_IP6 and NET_STACK (ipv4 | ipv6 | dual | none).
detect_net_stack() {
    NET_IP4=$(probe_ip 4)
    NET_IP6=$(probe_ip 6)
    if [ -n "$NET_IP4" ] && [ -n "$NET_IP6" ]; then
        NET_STACK="dual"
    elif [ -n "$NET_IP6" ]; then
        NET_STACK="ipv6"
    elif [ -n "$NET_IP4" ]; then
        NET_STACK="ipv4"
    else
        NET_STACK="none"
    fi
}

net_stack_label() {
    case "$NET_STACK" in
        ipv4) echo "僅 IPv4" ;;
        ipv6) echo "僅 IPv6" ;;
        dual) echo "雙堆疊 (IPv4 + IPv6)" ;;
        *)    echo "未能檢測到可用的網路協定，沿用 IPv4 設定" ;;
    esac
}

# JSON array of fallback resolvers reachable over the detected stack. An IPv6-only
# host must never be given 1.1.1.1 / 8.8.8.8: they cannot be reached there and
# stall every lookup. $1 = enable | disable (disable also lists plain Cloudflare).
fallback_dns_json() {
    local v4='"https://1.1.1.1/dns-query","8.8.8.8"'
    local v6='"https://[2606:4700:4700::1111]/dns-query","2001:4860:4860::8888"'
    if [ "$1" = "disable" ]; then
        v4+=',"1.1.1.1"'
        v6+=',"2606:4700:4700::1111"'
    fi
    case "$NET_STACK" in
        ipv6) echo "[$v6]" ;;
        dual) echo "[$v4,$v6]" ;;
        *)    echo "[$v4]" ;;
    esac
}

check_warp() {
    local ip
    detect_net_stack
    for ip in "$NET_IP4" "$NET_IP6"; do
        if is_warp_ip "$ip"; then
            echo -e "${RED}[⚠️ 錯誤] 檢測到目前處於 Cloudflare WARP 環境 (IP: $ip)！${NC}"
            echo -e "${RED}[⚠️ 提示] 本腳本不支援在 WARP 環境下執行，腳本將自動結束。${NC}"
            exit 1
        fi
    done
}

show_banner() {
    clear
    echo -e "${CYAN}+-------------------------------------------------------+${NC}"
    echo -e "${CYAN}|         GoogleToThisCountry (GTTC) 管理腳本           |${NC}"
    echo -e "${CYAN}+-------------------------------------------------------+${NC}"
    echo ""
    echo -e "   ${BLUE}██████${NC}   ${RED}██████${NC}   ${YELLOW}██████${NC}   ${BLUE}██████${NC}    ${GREEN}██${NC}      ${RED}██████${NC}"
    echo -e "  ${BLUE}██${NC}        ${RED}██  ██${NC}   ${YELLOW}██  ██${NC}  ${BLUE}██${NC}         ${GREEN}██${NC}      ${RED}██${NC}"
    echo -e "  ${BLUE}██   ███${NC}  ${RED}██  ██${NC}   ${YELLOW}██  ██${NC}  ${BLUE}██   ███${NC}   ${GREEN}██${NC}      ${RED}██████${NC}"
    echo -e "  ${BLUE}██    ██${NC}  ${RED}██  ██${NC}   ${YELLOW}██  ██${NC}  ${BLUE}██    ██${NC}   ${GREEN}██${NC}      ${RED}██${NC}"
    echo -e "   ${BLUE}██████${NC}   ${RED}██████${NC}   ${YELLOW}██████${NC}   ${BLUE}██████${NC}    ${GREEN}███████${NC} ${RED}██████${NC}"
    echo ""
}

find_config() {
    XRAY_CONF=""
    for path in "/etc/xray/config.json" "/usr/local/etc/xray/config.json" "/etc/v2ray/config.json" "/usr/local/etc/v2ray/config.json"; do
        if [ -f "$path" ]; then
            XRAY_CONF="$path"
            break
        fi
    done
}

get_current_country_name() {
    if [ -f "$CONFIG_TAG_FILE" ]; then
        cat "$CONFIG_TAG_FILE"
    else
        echo "未開啟"
    fi
}

check_status() {
    find_config
    if [ -n "$XRAY_CONF" ] && [ -f "$CONFIG_TAG_FILE" ]; then
        COUNTRY=$(cat "$CONFIG_TAG_FILE")
        echo -e "${GREEN}[已開啟 - ${COUNTRY}]${NC}"
    else
        echo -e "${RED}[已關閉]${NC}"
    fi
}

setup_shortcut() {
    mkdir -p /usr/local/bin
    LOCAL_SCRIPT="/usr/local/bin/gttc_manager.sh"

    SCRIPT_SOURCE="$0"
    if [ "$SCRIPT_SOURCE" = "bash" ] || [ "$SCRIPT_SOURCE" = "-bash" ] || [[ "$SCRIPT_SOURCE" == *"/dev/fd/"* ]] || [ "$SCRIPT_SOURCE" = "/dev/stdin" ]; then
        echo -e "${YELLOW}正在將腳本持久化安裝至 $LOCAL_SCRIPT ...${NC}"
        curl -sSL "https://raw.githubusercontent.com/wongjai/GoogleToThisCountry/main/gttc.sh" -o "$LOCAL_SCRIPT" || \
        wget -qO "$LOCAL_SCRIPT" "https://raw.githubusercontent.com/wongjai/GoogleToThisCountry/main/gttc.sh"
    else
        if [ "$(readlink -f "$SCRIPT_SOURCE" 2>/dev/null)" != "$LOCAL_SCRIPT" ]; then
            cp -f "$(readlink -f "$SCRIPT_SOURCE")" "$LOCAL_SCRIPT" 2>/dev/null || true
        fi
    fi

    chmod +x "$LOCAL_SCRIPT" 2>/dev/null || true
    ln -sf "$LOCAL_SCRIPT" /usr/local/bin/gttc
    chmod +x /usr/local/bin/gttc
}

check_swap() {
    if [ -f /proc/1/environ ] && grep -qa -e "container=lxc" -e "container=docker" /proc/1/environ; then
        return 0
    fi
    if [ -d /dev/pve ] || grep -q "lxc" /proc/1/cgroup 2>/dev/null; then
        return 0
    fi

    MEM_FREE=$(free -m | awk '/Mem:/ {print $4+$6}')
    SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')

    if [ -n "$MEM_FREE" ] && [ "$MEM_FREE" -lt 300 ] && [ "$SWAP_TOTAL" -eq 0 ]; then
        echo -e "${YELLOW}檢測到虛擬機記憶體不足且未配置 Swap，正在建立 1GB 臨時 Swap...${NC}"
        dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null || true
        chmod 600 /swapfile 2>/dev/null || true
        mkswap /swapfile >/dev/null 2>&1 || true
        swapon /swapfile >/dev/null 2>&1 || true
    fi
}

create_ping_service() {
    local lang_header="$1"
    
    {
        cat << 'EOF'
#!/bin/bash
UA_MOBILE="Mozilla/5.0 (Linux; Android 14; Pixel 8 Build/UD1A.230803.041) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.6261.119 Mobile Safari/537.36"

endpoints=(
    "https://www.google.com/generate_204"
    "https://connectivitycheck.gstatic.com/generate_204"
    "https://clients3.google.com/generate_204"
    "https://location.services.mozilla.com/v1/geolocate"
    "https://play.googleapis.com/generate_204"
    "https://safebrowsing.googleapis.com/v4/threatListUpdates:fetch"
)

EOF
        declare -f probe_ip is_warp_ip detect_net_stack
        cat << EOF

# The stack is re-detected on every round, so the service follows the host if
# IPv4 or IPv6 connectivity appears or disappears.
while true; do
    detect_net_stack
    if is_warp_ip "\$NET_IP4" || is_warp_ip "\$NET_IP6"; then
        echo "Detected WARP environment (\${NET_IP4:-\$NET_IP6}), stopping services."
        exit 1
    fi

    # Probe through each reachable family; "x" = nothing detected, let curl choose.
    case "\$NET_STACK" in
        ipv4) families="4" ;;
        ipv6) families="6" ;;
        dual) families="4 6" ;;
        *)    families="x" ;;
    esac

    for fam in \$families; do
        fam_opt=""
        [ "\$fam" = "x" ] || fam_opt="-\$fam"
        for url in "\${endpoints[@]}"; do
            curl -s \$fam_opt -A "\$UA_MOBILE" \\
                 -H "Accept-Language: ${lang_header}" \\
                 -H "Cache-Control: no-cache" \\
                 --connect-timeout 5 \\
                 "\$url" >/dev/null 2>&1 || true
        done
    done

    sleep 600
done
EOF
    } > "$PING_SCRIPT"
    chmod +x "$PING_SCRIPT"

    if command -v rc-service >/dev/null 2>&1 || [ -f /etc/alpine-release ]; then
        cat << 'EOF' > "$SERVICE_FILE_OPENRC"
#!/sbin/openrc-run

name="gttc-ping"
description="Google Country Location Keep-Alive Service"
command="/usr/local/bin/gttc_ping.sh"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
        chmod +x "$SERVICE_FILE_OPENRC"
        rc-update add gttc-ping default >/dev/null 2>&1 || true
    else
        cat << EOF > "$SERVICE_FILE_SYSTEMD"
[Unit]
Description=Google Country Location Keep-Alive Service
After=network.target

[Service]
Type=simple
ExecStart=$PING_SCRIPT
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

install_core_alpine_binary() {
    echo -e "${YELLOW}正在下載核心服務二進位檔案...${NC}"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) XARCH="64" ;;
        aarch64|arm64) XARCH="arm64-v8a" ;;
        armv7l) XARCH="arm32-v7a" ;;
        *) XARCH="64" ;;
    esac

    TMP_DIR=$(mktemp -d)
    curl -sSL -o "$TMP_DIR/xray.zip" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XARCH}.zip"
    unzip -q -o "$TMP_DIR/xray.zip" -d "$TMP_DIR"
    
    mkdir -p /usr/local/bin /usr/local/share/xray /etc/xray
    cp -f "$TMP_DIR/xray" /usr/local/bin/xray
    chmod +x /usr/local/bin/xray
    [ -f "$TMP_DIR/geoip.dat" ] && cp -f "$TMP_DIR/geoip.dat" /usr/local/share/xray/
    [ -f "$TMP_DIR/geosite.dat" ] && cp -f "$TMP_DIR/geosite.dat" /usr/local/share/xray/
    rm -rf "$TMP_DIR"

    cat << 'EOF' > /etc/init.d/xray
#!/sbin/openrc-run

name="xray"
description="Proxy Core Service"
command="/usr/local/bin/xray"
command_args="run -c /etc/xray/config.json"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
}

install_core() {
    setup_shortcut

    NEED_INSTALL=0
    for pkg in curl jq python3 bash unzip; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            NEED_INSTALL=1
            break
        fi
    done

    if [ "$NEED_INSTALL" -eq 1 ]; then
        echo -e "${YELLOW}=== 檢測到缺少相依套件，開始安裝環境 ===${NC}"
        check_swap
        
        if command -v apk >/dev/null 2>&1; then
            apk update -q
            apk add -q curl jq python3 bash unzip
        elif command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq curl jq python3 bash unzip
        elif command -v yum >/dev/null 2>&1; then
            yum install -y -q curl jq python3 bash unzip
        fi
    fi

    if command -v apk >/dev/null 2>&1 || [ -f /etc/alpine-release ]; then
        if ! command -v xray >/dev/null 2>&1; then
            echo -e "${YELLOW}檢測到 Alpine 環境，配置來源並嘗試安裝...${NC}"
            ALPINE_VER=$(cat /etc/alpine-release | cut -d'.' -f1,2)
            echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories
            echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories
            apk update -q

            if ! apk add -q xray 2>/dev/null; then
                install_core_alpine_binary
            else
                rc-update add xray default >/dev/null 2>&1 || true
            fi
        fi
    else
        find_config
        if [ -z "$XRAY_CONF" ]; then
            echo -e "${YELLOW}未檢測到核心服務，開始執行一鍵安裝...${NC}"
            bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
        fi
    fi

    find_config
    if [ -z "$XRAY_CONF" ]; then
        XRAY_CONF="/etc/xray/config.json"
    fi

    if [ ! -s "$XRAY_CONF" ]; then
        mkdir -p "$(dirname "$XRAY_CONF")"
        cat << 'CONF_EOF' > "$XRAY_CONF"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
CONF_EOF
        echo -e "${GREEN}已建立基礎設定檔 ($XRAY_CONF)。${NC}"
    fi
}

restart_service() {
    local action="$1"
    echo -e "${YELLOW}正在重新啟動相關服務...${NC}"
    if command -v rc-service >/dev/null 2>&1 || [ -f /etc/alpine-release ]; then
        rc-service xray $action 2>/dev/null || true
        rc-service gttc-ping $action 2>/dev/null || true
    else
        systemctl $action xray 2>/dev/null || systemctl $action v2ray 2>/dev/null || true
        if [ "$action" = "restart" ] || [ "$action" = "start" ]; then
            systemctl enable gttc-ping.service >/dev/null 2>&1 || true
            systemctl restart gttc-ping.service >/dev/null 2>&1 || true
        else
            systemctl stop gttc-ping.service >/dev/null 2>&1 || true
            systemctl disable gttc-ping.service >/dev/null 2>&1 || true
        fi
    fi
}

enable_target_country() {
    echo ""
    echo "================================================="
    echo "          請選擇目標國家 / 地區"
    echo "================================================="
    echo " 1. 🇹🇼 台灣 (Taiwan)"
    echo " 2. 🇨🇳 中國大陸 (China)"
    echo " 3. 🇯🇵 日本 (Japan)"
    echo " 4. 🇲🇴 澳門 (Macao)"
    echo " 5. 🇺🇸 美國 (United States)"
    echo " 6. 🇬🇧 英國 (United Kingdom) [實驗性]"
    echo "================================================="
    read -p "請選擇 [1-6]: " c_choice

    # DOH_SERVER / ECS_IP serve IPv4 and dual-stack hosts; DOH_SERVER_V6 / ECS_IP6
    # serve IPv6-only hosts (literal DoH address, so no resolver bootstrap is
    # needed) and the IPv6 half of dual-stack hosts. Every IPv6 prefix was checked
    # against the RIR databases (logs/ecs-v6-verification-*.log).
    case "$c_choice" in
        1)
            COUNTRY_NAME="🇹🇼 台灣"
            DOH_SERVER="https://dns.google/dns-query"
            DOH_SERVER_V6="https://[2001:4860:4860::8888]/dns-query"
            ECS_IP="168.95.1.1/24"
            ECS_IP6="2403:a7c0::/32"
            LANG_HEADER="zh-TW,zh;q=0.9,en;q=0.8"
            ;;
        2)
            COUNTRY_NAME="🇨🇳 中國大陸"
            DOH_SERVER="https://dns.alidns.com/dns-query"
            DOH_SERVER_V6="https://[2400:3200::1]/dns-query"
            ECS_IP="114.240.0.0/16"
            ECS_IP6="240e::/32"
            LANG_HEADER="zh-CN,zh;q=0.9,en;q=0.8"
            ;;
        3)
            COUNTRY_NAME="🇯🇵 日本"
            DOH_SERVER="https://dns.google/dns-query"
            DOH_SERVER_V6="https://[2001:4860:4860::8888]/dns-query"
            ECS_IP="133.242.0.0/16"
            ECS_IP6="2001:7fa:7::/48"
            LANG_HEADER="ja-JP,ja;q=0.9,en;q=0.8"
            ;;
        4)
            COUNTRY_NAME="🇲🇴 澳門"
            DOH_SERVER="https://dns.google/dns-query"
            DOH_SERVER_V6="https://[2001:4860:4860::8888]/dns-query"
            ECS_IP="202.175.3.3/24"
            ECS_IP6="2402:e940:20::/43"
            LANG_HEADER="zh-MO,zh-TW;q=0.9,zh;q=0.8,en;q=0.7"
            ;;
        5)
            COUNTRY_NAME="🇺🇸 美國"
            DOH_SERVER="https://dns.google/dns-query"
            DOH_SERVER_V6="https://[2001:4860:4860::8888]/dns-query"
            ECS_IP="64.233.160.0/24"
            ECS_IP6="2600:8000::/24"
            LANG_HEADER="en-US,en;q=0.9"
            ;;
        6)
            # ECS 81.2.69.0/24: inside RIPE inetnum 81.2.64.0/18 (country GB, AS20712); see README
            # ECS 2001:8b0::/32: inside RIPE inet6num 2001:8b0::/29 (country GB, AS20712, Andrews & Arnold)
            COUNTRY_NAME="🇬🇧 英國"
            DOH_SERVER="https://dns.google/dns-query"
            DOH_SERVER_V6="https://[2001:4860:4860::8888]/dns-query"
            ECS_IP="81.2.69.0/24"
            ECS_IP6="2001:8b0::/32"
            LANG_HEADER="en-GB,en;q=0.9"
            ;;
        *)
            echo -e "${RED}無效選擇，取消操作！${NC}"
            return
            ;;
    esac

    detect_net_stack
    echo -e "${YELLOW}網路堆疊檢測結果：$(net_stack_label)${NC}"

    find_config
    if [ -z "$XRAY_CONF" ]; then
        XRAY_CONF="/etc/xray/config.json"
    fi

    if [ ! -f "$XRAY_CONF" ]; then
        echo -e "${RED}錯誤：未找到設定檔，請先執行安裝！${NC}"
        return
    fi

    cp "$XRAY_CONF" "${XRAY_CONF}.bak"

    GTTC_CONF="$XRAY_CONF" GTTC_STACK="$NET_STACK" \
    GTTC_DOH="$DOH_SERVER" GTTC_DOH6="$DOH_SERVER_V6" GTTC_ECS="$ECS_IP" GTTC_ECS6="$ECS_IP6" \
    GTTC_FALLBACK="$(fallback_dns_json enable)" python3 -c '
import json
import os

env = os.environ
conf_path = env["GTTC_CONF"]
with open(conf_path, "r") as f:
    data = json.load(f)

domains = [
    "geosite:google",
    "domain:google.com",
    "domain:googleapis.com",
    "domain:gstatic.com",
    "domain:gvt1.com",
    "domain:1e100.net",
    "domain:location.services"
]

def country_server(address, subnet):
    return {"address": address, "clientSubnet": subnet, "domains": domains}

# IPv6-only: literal IPv6 DoH + IPv6 ECS. Dual-stack: one entry per family, IPv4
# first (Xray falls through to the next matching server). Otherwise IPv4 only.
stack = env["GTTC_STACK"]
if stack == "ipv6":
    country = [country_server(env["GTTC_DOH6"], env["GTTC_ECS6"])]
elif stack == "dual":
    country = [country_server(env["GTTC_DOH"], env["GTTC_ECS"]),
               country_server(env["GTTC_DOH"], env["GTTC_ECS6"])]
else:
    country = [country_server(env["GTTC_DOH"], env["GTTC_ECS"])]

data["dns"] = {"servers": country + json.loads(env["GTTC_FALLBACK"])}

if "routing" not in data:
    data["routing"] = {}
data["routing"]["domainStrategy"] = "IPIfNonMatch"

with open(conf_path, "w") as f:
    json.dump(data, f, indent=2)
'

    create_ping_service "$LANG_HEADER"
    echo "$COUNTRY_NAME" > "$CONFIG_TAG_FILE"
    restart_service "restart"

    echo -e "${GREEN}✅ 已成功開啟 Google 定位重新導向 -> [${COUNTRY_NAME}]！${NC}"
    echo -e "${GREEN}✅ 核心服務已重新載入設定，背景保活服務已啟動（網路堆疊：$(net_stack_label)）。${NC}"
}

disable_target_country() {
    find_config
    if [ -z "$XRAY_CONF" ]; then
        XRAY_CONF="/etc/xray/config.json"
    fi

    if [ ! -f "$XRAY_CONF" ]; then
        echo -e "${RED}錯誤：未找到設定檔！${NC}"
        return
    fi

    cp "$XRAY_CONF" "${XRAY_CONF}.bak"

    # Restore resolvers that are reachable over this host's stack (an IPv6-only
    # host must not be handed back IPv4-only resolvers).
    detect_net_stack
    GTTC_CONF="$XRAY_CONF" GTTC_FALLBACK="$(fallback_dns_json disable)" python3 -c '
import json
import os

conf_path = os.environ["GTTC_CONF"]
with open(conf_path, "r") as f:
    data = json.load(f)

data["dns"] = {"servers": json.loads(os.environ["GTTC_FALLBACK"])}

with open(conf_path, "w") as f:
    json.dump(data, f, indent=2)
'
    rm -f "$CONFIG_TAG_FILE"
    restart_service "stop"

    echo -e "${GREEN}✅ 已成功關閉重新導向模式，恢復預設國際解析！${NC}"
}

show_menu() {
    check_warp
    show_banner
    echo "================================================="
    echo -e "       GoogleToThisCountry (GTTC) 管理腳本   "
    echo -e "       目前模式狀態: $(check_status)"
    echo "================================================="
    echo -e " 1. ${GREEN}開啟/切換 目標國家重新導向 (多維發包 + EDNS 宣告)${NC}"
    echo -e " 2. ${RED}關閉重新導向模式${NC}"
    echo -e " 3. ${YELLOW}一鍵安裝/修復 核心服務與相依環境${NC}"
    echo " 0. 退出腳本"
    echo "================================================="
    echo -e " 💡 提示：後續可在命令列直接輸入 ${GREEN}gttc${NC} 呼出本選單"
    echo "================================================="
    read -p "請選擇選項 [0-3]: " choice

    case "$choice" in
        1)
            enable_target_country
            ;;
        2)
            disable_target_country
            ;;
        3)
            install_core
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}無效選項，請重新輸入！${NC}"
            show_menu
            ;;
    esac
}

check_warp
install_core
show_menu
