#!/bin/bash

export LANG=en_US.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "amazon linux" "fedora")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install")

IPTABLES_NAT_COMMENT="hy2-port-hop"
IPTABLES_INPUT_COMMENT="hy2-udp-input"
PORT_STATE_FILE="/etc/hysteria/port_state.conf"

# 脚本仓库地址（更新和 hy2 重装使用）
REPO_URL="https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh"

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

iptables_do() {
    local bin="$1"
    shift
    if has_cmd "$bin"; then
        "$bin" -w 5 "$@" 2>/dev/null || "$bin" "$@" 2>/dev/null
    else
        return 1
    fi
}

is_ipv4() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv6() {
    [[ $1 == *:* ]]
}

strip_url_scheme() {
    local v="$1"
    v="${v#http://}"
    v="${v#https://}"
    printf "%s" "$v"
}


[[ $EUID -ne 0 ]] && red "注意: 请在root用户下运行脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

SYS=""
for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

SYSTEM=""
int=0
for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        [[ -n $SYSTEM ]] && break
    fi
done

[[ -z $SYSTEM ]] && red "目前暂不支持你的VPS的操作系统！" && exit 1

if [[ -z $(type -P curl) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl
fi

# URL编码函数
urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="$c" ;;
            * ) printf -v o '%%%02X' "'$c" ;;
        esac
        encoded+="$o"
    done
    echo "$encoded"
}

# YAML 单引号字符串转义函数
yaml_escape() {
    local string="$1"
    string=${string//\'/\'\'}
    printf "'%s'" "$string"
}


# YAML 单引号字符串反转义函数
yaml_unescape() {
    local string="$1"
    string="${string#"${string%%[![:space:]]*}"}"
    string="${string%"${string##*[![:space:]]}"}"
    if [[ $string == \'*\' ]]; then
        string=${string:1:${#string}-2}
        string=${string//\'\'/\'}
    elif [[ $string == \"*\" ]]; then
        string=${string:1:${#string}-2}
    fi
    printf "%s" "$string"
}

# JSON 字符串转义函数
json_escape() {
    local string="$1"
    string=${string//\\/\\\\}
    string=${string//\"/\\\"}
    string=${string//$'\n'/\\n}
    string=${string//$'\r'/\\r}
    string=${string//$'\t'/\\t}
    string=${string//$'\b'/\\b}
    string=${string//$'\f'/\\f}
    printf "%s" "$string"
}

# 生成更高复杂度的随机密码
generate_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 32
}

is_number() {
    [[ $1 =~ ^[0-9]+$ ]]
}

valid_port() {
    is_number "$1" && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_hop_interval() {
    is_number "$1" && (( 10#$1 >= 5 ))
}

# 获取所有 UDP 监听端口列表（优先 ss，netstat 兜底，都没有返回空）
get_udp_ports() {
    if has_cmd ss; then
        ss -H -uln 2>/dev/null | awk '{print $5}' | sed 's/.*://g' | grep -E '^[0-9]+$' | sort -n | uniq
    elif has_cmd netstat; then
        netstat -uln 2>/dev/null | awk 'NR>2{print $4}' | sed 's/.*://g' | grep -E '^[0-9]+$' | sort -n | uniq
    else
        return 1
    fi
}

# 获取所有 TCP 监听端口列表（用于软提醒，UDP/TCP 不实际冲突）
get_tcp_ports() {
    if has_cmd ss; then
        ss -H -tln 2>/dev/null | awk '{print $4}' | sed 's/.*://g' | grep -E '^[0-9]+$' | sort -n | uniq
    elif has_cmd netstat; then
        netstat -tln 2>/dev/null | awk 'NR>2{print $4}' | sed 's/.*://g' | grep -E '^[0-9]+$' | sort -n | uniq
    else
        return 1
    fi
}

is_udp_port_in_use() {
    local check_port="$1"
    local used_ports
    if ! used_ports=$(get_udp_ports); then
        yellow "警告：未找到 ss/netstat，无法检测端口占用，请手动确认 UDP $check_port 未被占用。"
        return 1
    fi
    [[ -z "$used_ports" ]] && return 1
    grep -wq "$check_port" <<< "$used_ports" 2>/dev/null
}

# 软提醒：端口同时被 TCP 占用时提示（不阻塞，因为 UDP/TCP 不冲突）
warn_if_tcp_in_use() {
    local check_port="$1"
    local tcp_ports
    if ! tcp_ports=$(get_tcp_ports); then
        return 0
    fi
    [[ -z "$tcp_ports" ]] && return 0
    if grep -wq "$check_port" <<< "$tcp_ports" 2>/dev/null; then
        yellow "提示：TCP $check_port 也被占用（UDP/TCP 不冲突，可继续；如感困惑可换其他 UDP 端口）。"
    fi
}

check_udp_range_conflict() {
    local start="$1"
    local end="$2"
    local p
    local conflicts=()
    local used_ports=""

    # 一次性获取所有 UDP 监听端口列表，避免逐个端口调用 ss（1000 端口范围时性能提升显著）
    if ! used_ports=$(get_udp_ports); then
        yellow "警告：未找到 ss/netstat，无法检测端口范围占用，请手动确认范围空闲。"
        return 0
    fi
    [[ -z "$used_ports" ]] && return 0

    for ((p=start; p<=end; p++)); do
        if grep -wq "$p" <<< "$used_ports" 2>/dev/null; then
            conflicts+=("$p")
            [[ ${#conflicts[@]} -ge 8 ]] && break
        fi
    done

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        red "端口范围内发现 UDP 端口已被占用：${conflicts[*]}"
        red "端口跳跃会接管整个范围，请更换一个完全空闲的范围。"
        return 1
    fi

    return 0
}

# 进入端口配置前打印当前 UDP 占用情况，方便用户选端口
show_udp_port_usage() {
    local used_udp
    if ! used_udp=$(get_udp_ports); then
        yellow "提示：未找到 ss/netstat，无法列出已占用端口。"
        return 0
    fi
    if [[ -z "$used_udp" ]]; then
        green "当前无 UDP 端口被占用，可自由选择。"
    else
        local count
        count=$(echo "$used_udp" | wc -l)
        yellow "当前已占用 UDP 端口（共 $count 个）："
        # 最多显示前 20 个，避免刷屏
        echo "$used_udp" | head -20 | tr '\n' ' '
        echo ""
        [[ $count -gt 20 ]] && yellow "  ...及其他 $((count-20)) 个，详见 ss -uln"
    fi
}

remove_rules_by_comment() {
    local bin="$1"
    local table="$2"
    local chain="$3"
    local comment="$4"
    local line
    local count=0

    if ! has_cmd "$bin"; then
        return 0
    fi

    while true; do
        if [[ -n "$table" ]]; then
            line=$("$bin" -t "$table" -L "$chain" --line-numbers -n -v 2>/dev/null | grep -F "$comment" | awk '{print $1}' | head -n 1)
        else
            line=$("$bin" -L "$chain" --line-numbers -n -v 2>/dev/null | grep -F "$comment" | awk '{print $1}' | head -n 1)
        fi

        [[ -z "$line" ]] && break

        if [[ -n "$table" ]]; then
            "$bin" -t "$table" -D "$chain" "$line" >/dev/null 2>&1 || break
        else
            "$bin" -D "$chain" "$line" >/dev/null 2>&1 || break
        fi

        ((count++))
        [[ $count -gt 100 ]] && break
    done
}

remove_hy2_iptables_rules() {
    remove_rules_by_comment iptables nat PREROUTING "$IPTABLES_NAT_COMMENT"
    remove_rules_by_comment ip6tables nat PREROUTING "$IPTABLES_NAT_COMMENT"
    remove_rules_by_comment iptables "" INPUT "$IPTABLES_INPUT_COMMENT"
    remove_rules_by_comment ip6tables "" INPUT "$IPTABLES_INPUT_COMMENT"
}

add_udp_input_rule() {
    local range="$1"
    local ok=1

    iptables_do iptables -I INPUT -p udp --dport "$range" -m comment --comment "$IPTABLES_INPUT_COMMENT" -j ACCEPT && ok=0
    iptables_do ip6tables -I INPUT -p udp --dport "$range" -m comment --comment "$IPTABLES_INPUT_COMMENT" -j ACCEPT && ok=0

    return "$ok"
}

add_port_hop_redirect_rule() {
    local range="$1"
    local target_port="$2"
    local ok=1

    iptables_do iptables -t nat -A PREROUTING -p udp --dport "$range" -m comment --comment "$IPTABLES_NAT_COMMENT" -j REDIRECT --to-ports "$target_port" && ok=0
    iptables_do ip6tables -t nat -A PREROUTING -p udp --dport "$range" -m comment --comment "$IPTABLES_NAT_COMMENT" -j REDIRECT --to-ports "$target_port" && ok=0

    return "$ok"
}

save_port_state() {
    mkdir -p /etc/hysteria
    cat > "$PORT_STATE_FILE" << EOF
PORT='$port'
FIRSTPORT='$firstport'
ENDPORT='$endport'
HOP_INTERVAL='$hop_interval'
MIN_HOP_INTERVAL='$min_hop_interval'
MAX_HOP_INTERVAL='$max_hop_interval'
OBFS_TYPE='$obfs_type'
OBFS_PASSWORD='$obfs_password'
EOF
    chmod 600 "$PORT_STATE_FILE"
}

load_port_state() {
    if [[ -f "$PORT_STATE_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$PORT_STATE_FILE"
        port="$PORT"
        firstport="$FIRSTPORT"
        endport="$ENDPORT"
        hop_interval="$HOP_INTERVAL"
        min_hop_interval="$MIN_HOP_INTERVAL"
        max_hop_interval="$MAX_HOP_INTERVAL"
        obfs_type="$OBFS_TYPE"
        obfs_password="$OBFS_PASSWORD"
        return 0
    fi
    return 1
}

grant_traverse_permission() {
    local target_path="$1"
    local dir
    local current_path=""
    local part

    dir=$(dirname "$target_path")
    IFS='/' read -ra path_parts <<< "$dir"
    for part in "${path_parts[@]}"; do
        [[ -z "$part" ]] && continue
        current_path="$current_path/$part"
        if id "hysteria" &>/dev/null && has_cmd setfacl; then
            setfacl -m u:hysteria:--x "$current_path" 2>/dev/null || true
        else
            chmod o+x "$current_path" 2>/dev/null || true
        fi
    done
}

grant_cert_read_permissions() {
    local cert_file="$1"
    local key_file="$2"
    local real_cert_path
    local real_key_path

    real_cert_path=$(readlink -f "$cert_file" 2>/dev/null || echo "$cert_file")
    real_key_path=$(readlink -f "$key_file" 2>/dev/null || echo "$key_file")

    grant_traverse_permission "$real_cert_path"
    grant_traverse_permission "$real_key_path"

    if id "hysteria" &>/dev/null && has_cmd setfacl; then
        setfacl -m u:hysteria:r "$real_cert_path" "$real_key_path" 2>/dev/null || true
        setfacl -d -m u:hysteria:r "$(dirname "$real_cert_path")" 2>/dev/null || true
        setfacl -d -m u:hysteria:r "$(dirname "$real_key_path")" 2>/dev/null || true
    elif id "hysteria" &>/dev/null; then
        chgrp hysteria "$real_cert_path" "$real_key_path" 2>/dev/null || true
        chmod g+r "$real_cert_path" "$real_key_path" 2>/dev/null || true
    else
        chmod o+r "$real_cert_path" "$real_key_path" 2>/dev/null || true
    fi

    # 最大兼容兜底：如果没有 setfacl/chgrp 或续签后新文件未继承 ACL，仍允许服务读取。
    # 这里不复制、不搬运证书，只对原路径授予读取权限。
    chmod o+r "$real_cert_path" "$real_key_path" 2>/dev/null || true
}


install_cert_permission_helper() {
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/hy2-fix-cert-perms <<'EOS'
#!/bin/bash

CONFIG_FILE="/etc/hysteria/config.yaml"

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

yaml_unescape_local() {
    local string="$1"
    string="${string#"${string%%[![:space:]]*}"}"
    string="${string%"${string##*[![:space:]]}"}"
    if [[ $string == \'*\' ]]; then
        string=${string:1:${#string}-2}
        string=${string//\'\'/\'}
    elif [[ $string == \"*\" ]]; then
        string=${string:1:${#string}-2}
    fi
    printf "%s" "$string"
}

grant_traverse_permission_local() {
    local target_path="$1"
    local dir
    local current_path=""
    local part

    dir=$(dirname "$target_path")
    IFS='/' read -ra path_parts <<< "$dir"
    for part in "${path_parts[@]}"; do
        [[ -z "$part" ]] && continue
        current_path="$current_path/$part"
        if id "hysteria" &>/dev/null && has_cmd setfacl; then
            setfacl -m u:hysteria:--x "$current_path" 2>/dev/null || true
        else
            chmod o+x "$current_path" 2>/dev/null || true
        fi
    done
}

grant_cert_read_permissions_local() {
    local cert_file="$1"
    local key_file="$2"
    local real_cert_path
    local real_key_path

    real_cert_path=$(readlink -f "$cert_file" 2>/dev/null || echo "$cert_file")
    real_key_path=$(readlink -f "$key_file" 2>/dev/null || echo "$key_file")

    [[ -f "$real_cert_path" && -f "$real_key_path" ]] || exit 0

    grant_traverse_permission_local "$real_cert_path"
    grant_traverse_permission_local "$real_key_path"

    if id "hysteria" &>/dev/null && has_cmd setfacl; then
        setfacl -m u:hysteria:r "$real_cert_path" "$real_key_path" 2>/dev/null || true
        setfacl -d -m u:hysteria:r "$(dirname "$real_cert_path")" 2>/dev/null || true
        setfacl -d -m u:hysteria:r "$(dirname "$real_key_path")" 2>/dev/null || true
    elif id "hysteria" &>/dev/null; then
        chgrp hysteria "$real_cert_path" "$real_key_path" 2>/dev/null || true
        chmod g+r "$real_cert_path" "$real_key_path" 2>/dev/null || true
    fi

    # 兼容优先：不搬运证书，直接确保原始目标文件可被服务读取。
    chmod o+r "$real_cert_path" "$real_key_path" 2>/dev/null || true
}

[[ -f "$CONFIG_FILE" ]] || exit 0
cert_path=$(yaml_unescape_local "$(grep "^[[:space:]]*cert:" "$CONFIG_FILE" | head -1 | sed 's/^[[:space:]]*cert:[[:space:]]*//')")
key_path=$(yaml_unescape_local "$(grep "^[[:space:]]*key:" "$CONFIG_FILE" | head -1 | sed 's/^[[:space:]]*key:[[:space:]]*//')")
[[ -n "$cert_path" && -n "$key_path" ]] || exit 0

grant_cert_read_permissions_local "$cert_path" "$key_path"
EOS
    chmod +x /usr/local/bin/hy2-fix-cert-perms

    # Certbot 续签后自动重新授权。这个 hook 不复制、不搬运证书，只重授读取权限。
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy 2>/dev/null || true
    if [[ -d /etc/letsencrypt/renewal-hooks/deploy ]]; then
        cat > /etc/letsencrypt/renewal-hooks/deploy/hy2-fix-cert-perms <<'EOS'
#!/bin/bash
/usr/local/bin/hy2-fix-cert-perms >/dev/null 2>&1 || true
systemctl try-restart hysteria-server >/dev/null 2>&1 || true
EOS
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/hy2-fix-cert-perms
    fi
}

install_management_command() {
    local src=""

    if [[ -n ${BASH_SOURCE[0]} && -f ${BASH_SOURCE[0]} ]]; then
        src="${BASH_SOURCE[0]}"
    elif [[ -f "$0" && "$0" != "bash" && "$0" != "-bash" ]]; then
        src="$0"
    fi

    if [[ -n "$src" ]]; then
        install -m 755 "$src" /usr/bin/hy2
        return $?
    fi

    # 管道运行（bash <(curl ...)）或 /dev/fd/ 等无物理文件的情况
    # 从 GitHub 重新下载一份作为管理命令
    green "检测到脚本通过管道运行，正在从仓库获取脚本以安装管理命令..."

    if command -v curl &>/dev/null; then
        curl -sL -o /usr/bin/hy2 "$REPO_URL" && chmod 755 /usr/bin/hy2
    elif command -v wget &>/dev/null; then
        wget -qO /usr/bin/hy2 "$REPO_URL" && chmod 755 /usr/bin/hy2
    fi

    if [[ -f /usr/bin/hy2 && -s /usr/bin/hy2 ]]; then
        green "管理命令 hy2 安装成功！"
        return 0
    else
        rm -f /usr/bin/hy2
        red "无法自动写入 /usr/bin/hy2：下载失败。"
        red "安装完成后请手动执行以下命令："
        red "  curl -sL -o /usr/bin/hy2 $REPO_URL && chmod 755 /usr/bin/hy2"
        return 1
    fi
}

realip(){
    local url
    # IPv4 优先，多源 fallback 提高可靠性
    for url in "https://ip.sb" "https://api.ipify.org" "https://ifconfig.me"; do
        ip=$(curl -s4m5 "$url" -k 2>/dev/null | tr -d '\r\n[:space:]')
        [[ -n $ip ]] && return
    done
    # IPv6 兜底
    for url in "https://ip.sb" "https://api6.ipify.org"; do
        ip=$(curl -s6m5 "$url" -k 2>/dev/null | tr -d '\r\n[:space:]')
        [[ -n $ip ]] && return
    done
    red "无法获取服务器公网 IP，请检查网络。"
    exit 1
}

save_iptables_rules(){
    if [[ $SYSTEM == "CentOS" ]]; then
        if [[ -f /usr/libexec/iptables/iptables.init ]]; then
            service iptables save >/dev/null 2>&1
            service ip6tables save >/dev/null 2>&1
        else
            iptables-save > /etc/sysconfig/iptables 2>/dev/null
            ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null
        fi
    else
        netfilter-persistent save >/dev/null 2>&1
    fi
}

install_iptables_persistent(){
    if [[ $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_INSTALL[int]} iptables-services
        systemctl enable iptables >/dev/null 2>&1
        systemctl enable ip6tables >/dev/null 2>&1
        systemctl start iptables >/dev/null 2>&1
        systemctl start ip6tables >/dev/null 2>&1
    else
        # 非交互式安装 iptables-persistent
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null
        DEBIAN_FRONTEND=noninteractive ${PACKAGE_INSTALL[int]} iptables-persistent netfilter-persistent
    fi
}

fix_permissions(){
    if id "hysteria" &>/dev/null; then
        chown -R hysteria:hysteria /etc/hysteria
    fi
    chmod 755 /etc/hysteria
    if [[ -f /etc/hysteria/cert.crt ]]; then
        chmod 644 /etc/hysteria/cert.crt
    fi
    if [[ -f /etc/hysteria/private.key ]]; then
        chmod 600 /etc/hysteria/private.key
    fi
}

# 选择握手/伪装域名（推荐列表 + 自动测速 + 自定义）
# 选最优握手域名的原则：
#   1. 必须支持 HTTPS（TLS 握手特征要对得上）
#   2. 最好支持 HTTP/3 (QUIC)，因为 Hysteria 2 就是 QUIC，流量特征更接近
#   3. 国内可访问（否则 GFW 可能直接阻断该 SNI）
#   4. 是 HTTPS 大站，不敏感
#   5. 【关键】纯净度：与 AI/GitHub/Google 等敏感服务无关联，
#      用这些域名做 SNI 不会暴露你真实访问意图（AI/代码托管等）。
#      ❌ 绝对不要用 chat.openai.com / github.com / claude.ai / *.google.com 等
#         这些域名要么国内不可达，要么是 GFW 重点监控对象，用作 SNI 反而暴露意图。
select_sni() {
    # 推荐域名列表：均为常规大站，与 AI/GitHub 等敏感服务无关联
    # 字段：域名|HTTP/3|纯净度说明
    local sni_list=(
        "www.cloudflare.com|是|CDN基础设施，最纯净，与任何业务无关联，HTTP/3+全球CDN"
        "www.apple.com|是|硬件厂商官网，纯净，与 AI/GitHub 无关联"
        "www.microsoft.com|是|系统厂商官网，纯净，与 AI/GitHub 无关联"
        "www.bing.com|否|搜索引擎，纯净，但无 HTTP/3（特征匹配度略低）"
    )

    echo ""
    green "选择握手/伪装域名 (SNI)："
    echo -e "    ${PLAIN}说明：握手域名用于 TLS 伪装，让流量看起来像在访问该大站。"
    echo -e "    ${PLAIN}      选支持 HTTP/3 的大站效果最好（Hysteria 2 本身是 QUIC 协议）。"
    echo -e "    ${GREEN}    ★ 所有推荐域名均为常规大站，与 AI/GitHub/Google 等敏感服务无关联，"
    echo -e "      ${GREEN}不会暴露你真实的访问意图。${PLAIN}"
    echo -e "    ${RED}    ✗ 切勿使用 chat.openai.com / github.com / claude.ai / *.google.com 等，"
    echo -e "      ${RED}这些是 GFW 重点监控对象，用作 SNI 反而暴露意图。${PLAIN}"
    echo ""
    local i=1
    for item in "${sni_list[@]}"; do
        local domain="${item%%|*}"
        local rest="${item#*|}"
        local http3="${rest%%|*}"
        local desc="${rest##*|}"
        if [[ $i -eq 1 ]]; then
            echo -e " ${GREEN}${i}.${PLAIN} ${domain} ${YELLOW}（默认，推荐）${PLAIN}"
        else
            echo -e " ${GREEN}${i}.${PLAIN} ${domain}"
        fi
        echo -e "    ${PLAIN}HTTP/3: ${http3} | ${desc}"
        ((i++))
    done
    echo -e " ${GREEN}0.${PLAIN} 自动测速选最优 ${YELLOW}(检测各域名 HTTP/3 支持和延迟)${PLAIN}"
    echo -e " ${GREEN}99.${PLAIN} 自定义输入"
    echo ""
    read -rp "请输入选项 [0-4/99]（回车默认 1）: " sniChoice
    [[ -z $sniChoice ]] && sniChoice=1

    local result=""
    case $sniChoice in
        0)
            result=$(auto_test_sni "${sni_list[@]}")
            ;;
        99)
            read -rp "请输入握手/伪装域名：" result
            result=$(strip_url_scheme "$result")
            [[ -z $result ]] && result="www.cloudflare.com"
            ;;
        [1-9])
            local idx=$((sniChoice - 1))
            if [[ $idx -lt ${#sni_list[@]} ]]; then
                result="${sni_list[$idx]%%|*}"
            else
                result="www.cloudflare.com"
            fi
            ;;
        *)
            result="www.cloudflare.com"
            ;;
    esac

    printf "%s" "$result"
}

# 自动测速：检测各候选域名的 HTTP/3 支持和 HTTPS 连通延迟，返回最优
auto_test_sni() {
    local candidates=("$@")
    local best_domain=""
    local best_score=-1
    local domain http3 lat score

    yellow "正在检测候选域名（HTTP/3 支持 + HTTPS 延迟）..."
    printf "%-22s %-10s %-12s %s\n" "域名" "HTTP/3" "延迟(ms)" "评分"
    printf "%-22s %-10s %-12s %s\n" "------" "------" "--------" "----"

    for item in "${candidates[@]}"; do
        # 列表格式：域名|HTTP/3|说明，只取第一段域名
        domain="${item%%|*}"
        http3="否"
        lat="-"
        score=0

        # 检测 HTTP/3 支持（通过 alt-svc 头判断，无需 --http3 编译选项）
        local alt_svc
        alt_svc=$(curl -sI -m 5 "https://$domain" 2>/dev/null | grep -i "alt-svc:" | tr -d '\r')
        if [[ $alt_svc == *h3* ]]; then
            http3="是"
            score=$((score + 50))
        fi

        # 检测 HTTPS 连通延迟（TLS 握手完成时间，含 TCP+TLS，比 time_connect 更准确）
        local time_appconnect
        time_appconnect=$(curl -so /dev/null -w "%{time_appconnect}" -m 5 "https://$domain" 2>/dev/null)
        if [[ -n $time_appconnect && $time_appconnect != "0.000000" ]]; then
            # 延迟越低分越高（100ms=100分，500ms=20分，>1000ms=0分）
            local lat_ms
            lat_ms=$(awk "BEGIN{printf \"%d\", $time_appconnect * 1000}")
            lat="${lat_ms}ms"
            score=$((score + $(awk "BEGIN{printf \"%d\", ($lat_ms < 1000) ? (1000 - $lat_ms) / 10 : 0}")))
        else
            # 连不通直接 0 分
            score=0
            lat="超时"
        fi

        printf "%-22s %-10s %-12s %s\n" "$domain" "$http3" "$lat" "$score"

        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best_domain=$domain
        fi
    done

    echo ""
    if [[ -z $best_domain || $best_score -le 0 ]]; then
        yellow "检测失败或全部不通，使用默认 www.cloudflare.com"
        printf "%s" "www.cloudflare.com"
    else
        green "最优握手域名：$best_domain（评分 $best_score）"
        printf "%s" "$best_domain"
    fi
}

inst_cert(){
    mkdir -p /etc/hysteria

    green "请选择 Hysteria 2 协议的证书申请方式："
    echo ""

    echo -e " ${GREEN}1.${PLAIN} 使用自签证书 ${YELLOW}（默认，推荐）${PLAIN}"
    echo -e "    ${PLAIN}说明：TLS 加密完整，流量特征与标准 HTTPS 无异。适合没有域名的场景。"
    echo ""

    echo -e " ${GREEN}2.${PLAIN} 使用 ACME 脚本自动申请证书"
    echo -e "    ${PLAIN}说明：需要你拥有一个域名。脚本会自动申请并更新证书。"
    echo -e "          ${YELLOW}注意：请确保域名 DNS 已正确解析到本机 IP。${PLAIN}"
    echo ""

    echo -e " ${GREEN}3.${PLAIN} 使用本地已有的证书文件"
    echo -e "    ${PLAIN}说明：如果你已经拥有有效的证书文件 (crt/key)，请选择此项手动指定路径。"
    echo ""

    read -rp "请输入选项 [1-3]（回车默认 1）: " certInput
    [[ -z $certInput ]] && certInput=1

    if [[ $certInput == 2 ]]; then
        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        # ACME申请的证书是受信任的，不需要跳过验证
        insecure=0

        if [[ -f $cert_path && -f $key_path && -s $cert_path && -s $key_path ]] && [[ -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log)
            green "检测到原有域名：$domain 的证书，正在应用"
            hy_domain=$domain
        else
            WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
                wg-quick down wgcf >/dev/null 2>&1
                systemctl stop warp-go >/dev/null 2>&1
                trap 'systemctl start warp-go >/dev/null 2>&1; wg-quick up wgcf >/dev/null 2>&1' EXIT
                realip
                systemctl start warp-go >/dev/null 2>&1
                wg-quick up wgcf >/dev/null 2>&1
                trap - EXIT
            else
                realip
            fi

            read -rp "请输入需要申请证书的域名：" domain
            [[ -z $domain ]] && red "未输入域名，无法执行操作！" && exit 1
            green "已输入的域名：$domain" && sleep 1

            ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl acl
            if [[ $SYSTEM == "CentOS" ]]; then
                ${PACKAGE_INSTALL[int]} cronie
                systemctl start crond
                systemctl enable crond
            else
                ${PACKAGE_INSTALL[int]} cron
                systemctl start cron
                systemctl enable cron
            fi

            curl -fsSL https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com || {
                red "acme.sh 安装失败，请检查网络连接后重试"
                exit 1
            }
            source ~/.bashrc
            bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
            bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

            if [[ -n $(echo $ip | grep ":") ]]; then
                bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --listen-v6 --insecure
            else
                bash ~/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --insecure
            fi

            bash ~/.acme.sh/acme.sh --install-cert -d "${domain}" --key-file /etc/hysteria/private.key --fullchain-file /etc/hysteria/cert.crt --ecc --reloadcmd "chown hysteria:hysteria /etc/hysteria/cert.crt /etc/hysteria/private.key 2>/dev/null || true; chmod 644 /etc/hysteria/cert.crt 2>/dev/null || true; chmod 600 /etc/hysteria/private.key 2>/dev/null || true; systemctl try-restart hysteria-server >/dev/null 2>&1 || true"

            if [[ -f /etc/hysteria/cert.crt && -f /etc/hysteria/private.key ]] && [[ -s /etc/hysteria/cert.crt && -s /etc/hysteria/private.key ]]; then
                echo "$domain" > /root/ca.log
                install_cert_permission_helper
                sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
                echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab

                green "证书申请成功!"
                hy_domain=$domain
            else
                red "证书申请失败！"
                exit 1
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        read -rp "请输入公钥文件 crt 的路径：" cert_path
        read -rp "请输入密钥文件 key 的路径：" key_path
        read -rp "请输入证书的域名：" domain

        if [[ ! -f $cert_path ]]; then
            red "证书文件不存在：$cert_path"
            exit 1
        fi
        if [[ ! -f $key_path ]]; then
            red "密钥文件不存在：$key_path"
            exit 1
        fi

        # 不搬运、不复制证书：只对用户提供的原始证书路径授予 Hysteria 读取权限。
        grant_cert_read_permissions "$cert_path" "$key_path"
        install_cert_permission_helper

        hy_domain=$domain
        # 用户提供的证书默认是受信任的，不需要跳过验证
        insecure=0

        green "已授予 Hysteria 读取证书文件的权限"
    else
        green "将使用自签证书作为 Hysteria 2 的节点证书"

        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"

        # 选择握手/伪装域名（推荐列表，默认 cloudflare）
        custom_sni=$(select_sni)

        # 选择证书算法
        echo ""
        green "选择自签证书加密算法："
        echo -e " ${GREEN}1.${PLAIN} Ed25519 ${YELLOW}（默认，推荐）${PLAIN}"
        echo -e "    ${PLAIN}说明：现代椭圆曲线，密钥短、握手快、CPU 占用最低、强度高（256 位安全级）。"
        echo -e " ${GREEN}2.${PLAIN} prime256v1 (NIST P-256)"
        echo -e "    ${PLAIN}说明：兼容性最广，旧客户端/老内核支持更好（128 位安全级）。"
        echo -e " ${GREEN}3.${PLAIN} secp384r1 (NIST P-384)"
        echo -e "    ${PLAIN}说明：强度更高（192 位安全级），但握手和加解密稍慢，适合极端安全需求。"
        echo ""
        read -rp "请输入选项 [1-3]（回车默认 1）: " certAlgoInput
        [[ -z $certAlgoInput ]] && certAlgoInput=1

        if [[ $certAlgoInput == 2 ]]; then
            cert_algo="prime256v1"
            openssl ecparam -genkey -name prime256v1 -out "$key_path"
        elif [[ $certAlgoInput == 3 ]]; then
            cert_algo="secp384r1"
            openssl ecparam -genkey -name secp384r1 -out "$key_path"
        else
            cert_algo="Ed25519"
            openssl genpkey -algorithm Ed25519 -out "$key_path"
        fi

        openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=$custom_sni"

        hy_domain="$custom_sni"
        domain="$custom_sni"
        # 自签证书需要跳过验证
        insecure=1
        yellow "自签证书已生成（$cert_algo），握手/伪装域名：$custom_sni"
    fi
}

inst_port_config(){
    remove_hy2_iptables_rules

    echo ""
    green "请选择端口使用模式："
    echo -e " ${GREEN}1.${PLAIN} 端口跳跃 (Port Hopping)"
    echo -e "    ${PLAIN}说明：自动在多个端口间切换，有效对抗运营商针对性阻断和限速，连接更稳。"
    echo -e " ${GREEN}2.${PLAIN} 单端口模式 ${YELLOW}（默认，推荐）${PLAIN}"
    echo ""
    read -rp "请输入选项 [1-2]（回车默认 2）: " portMode
    [[ -z $portMode ]] && portMode=2

    # 进入端口输入前，展示当前 UDP 占用情况，方便用户选端口
    echo ""
    show_udp_port_usage
    echo ""

    if [[ $portMode == 2 ]]; then
        while true; do
            read -rp "设置 Hysteria 2 端口 [1-65535]（回车默认 443）：" port
            [[ -z $port ]] && port=443

            if ! valid_port "$port"; then
                red "端口必须是 1-65535 之间的数字！"
                continue
            fi
            port=$((10#$port))

            if is_udp_port_in_use "$port"; then
                echo -e "${RED} $port ${PLAIN} UDP 端口已被占用，请更换！"
                continue
            fi

            # TCP 软提醒（不阻塞，UDP/TCP 不实际冲突）
            warn_if_tcp_in_use "$port"

            break
        done

        firstport=""
        endport=""
        hop_interval=""
        min_hop_interval=""
        max_hop_interval=""

        if ! add_udp_input_rule "$port"; then
            yellow "警告：未能自动添加防火墙放行规则，请确认服务器安全组/防火墙已放行 UDP $port。"
        fi
        save_port_state
        save_iptables_rules

        yellow "Hysteria 2 将运行在单端口：$port"

    else
        green "已选择端口跳跃模式。"
        yellow "注意：请仔细检查服务器是否存在端口冲突（如Web服务的80/443等）。"
        yellow "推荐：范围大小约 1000 个端口，位于 30000-50000 高位区间。"
        echo ""

        while true; do
            read -rp "请输入起始端口/主端口 [建议30000-50000] (回车随机生成): " firstport
            [[ -z $firstport ]] && firstport=$(shuf -i 30000-50000 -n 1)

            if ! valid_port "$firstport"; then
                red "起始端口必须是 1-65535 之间的数字！"
                continue
            fi
            firstport=$((10#$firstport))

            if [[ $firstport -ge 65535 ]]; then
                red "端口跳跃模式下起始端口必须小于 65535！"
                continue
            fi

            if is_udp_port_in_use "$firstport"; then
                echo -e "${RED} $firstport ${PLAIN} UDP 端口已被占用，请更换！"
                continue
            fi

            # TCP 软提醒
            warn_if_tcp_in_use "$firstport"

            break
        done

        while true; do
            default_endport=$((firstport + 1000))
            [[ $default_endport -gt 65535 ]] && default_endport=65535
            read -rp "请输入结束端口 (回车默认为 起始端口+1000 -> $default_endport): " endport
            [[ -z $endport ]] && endport=$default_endport

            if ! valid_port "$endport"; then
                red "结束端口必须是 1-65535 之间的数字！"
                continue
            fi
            endport=$((10#$endport))

            if [[ $firstport -ge $endport ]]; then
                red "起始端口必须小于结束端口！"
                continue
            fi

            if ! check_udp_range_conflict "$firstport" "$endport"; then
                continue
            fi

            break
        done

        # 设置端口跳跃间隔
        echo ""
        green "请选择端口跳跃时间模式："
        echo -e " ${GREEN}1.${PLAIN} 固定跳跃时间 ${YELLOW}（默认）${PLAIN}"
        echo -e " ${GREEN}2.${PLAIN} 随机跳跃时间"
        echo -e "    ${YELLOW}注意：低版本的代理软件可能不支持随机跳跃时间，Xray 内核系列可能不支持。${PLAIN}"
        echo ""
        read -rp "请输入选项 [1-2]（回车默认 1）: " hopTimeMode
        [[ -z $hopTimeMode ]] && hopTimeMode=1

        if [[ $hopTimeMode == 2 ]]; then
            hop_interval=""
            while true; do
                read -rp "请输入最低跳跃时间秒数 [默认10]: " min_hop_interval
                [[ -z $min_hop_interval ]] && min_hop_interval=10
                read -rp "请输入最高跳跃时间秒数 [默认60]: " max_hop_interval
                [[ -z $max_hop_interval ]] && max_hop_interval=60

                if ! valid_hop_interval "$min_hop_interval"; then
                    red "最低跳跃时间必须是数字，且至少为 5 秒！"
                    continue
                fi
                min_hop_interval=$((10#$min_hop_interval))

                if ! is_number "$max_hop_interval"; then
                    red "最高跳跃时间必须是数字！"
                    continue
                fi
                max_hop_interval=$((10#$max_hop_interval))

                if [[ $max_hop_interval -le $min_hop_interval ]]; then
                    red "最高跳跃时间必须大于最低跳跃时间，不能等于或小于！"
                    continue
                fi

                break
            done
        else
            min_hop_interval=""
            max_hop_interval=""
            while true; do
                read -rp "请输入端口跳跃间隔秒数 [默认30]: " hop_interval
                [[ -z $hop_interval ]] && hop_interval=30

                if ! valid_hop_interval "$hop_interval"; then
                    red "端口跳跃间隔必须是数字，且至少为 5 秒！"
                    continue
                fi
                hop_interval=$((10#$hop_interval))

                break
            done
        fi

        port=$firstport

        if ! add_port_hop_redirect_rule "$firstport:$endport" "$port"; then
            red "端口跳跃转发规则添加失败，请确认 iptables/ip6tables 可用。"
            return 1
        fi
        if ! add_udp_input_rule "$firstport:$endport"; then
            yellow "警告：未能自动添加防火墙放行规则，请确认服务器安全组/防火墙已放行 UDP $firstport-$endport。"
        fi
        save_port_state
        save_iptables_rules

        if [[ -n $min_hop_interval && -n $max_hop_interval ]]; then
            yellow "端口跳跃设置完成：$firstport - $endport (主监听端口: $port, 随机跳跃间隔: ${min_hop_interval}-${max_hop_interval}s)"
        else
            yellow "端口跳跃设置完成：$firstport - $endport (主监听端口: $port, 跳跃间隔: ${hop_interval}s)"
        fi
    fi
}

inst_pwd(){
    read -rp "设置 Hysteria 2 密码（回车跳过为随机字符）：" auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(generate_password)
    yellow "使用在 Hysteria 2 节点的密码为：$auth_pwd"
}

inst_site(){
    echo ""
    green "设置 Hysteria 2 伪装形式："

    echo -e " ${GREEN}1.${PLAIN} 返回 403 Forbidden 页面 ${YELLOW}（默认，强烈推荐）${PLAIN}"
    echo -e "    ${PLAIN}说明：模拟 Nginx 私有服务器拒绝访问。${GREEN}性能最优，CPU占用最低，隐蔽性极佳。${PLAIN}"
    echo ""

    echo -e " ${GREEN}2.${PLAIN} 伪装成其他网页 (Proxy 模式)"
    echo -e "    ${PLAIN}说明：反代目标网站。${RED}不推荐！会消耗额外 CPU/带宽，容易被识别为跳板攻击，伪装效果往往不如静态页面。${PLAIN}"
    echo ""

    read -rp "请输入选项 [1-2]（回车默认 1）: " masqInput
    [[ -z $masqInput ]] && masqInput=1

    if [[ $masqInput == 2 ]]; then
        masq_type="proxy"
        read -rp "请输入 Hysteria 2 的伪装网站地址 （去除https://） [默认首尔大学]：" proxysite
        proxysite=$(strip_url_scheme "$proxysite")
        [[ -z $proxysite ]] && proxysite="en.snu.ac.kr"
        yellow "Hysteria 2 将伪装成：$proxysite (性能较低)"
    else
        masq_type="string"
        proxysite=""
        green "Hysteria 2 将使用 403 Forbidden 页面作为伪装 (性能最优)"
    fi
}

inst_bandwidth(){
    echo ""
    green "设置服务端带宽限制 (速度限制)："
    echo -e " ${GREEN}1.${PLAIN} 开启 100 Mbps 限制"
    echo -e "    ${PLAIN}说明：${GREEN}100M 对于 4K 视频绰绰有余。${PLAIN}保持带宽克制能降低被运营商 QoS 的风险。"
    echo -e " ${GREEN}2.${PLAIN} 不限制带宽 ${YELLOW}（默认，推荐）${PLAIN}"
    echo -e "    ${PLAIN}说明：带宽由客户端自控，客户端设多少跑多少。适合自用场景。"
    echo ""

    read -rp "请输入选项 [1-2]（回车默认 2）: " bwInput
    [[ -z $bwInput ]] && bwInput=2

    if [[ $bwInput == 2 ]]; then
        limit_bandwidth="no"
        bandwidth_value=""
        yellow "已选择：不限制带宽（客户端自控）"
    else
        limit_bandwidth="yes"
        bandwidth_value="100"
        yellow "已选择：限制服务端带宽为 100 Mbps (上下行)"
    fi
}

# 混淆加密配置（默认开启 Salamander，对新人零配置）
inst_obfs(){
    echo ""
    green "设置流量混淆加密 (抗识别/抗 QoS 限速)："
    echo -e " ${GREEN}1.${PLAIN} 开启 Salamander 混淆加密 ${YELLOW}（默认，强烈推荐）${PLAIN}"
    echo -e "    ${PLAIN}说明：在 QUIC/TLS 加密基础上，对 QUIC 包头再做一层 AES-CTR 流加密，"
    echo -e "    ${PLAIN}      ${GREEN}运营商完全看不出这是 QUIC 流量${PLAIN}，表现为完全随机 UDP 包，抗识别/抗封锁。"
    echo -e " ${GREEN}2.${PLAIN} 关闭混淆"
    echo -e "    ${PLAIN}说明：仅 QUIC 原生 TLS，若运营商不做深包检测时可关闭，性能差异可忽略。"
    echo ""

    read -rp "请输入选项 [1-2]（回车默认 1）: " obfsInput
    [[ -z $obfsInput ]] && obfsInput=1

    if [[ $obfsInput == 1 ]]; then
        obfs_type="salamander"
        read -rp "设置混淆密钥（回车自动生成）：" obfs_password
        [[ -z $obfs_password ]] && obfs_password=$(generate_password)
        yellow "混淆加密已开启，密钥：$obfs_password"
    else
        obfs_type=""
        obfs_password=""
        yellow "未开启混淆加密（仅 QUIC 原生 TLS 加密）"
    fi
}

generate_config(){
    # 如果已有配置，改前备份
    if [[ -f /etc/hysteria/config.yaml ]]; then
        local bak_file="/etc/hysteria/config.yaml.bak.$(date +%s)"
        cp /etc/hysteria/config.yaml "$bak_file" 2>/dev/null || true
        chmod 600 "$bak_file" 2>/dev/null || true
    fi

    mkdir -p /etc/hysteria

    yaml_cert_path=$(yaml_escape "$cert_path")
    yaml_key_path=$(yaml_escape "$key_path")
    yaml_auth_pwd=$(yaml_escape "$auth_pwd")
    yaml_proxy_url=$(yaml_escape "https://$proxysite")
    yaml_obfs_password=$(yaml_escape "$obfs_password")

    cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: $yaml_cert_path
  key: $yaml_key_path
  minVersion: tls1.3
  alpn:
    - h3
    - h2
    - http/1.1

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
  disablePathMTUDiscovery: false

auth:
  type: password
  password: $yaml_auth_pwd

EOF

    if [[ -n $obfs_type && -n $obfs_password ]]; then
        cat << EOF >> /etc/hysteria/config.yaml
obfs:
  type: $obfs_type
  salamander:
    password: $yaml_obfs_password

EOF
    fi

    if [[ $limit_bandwidth == "yes" ]]; then
        cat << EOF >> /etc/hysteria/config.yaml
bandwidth:
  up: ${bandwidth_value:-100} mbps
  down: ${bandwidth_value:-100} mbps

EOF
    fi

    cat << EOF >> /etc/hysteria/config.yaml
masquerade:
EOF
    if [[ $masq_type == "proxy" ]]; then
        cat << EOF >> /etc/hysteria/config.yaml
  type: proxy
  proxy:
    url: $yaml_proxy_url
    rewriteHost: true
EOF
    else
        cat << EOF >> /etc/hysteria/config.yaml
  type: string
  string:
    content: "<h1>403 Forbidden</h1><p>You don't have permission to access this resource.</p><hr><address>Nginx</address>"
    headers:
      Content-Type: text/html; charset=utf-8
      Server: nginx
    statusCode: 403
EOF
    fi
}

generate_client_config(){
    realip

    if [[ -n $firstport && -n $endport ]]; then
        server_port_string="$port,$firstport-$endport"
    else
        server_port_string=$port
    fi

    if [[ -n $(echo $ip | grep ":") ]]; then
        last_ip="[$ip]"
    else
        last_ip=$ip
    fi

    # 根据 insecure 变量设置布尔值
    if [[ $insecure == 1 ]]; then
        insecure_bool="true"
    else
        insecure_bool="false"
    fi

    mkdir -p /root/hy

    yaml_server=$(yaml_escape "$last_ip:$server_port_string")
    yaml_auth_pwd=$(yaml_escape "$auth_pwd")
    yaml_hy_domain=$(yaml_escape "$hy_domain")
    yaml_obfs_password=$(yaml_escape "$obfs_password")
    json_server=$(json_escape "$last_ip:$server_port_string")
    json_auth_pwd=$(json_escape "$auth_pwd")
    json_hy_domain=$(json_escape "$hy_domain")
    json_obfs_password=$(json_escape "$obfs_password")
    encoded_pwd=$(urlencode "$auth_pwd")
    encoded_sni=$(urlencode "$hy_domain")
    encoded_obfs=$(urlencode "$obfs_password")

    # 生成 YAML 客户端配置
    cat << EOF > /root/hy/hy-client.yaml
server: $yaml_server

auth: $yaml_auth_pwd

tls:
  sni: $yaml_hy_domain
  insecure: $insecure_bool
  alpn:
    - h3
    - h2
    - http/1.1

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

fastOpen: true

socks5:
  listen: 127.0.0.1:5678

EOF

    # 混淆加密配置
    if [[ -n $obfs_type && -n $obfs_password ]]; then
        cat << EOF >> /root/hy/hy-client.yaml
obfs:
  type: $obfs_type
  salamander:
    password: $yaml_obfs_password

EOF
    fi

    # 仅在端口跳跃模式下添加 transport 配置
    if [[ -n $firstport && -n $endport ]]; then
        cat << EOF >> /root/hy/hy-client.yaml
transport:
  type: udp
  udp:
EOF
        if [[ -n $min_hop_interval && -n $max_hop_interval ]]; then
            cat << EOF >> /root/hy/hy-client.yaml
    minHopInterval: ${min_hop_interval:-10}s
    maxHopInterval: ${max_hop_interval:-60}s
EOF
        else
            cat << EOF >> /root/hy/hy-client.yaml
    hopInterval: ${hop_interval:-30}s
EOF
        fi
    fi

    # 生成 JSON 配置（用变量构建 transport 和 obfs 字段）
    json_transport=""
    if [[ -n $firstport && -n $endport ]]; then
        if [[ -n $min_hop_interval && -n $max_hop_interval ]]; then
            json_transport=',"transport":{"type":"udp","udp":{"minHopInterval":"'"${min_hop_interval:-10}"'s","maxHopInterval":"'"${max_hop_interval:-60}"'s"}}'
        else
            json_transport=',"transport":{"type":"udp","udp":{"hopInterval":"'"${hop_interval:-30}"'s"}}'
        fi
    fi

    json_obfs=""
    if [[ -n $obfs_type && -n $obfs_password ]]; then
        json_obfs=',"obfs":{"type":"'"$obfs_type"'","salamander":{"password":"'"$json_obfs_password"'"}}'
    fi

    cat << EOF > /root/hy/hy-client.json
{
  "server": "$json_server",
  "auth": "$json_auth_pwd",
  "tls": {
    "sni": "$json_hy_domain",
    "insecure": $insecure_bool,
    "alpn": ["h3","h2","http/1.1"]
  },
  "quic": {
    "initStreamReceiveWindow": 8388608,
    "maxStreamReceiveWindow": 8388608,
    "initConnReceiveWindow": 20971520,
    "maxConnReceiveWindow": 20971520,
    "maxIdleTimeout": "30s",
    "keepAlivePeriod": "10s"
  },
  "fastOpen": true,
  "socks5": {
    "listen": "127.0.0.1:5678"
  }$json_obfs$json_transport
}
EOF

    # 生成订阅链接 - 按照标准格式（含 obfs 参数）
    local url_params="security=tls&insecure=${insecure}&sni=${encoded_sni}"
    if [[ -n $obfs_type && -n $obfs_password ]]; then
        url_params="${url_params}&obfs=${obfs_type}&obfsParam=${encoded_obfs}"
    fi
    if [[ -n $firstport && -n $endport ]]; then
        if [[ -n $min_hop_interval && -n $max_hop_interval ]]; then
            url_params="${url_params}&mportHopInt=${min_hop_interval:-10}-${max_hop_interval:-60}&mport=${firstport}-${endport}"
        else
            url_params="${url_params}&mportHopInt=${hop_interval:-30}&mport=${firstport}-${endport}"
        fi
    fi
    url="hysteria2://${encoded_pwd}@${last_ip}:${port}?${url_params}#Hysteria2"

    echo "$url" > /root/hy/url.txt
}

read_current_config(){
    if [[ -f /etc/hysteria/config.yaml ]]; then
        # 端口解析：支持 ":443"、"0.0.0.0:443"、"[::]:443" 三种格式
        port=$(grep "^listen:" /etc/hysteria/config.yaml | sed 's/^listen:[[:space:]]*//' | sed 's/.*://')
        cert_path=$(yaml_unescape "$(grep "^[[:space:]]*cert:" /etc/hysteria/config.yaml | sed 's/^[[:space:]]*cert:[[:space:]]*//')")
        key_path=$(yaml_unescape "$(grep "^[[:space:]]*key:" /etc/hysteria/config.yaml | sed 's/^[[:space:]]*key:[[:space:]]*//')")
        auth_pwd=$(yaml_unescape "$(grep "^[[:space:]]*password:" /etc/hysteria/config.yaml | sed 's/^[[:space:]]*password:[[:space:]]*//')")

        if grep -q "type: proxy" /etc/hysteria/config.yaml; then
            masq_type="proxy"
            proxysite=$(yaml_unescape "$(grep "^[[:space:]]*url:" /etc/hysteria/config.yaml | sed 's/^[[:space:]]*url:[[:space:]]*//')")
            proxysite=$(echo "$proxysite" | sed 's#^https://##')
        else
            masq_type="string"
            proxysite=""
        fi

        if grep -q "bandwidth:" /etc/hysteria/config.yaml; then
            limit_bandwidth="yes"
            bandwidth_value=$(grep "up:" /etc/hysteria/config.yaml | head -1 | awk '{print $2}')
        else
            limit_bandwidth="no"
            bandwidth_value=""
        fi

        # 读取 obfs 混淆设置（必须限定在 obfs: 块内匹配，避免误读 auth.type / masquerade.type）
        if grep -q "^obfs:" /etc/hysteria/config.yaml; then
            # 用 awk 提取 obfs: 块的内容（从 ^obfs: 到下一个顶层 key 或文件末尾）
            local obfs_block
            obfs_block=$(awk '/^obfs:/{f=1;next} /^[a-zA-Z]/{f=0} f' /etc/hysteria/config.yaml)
            obfs_type=$(echo "$obfs_block" | grep "^[[:space:]]*type:" | awk '{print $2}')
            obfs_password=$(yaml_unescape "$(echo "$obfs_block" | grep "^[[:space:]]*password:" | sed 's/^[[:space:]]*password:[[:space:]]*//')")
        else
            obfs_type=""
            obfs_password=""
        fi

        if [[ -f /root/hy/hy-client.yaml ]]; then
            hy_domain=$(yaml_unescape "$(grep "^[[:space:]]*sni:" /root/hy/hy-client.yaml | sed 's/^[[:space:]]*sni:[[:space:]]*//')")
            # 读取跳跃间隔
            hop_interval=$(grep "hopInterval:" /root/hy/hy-client.yaml | awk '{print $2}' | sed 's/s$//')
            min_hop_interval=$(grep "minHopInterval:" /root/hy/hy-client.yaml | awk '{print $2}' | sed 's/s$//')
            max_hop_interval=$(grep "maxHopInterval:" /root/hy/hy-client.yaml | awk '{print $2}' | sed 's/s$//')
            # 读取 insecure 设置
            insecure_value=$(grep "insecure:" /root/hy/hy-client.yaml | awk '{print $2}')
            if [[ $insecure_value == "true" ]]; then
                insecure=1
            else
                insecure=0
            fi
        else
            hy_domain=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/.*CN = //;s/,.*//' | sed 's/.*CN=//;s/,.*//')
            [[ -z $hy_domain ]] && hy_domain="www.cloudflare.com"
            hop_interval=30
            min_hop_interval=""
            max_hop_interval=""
            # 通过 issuer==subject 判断自签证书（自签证书的颁发者=持有者）
            # 不再依赖域名判断，SNI 改成什么都能正确识别自签证书
            # 注意：openssl 输出带 "issuer=" / "subject=" 前缀，需去掉前缀再比较
            local cert_issuer cert_subject
            cert_issuer=$(openssl x509 -in "$cert_path" -noout -issuer 2>/dev/null | sed 's/^[a-zA-Z]*=//')
            cert_subject=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed 's/^[a-zA-Z]*=//')
            if [[ -n $cert_issuer && -n $cert_subject && $cert_issuer == "$cert_subject" ]]; then
                insecure=1
            else
                insecure=0
            fi
        fi

        # 优先读取脚本自己的端口状态文件（含 obfs 保存字段）
        if ! load_port_state; then
            port_hop_rule=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -F "$IPTABLES_NAT_COMMENT" | head -n 1)
            port_range=$(echo "$port_hop_rule" | sed -nE 's/.*--dport ([0-9]+):([0-9]+).*/\1:\2/p')
            if [[ -n $port_range ]]; then
                firstport=$(echo "$port_range" | cut -d: -f1)
                endport=$(echo "$port_range" | cut -d: -f2)
            else
                firstport=""
                endport=""
            fi
        fi

        return 0
    else
        return 1
    fi
}

insthysteria(){
    # 前置检测：已安装则提示（--reinstall / -f 跳过确认）
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        if [[ $FORCE_INSTALL != "1" ]]; then
            red "检测到 Hysteria 2 服务已在运行！"
            read -rp "是否覆盖安装？(y/N): " confirm
            [[ $confirm != "y" && $confirm != "Y" ]] && yellow "已取消安装" && exit 0
        fi
        systemctl stop hysteria-server
    fi

    # 获取服务器公网 IP（证书和客户端配置需要）
    realip

    if [[ $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_INSTALL[int]} curl wget sudo qrencode procps openssl iproute acl
    else
        ${PACKAGE_INSTALL[int]} curl wget sudo qrencode procps openssl iproute2 acl
    fi

    install_iptables_persistent

    bash <(curl -fsSL https://get.hy2.sh/)

    if [[ ! -f /usr/local/bin/hysteria ]]; then
        red "Hysteria 2 安装失败！"
        exit 1
    fi

    inst_cert
    inst_port_config
    inst_pwd
    inst_site
    inst_bandwidth
    inst_obfs
    generate_config
    generate_client_config

    fix_permissions

    systemctl daemon-reload
    systemctl enable hysteria-server

    echo "正在启动 Hysteria 2 服务..."
    systemctl start hysteria-server

    # 轮询等待服务就绪（最长 10 秒），比固定 sleep 更快
    local wait_ok=0
    for _ in {1..10}; do
        if systemctl is-active --quiet hysteria-server && [[ -f '/etc/hysteria/config.yaml' ]]; then
            wait_ok=1
            break
        fi
        sleep 1
    done

    if [[ $wait_ok -eq 1 ]]; then
        green "Hysteria 2 服务启动成功"
    else
        red "Hysteria 2 服务启动失败，请检查日志：journalctl -u hysteria-server -e" && exit 1
    fi
    green "======================================================================================"
    green "Hysteria 2 代理服务安装完成"

    green "======================================================================================"
    green "               管理命令：${YELLOW}hy2${GREEN} (直接输入 hy2 即可)"
    green "        输入 ${YELLOW}hy2${GREEN} 即可再次召唤本主界面，进行配置管理"
    green "======================================================================================"

    yellow "Hysteria 2 客户端 YAML 配置文件 hy-client.yaml 内容如下"
    green "$(cat /root/hy/hy-client.yaml)"
    yellow "Hysteria 2 客户端 JSON 配置文件 hy-client.json 内容如下"
    green "$(cat /root/hy/hy-client.json)"
    yellow "Hysteria 2 节点分享链接如下"
    green "$(cat /root/hy/url.txt)"
}

unsthysteria(){
    red "⚠️  确认卸载 Hysteria 2？此操作将删除所有配置文件和客户端信息！"
    read -rp "确认卸载？(y/N): " confirm
    [[ $confirm != "y" && $confirm != "Y" ]] && yellow "已取消卸载" && return

    systemctl stop hysteria-server.service >/dev/null 2>&1
    systemctl disable hysteria-server.service >/dev/null 2>&1
    rm -f /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service
    rm -f /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
    rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy /root/hysteria.sh
    rm -f /usr/bin/hy2 /usr/local/bin/hy2-fix-cert-perms /etc/letsencrypt/renewal-hooks/deploy/hy2-fix-cert-perms
    # 清理 acme.sh 的 crontab 条目（安装时添加到 /etc/crontab）
    sed -i '/acme\.sh --cron/d' /etc/crontab 2>/dev/null || true
    remove_hy2_iptables_rules
    save_iptables_rules
    systemctl daemon-reload
    green "Hysteria 2 已彻底卸载完成！"
}

starthysteria(){
    systemctl start hysteria-server
    systemctl enable hysteria-server >/dev/null 2>&1
    if systemctl is-active --quiet hysteria-server; then
        green "Hysteria 2 启动成功"
    else
        red "Hysteria 2 启动失败，请查看日志：journalctl -u hysteria-server -e"
        return 1
    fi
}

stophysteria(){
    systemctl stop hysteria-server
    systemctl disable hysteria-server >/dev/null 2>&1
    green "Hysteria 2 已停止"
}

hysteriaswitch(){
    yellow "请选择你需要的操作："
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 启动 Hysteria 2"
    echo -e " ${GREEN}2.${PLAIN} 关闭 Hysteria 2"
    echo -e " ${GREEN}3.${PLAIN} 重启 Hysteria 2"
    echo ""
    read -rp "请输入选项 [1-3]: " switchInput
    case $switchInput in
        1 ) starthysteria ;;
        2 ) stophysteria ;;
        3 ) stophysteria && starthysteria ;;
        * ) yellow "无效选项，请重新运行脚本" ;;
    esac
}

changebandwidth(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi

    echo ""
    green "请选择带宽限速模式："
    echo -e " ${GREEN}1.${PLAIN} 开启 100 Mbps 限制"
    echo -e " ${GREEN}2.${PLAIN} 自定义限速数值"
    echo -e " ${GREEN}3.${PLAIN} 关闭限速（客户端自控） ${YELLOW}（推荐）${PLAIN}"
    echo ""
    read -rp "请输入选项 [1-3]: " bwChange

    if [[ $bwChange == 1 ]]; then
        limit_bandwidth="yes"
        bandwidth_value="100"
        yellow "已设置为：100 Mbps 限速"
    elif [[ $bwChange == 2 ]]; then
        while true; do
            read -rp "请输入限速数值 (单位 mbps，例如 50): " custBw
            [[ -z $custBw ]] && custBw=100
            if ! is_number "$custBw" || (( 10#$custBw <= 0 )); then
                red "限速数值必须是正整数！"
                continue
            fi
            custBw=$((10#$custBw))
            break
        done
        limit_bandwidth="yes"
        bandwidth_value="$custBw"
        yellow "已设置为：$custBw Mbps 限速"
    else
        limit_bandwidth="no"
        bandwidth_value=""
        yellow "已关闭带宽限制"
    fi

    generate_config
    fix_permissions
    stophysteria && starthysteria
    green "带宽限制配置已更新！"
}

changeport(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    systemctl stop hysteria-server >/dev/null 2>&1
    inst_port_config
    generate_config
    generate_client_config
    fix_permissions
    starthysteria
    green "Hysteria 2 端口配置已更新！"
    showconf
}

changepasswd(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    read -rp "设置 Hysteria 2 密码（回车跳过为随机字符）：" new_pwd
    [[ -z $new_pwd ]] && new_pwd=$(generate_password)
    auth_pwd=$new_pwd
    generate_config
    generate_client_config
    fix_permissions
    stophysteria && starthysteria
    green "Hysteria 2 节点密码已成功修改为：$auth_pwd"
    showconf
}

change_cert(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    inst_cert
    generate_config
    generate_client_config
    fix_permissions
    stophysteria && starthysteria
    green "Hysteria 2 节点证书类型已成功修改"
    showconf
}

# 修改握手/伪装域名（仅适用于自签证书模式）
change_sni(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi

    yellow "当前握手域名：$hy_domain"
    yellow "注意：此功能仅适用于自签证书模式，将重新生成自签证书。"
    yellow "      如果你当前使用 ACME/自定义证书，请使用「修改证书类型」切换。"
    echo ""

    local new_sni
    new_sni=$(select_sni)

    if [[ $new_sni == "$hy_domain" ]]; then
        yellow "新域名与当前域名相同，已取消。"
        return 0
    fi

    # 重新生成自签证书（保持原有算法，默认 Ed25519）
    cert_path="/etc/hysteria/cert.crt"
    key_path="/etc/hysteria/private.key"
    mkdir -p /etc/hysteria

    # 检测现有证书算法，尽量保持一致
    # 统一用 openssl pkey 读取私钥信息（兼容 EC / Ed25519 / RSA）
    local existing_algo=""
    if [[ -f "$key_path" ]]; then
        local key_text
        key_text=$(openssl pkey -in "$key_path" -noout -text 2>/dev/null)
        if echo "$key_text" | grep -q "ED25519"; then
            existing_algo="Ed25519"
        elif echo "$key_text" | grep -q "ASN1 OID: prime256v1"; then
            existing_algo="prime256v1"
        elif echo "$key_text" | grep -q "ASN1 OID: secp384r1"; then
            existing_algo="secp384r1"
        fi
    fi
    local use_algo="${existing_algo:-Ed25519}"

    if [[ $use_algo == "prime256v1" ]]; then
        openssl ecparam -genkey -name prime256v1 -out "$key_path"
    elif [[ $use_algo == "secp384r1" ]]; then
        openssl ecparam -genkey -name secp384r1 -out "$key_path"
    else
        openssl genpkey -algorithm Ed25519 -out "$key_path"
    fi
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=$new_sni"

    hy_domain="$new_sni"
    domain="$new_sni"
    insecure=1

    generate_config
    generate_client_config
    fix_permissions
    stophysteria && starthysteria
    green "握手/伪装域名已修改为：$new_sni（证书算法：$use_algo）"
    showconf
}

changeproxysite(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    inst_site
    generate_config
    fix_permissions
    stophysteria && starthysteria
    green "Hysteria 2 节点伪装形式已修改成功！"
}

change_obfs(){
    if ! read_current_config; then
        red "未找到配置文件，请先安装 Hysteria 2"
        return 1
    fi
    if [[ -n $obfs_type ]]; then
        yellow "当前混淆加密：已开启 ($obfs_type)"
    else
        yellow "当前混淆加密：未开启（仅 QUIC 原生 TLS 加密）"
    fi
    inst_obfs
    save_port_state
    generate_config
    generate_client_config
    fix_permissions
    stophysteria && starthysteria
    green "混淆加密设置已更新！"
    showconf
}

changeconf(){
    green "Hysteria 2 配置变更选择如下:"
    echo -e " ${GREEN}1.${PLAIN} 修改端口 (重新配置)"
    echo -e " ${GREEN}2.${PLAIN} 修改密码"
    echo -e " ${GREEN}3.${PLAIN} 修改证书类型"
    echo -e " ${GREEN}4.${PLAIN} 修改伪装形式"
    echo -e " ${GREEN}5.${PLAIN} 编辑带宽限速"
    echo -e " ${GREEN}6.${PLAIN} 修改握手域名 ${YELLOW}(仅自签证书)${PLAIN}"
    echo -e " ${GREEN}7.${PLAIN} 修改混淆加密 ${YELLOW}(传输层再加密/抗识别)${PLAIN}"
    echo ""
    read -rp " 请选择操作 [1-7]：" confAnswer
    case $confAnswer in
        1 ) changeport ;;
        2 ) changepasswd ;;
        3 ) change_cert ;;
        4 ) changeproxysite ;;
        5 ) changebandwidth ;;
        6 ) change_sni ;;
        7 ) change_obfs ;;
        * ) yellow "无效选项，请重新运行脚本" ;;
    esac
}

showconf(){
    if [[ ! -f /root/hy/hy-client.yaml ]]; then
        red "未找到客户端配置文件，请先安装 Hysteria 2"
        return 1
    fi
    yellow "Hysteria 2 客户端 YAML 配置文件 hy-client.yaml 内容如下"
    green "$(cat /root/hy/hy-client.yaml)"
    yellow "Hysteria 2 客户端 JSON 配置文件 hy-client.json 内容如下"
    green "$(cat /root/hy/hy-client.json)"
    yellow "Hysteria 2 节点分享链接如下"
    green "$(cat /root/hy/url.txt)"
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#                  ${GREEN}Hysteria 2 一键安装脚本${PLAIN}                  #"
    echo "#############################################################"

    # 状态栏：显示运行状态、端口、核心版本（已安装时）
    if [[ -f /etc/hysteria/config.yaml ]]; then
        local status port_info version_info
        if systemctl is-active --quiet hysteria-server 2>/dev/null; then
            status="${GREEN}● 运行中${PLAIN}"
        else
            status="${RED}○ 未运行${PLAIN}"
        fi
        port_info=$(grep "^listen:" /etc/hysteria/config.yaml 2>/dev/null | sed 's/^listen:[[:space:]]*//')
        version_info=$(hysteria version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo -e "#  状态: $status | 端口: ${port_info:-未知} | 核心: ${version_info:-未知}"
    else
        echo -e "#  状态: ${YELLOW}未安装${PLAIN}"
    fi
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} ${GREEN}安装 Hysteria 2${PLAIN}"
    echo -e " ${RED}2.${PLAIN} ${RED}卸载 Hysteria 2${PLAIN}"
    echo " ------------------------------------------------------------"
    echo -e " 3. 关闭、开启、重启 Hysteria 2"
    echo -e " 4. 修改 Hysteria 2 配置"
    echo -e " 5. 显示 Hysteria 2 配置文件"
    echo -e " 6. 更新 Hysteria 2 核心"
    echo -e " 7. 更新脚本"
    echo " ------------------------------------------------------------"
    echo -e " 0. 退出脚本"
    echo ""
    read -rp "请输入选项 [0-7]: " menuInput
    case $menuInput in
        1 ) insthysteria ;;
        2 ) unsthysteria ;;
        3 ) hysteriaswitch ;;
        4 ) changeconf ;;
        5 ) showconf ;;
        6 ) update_core ;;
        7 ) update_script ;;
        0 ) exit 0 ;;
        * ) yellow "无效选项，请重新运行脚本" ;;
    esac
}

# 更新 Hysteria 2 核心
update_core() {
    if [[ ! -f /usr/local/bin/hysteria ]]; then
        red "未检测到 Hysteria 2 核心，请先安装。"
        return 1
    fi

    local old_version
    old_version=$(hysteria version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    yellow "当前 Hysteria 2 核心版本：${old_version:-未知}"
    echo ""
    read -rp "确认更新核心？(y/N): " confirm
    [[ $confirm != "y" && $confirm != "Y" ]] && yellow "已取消" && return 0

    yellow "正在更新 Hysteria 2 核心..."
    systemctl stop hysteria-server >/dev/null 2>&1

    bash <(curl -fsSL https://get.hy2.sh/)

    if [[ ! -f /usr/local/bin/hysteria ]]; then
        red "Hysteria 2 核心更新失败！"
        systemctl start hysteria-server >/dev/null 2>&1
        return 1
    fi

    systemctl start hysteria-server

    local new_version
    new_version=$(hysteria version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if systemctl is-active --quiet hysteria-server; then
        green "Hysteria 2 核心更新成功！"
        green "版本变化：${old_version:-未知} → ${new_version:-未知}"
    else
        red "更新后启动失败，请查看日志：journalctl -u hysteria-server -e"
        return 1
    fi
}

# 更新脚本
update_script() {
    local tmp_file="/tmp/hysteria-update.sh"

    yellow "正在检查脚本更新..."

    if command -v curl &>/dev/null; then
        curl -sL -o "$tmp_file" "$REPO_URL" || { red "下载失败"; return 1; }
    elif command -v wget &>/dev/null; then
        wget -qO "$tmp_file" "$REPO_URL" || { red "下载失败"; return 1; }
    else
        red "更新失败：未找到 curl 或 wget"
        return 1
    fi

    if [[ ! -f "$tmp_file" || ! -s "$tmp_file" ]]; then
        red "更新失败：无法从仓库获取脚本"
        return 1
    fi

    # 校验：确保下载的是 bash 脚本
    if ! head -1 "$tmp_file" | grep -qE '^#!/bin/bash'; then
        red "更新失败：下载的文件不是有效的脚本"
        rm -f "$tmp_file"
        return 1
    fi

    # 安装到 /usr/bin/hy2
    install -m 755 "$tmp_file" /usr/bin/hy2
    green "脚本更新成功！"

    # 如果当前目录有 hysteria.sh，一并更新
    if [[ -f ./hysteria.sh ]]; then
        cp "$tmp_file" ./hysteria.sh
        chmod +x ./hysteria.sh
        green "本地脚本 hysteria.sh 已同步更新"
    fi

    rm -f "$tmp_file"
    green "请重新运行脚本以使用最新版本。"
    exit 0
}

# 入口：参数解析
FORCE_INSTALL=0
case "$1" in
    --reinstall|-f)
        FORCE_INSTALL=1
        insthysteria
        rc=$?
        install_management_command
        exit $rc
        ;;
esac

# 入口：每次运行均同步管理命令到 /usr/bin/hy2
# 这样无论通过哪种方式更新脚本，下次运行 hy2 即是最新版
install_management_command

menu
