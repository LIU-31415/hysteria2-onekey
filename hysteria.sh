#!/usr/bin/env bash
# Hysteria 2 one-key installer for personal Linux VPS.

set -o pipefail
umask 077

readonly SCRIPT_VERSION="2.0.4"
readonly CORE_INSTALLER_URL="https://get.hy2.sh/"
readonly REPO_RAW_URL="https://raw.githubusercontent.com/LIU-31415/hysteria2-onekey/master/hysteria.sh"

if [[ "${HY2_TEST_MODE:-0}" == "1" ]]; then
    CONFIG_DIR="${HY2_CONFIG_DIR:-/etc/hysteria}"
    CONFIG_FILE="${HY2_CONFIG_FILE:-${CONFIG_DIR}/config.yaml}"
    STATE_FILE="${HY2_STATE_FILE:-${CONFIG_DIR}/installer-state.conf}"
    CERT_FILE="${HY2_CERT_FILE:-${CONFIG_DIR}/server.crt}"
    KEY_FILE="${HY2_KEY_FILE:-${CONFIG_DIR}/server.key}"
    CLIENT_DIR="${HY2_CLIENT_DIR:-/root/hy}"
    BACKUP_DIR="${HY2_BACKUP_DIR:-${CONFIG_DIR}/backups}"
    HYSTERIA_BIN="${HY2_BIN:-/usr/local/bin/hysteria}"
    MANAGEMENT_BIN="${HY2_MANAGEMENT_BIN:-/usr/bin/hy2}"
    SERVICE_NAME="${HY2_SERVICE_NAME:-hysteria-server.service}"
    SERVICE_FILE="${HY2_SERVICE_FILE:-/etc/systemd/system/hysteria-server.service}"
    SERVICE_TEMPLATE_FILE="${HY2_SERVICE_TEMPLATE_FILE:-/etc/systemd/system/hysteria-server@.service}"
    ACME_HOME="${HY2_ACME_HOME:-/root/.acme.sh}"
    HYSTERIA_HOME_DIR="${HY2_HYSTERIA_HOME_DIR:-/var/lib/hysteria}"
else
    CONFIG_DIR="/etc/hysteria"; CONFIG_FILE="/etc/hysteria/config.yaml"
    STATE_FILE="/etc/hysteria/installer-state.conf"
    CERT_FILE="/etc/hysteria/server.crt"; KEY_FILE="/etc/hysteria/server.key"
    CLIENT_DIR="/root/hy"; BACKUP_DIR="/etc/hysteria/backups"
    HYSTERIA_BIN="/usr/local/bin/hysteria"; MANAGEMENT_BIN="/usr/bin/hy2"
    SERVICE_NAME="hysteria-server.service"; SERVICE_FILE="/etc/systemd/system/hysteria-server.service"
    SERVICE_TEMPLATE_FILE="/etc/systemd/system/hysteria-server@.service"
    ACME_HOME="/root/.acme.sh"; HYSTERIA_HOME_DIR="/var/lib/hysteria"
fi
CURRENT_CERT_FILE="$CERT_FILE"
CURRENT_KEY_FILE="$KEY_FILE"

PUBLIC_IP=""
SERVER_ADDRESS=""
SERVER_PORT="443"
AUTH_PASSWORD=""
OBFS_PASSWORD=""
CERT_MODE="ip-acme"
TLS_SNI=""
TLS_INSECURE="0"
TLS_PIN_SHA256=""
ACME_CHALLENGE_PORT=""
ACME_OWNED="0"
HYSTERIA_USER_OWNED="0"
HYSTERIA_CORE_OWNED="0"
FAILED_ACME_IDENTIFIER=""
TRANSACTION_DIR=""
TRANSACTION_ACTIVE="0"

if [[ -t 1 ]]; then
    C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[36m'; C_RESET='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

info() { printf '%b[信息]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
success() { printf '%b[完成]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[注意]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%b[错误]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { error "$*"; return 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }
has_valid_installer_state() {
    [[ -f "$STATE_FILE" && -n "$(state_get_from "$STATE_FILE" version 2>/dev/null || true)" ]]
}
managed_paths_are_safe() {
    local path resolved
    for path in "$CONFIG_DIR" "$CLIENT_DIR" "$BACKUP_DIR"; do
        [[ ! -L "$path" ]] || return 1
        resolved="$(readlink -m -- "$path" 2>/dev/null)" || return 1
        [[ "$resolved" == "$path" ]] || return 1
    done
    for path in "$CONFIG_FILE" "$STATE_FILE" "$CERT_FILE" "$KEY_FILE"; do
        [[ ! -L "$path" ]] || return 1
    done
}
is_safe_tree_path() {
    local target="$1" resolved
    case "$target" in
        "$CONFIG_DIR"|"$CLIENT_DIR"|"$BACKUP_DIR"|"$ACME_HOME"|"$HYSTERIA_HOME_DIR"|/tmp/hy2-transaction.*|/tmp/hy2-certcheck.*) ;;
        *) return 1 ;;
    esac
    resolved="$(readlink -m -- "$target" 2>/dev/null)" || return 1
    [[ -n "$resolved" && ${#resolved} -ge 6 ]] || return 1
    case "$resolved" in /|/root|/etc|/usr|/var|/tmp) return 1 ;; esac
}
safe_remove_tree() {
    is_safe_tree_path "$1" || { error "拒绝删除不安全路径：$1"; return 1; }
    rm -rf -- "$1"
}

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

random_secret() {
    local length="${1:-24}"
    local value
    if has_cmd openssl; then
        value="$(openssl rand -hex $(((length + 1) / 2)))" || return 1
    else
        value="$(od -An -N "$length" -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 1
    fi
    printf '%s' "${value:0:length}"
}

valid_ipv4() {
    local ip="$1" part
    local -a parts=()
    local IFS='.'
    read -r -a parts <<<"$ip"
    [[ ${#parts[@]} -eq 4 ]] || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

valid_ipv6() {
    local ip="$1" left right group ipv4_tail
    local -a left_groups=() right_groups=() groups=()
    [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1

    if [[ "$ip" == *.* ]]; then
        ipv4_tail="${ip##*:}"
        valid_ipv4 "$ipv4_tail" || return 1
        ip="${ip%:*}:0:0"
    fi

    [[ "$ip" != *:::* ]] || return 1
    if [[ "$ip" == *::* ]]; then
        left="${ip%%::*}"
        right="${ip#*::}"
        [[ "$right" != *::* ]] || return 1
        [[ -z "$left" ]] || IFS=: read -r -a left_groups <<<"$left"
        [[ -z "$right" ]] || IFS=: read -r -a right_groups <<<"$right"
        ((${#left_groups[@]} + ${#right_groups[@]} < 8)) || return 1
        groups=("${left_groups[@]}" "${right_groups[@]}")
    else
        [[ "$ip" != :* && "$ip" != *: ]] || return 1
        IFS=: read -r -a groups <<<"$ip"
        ((${#groups[@]} == 8)) || return 1
    fi
    for group in "${groups[@]}"; do
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
}

valid_ip() { valid_ipv4 "$1" || valid_ipv6 "$1"; }
valid_hostname() {
    local name="$1"
    [[ ${#name} -le 253 && "$name" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_secret() {
    [[ -n "$1" && ${#1} -le 256 ]] || return 1
    ! printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

yaml_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    printf '"%s"' "$value"
}

yaml_unquote() {
    local value out="" char next i
    value="$(trim "$1")"
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
        for ((i=0; i<${#value}; i++)); do
            char="${value:i:1}"
            if [[ "$char" == '\' && $((i + 1)) -lt ${#value} ]]; then
                next="${value:i+1:1}"
                case "$next" in
                    n) out+=$'\n' ;;
                    '"') out+='"' ;;
                    '\') out+='\' ;;
                    *) out+="\\${next}" ;;
                esac
                i=$((i + 1))
            else
                out+="$char"
            fi
        done
        printf '%s' "$out"
    elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
        printf '%s' "${value//\'\'/\'}"
    else
        printf '%s' "$value"
    fi
}

uri_encode() {
    local input="$1" out="" byte char
    local -a bytes=()
    while read -r -a bytes; do
        for byte in "${bytes[@]}"; do
            case "$byte" in
                2d|2e|3[0-9]|4[1-9a-f]|5[0-9a]|5f|6[1-9a-f]|7[0-9a]|7e)
                    printf -v char '%b' "\\x${byte}"
                    out+="$char"
                    ;;
                *) out+="%${byte^^}" ;;
            esac
        done
    done < <(printf '%s' "$input" | od -An -v -tx1)
    printf '%s' "$out"
}

host_for_uri() {
    if valid_ipv6 "$1"; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

state_get_from() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$file"
}
state_get() { state_get_from "$STATE_FILE" "$1"; }
atomic_install_file() {
    local source="$1" target="$2" mode="${3:-600}" owner="${4:-root}" group="${5:-root}" temp
    mkdir -p "$(dirname "$target")" || return 1
    temp="${target}.new.$$"
    install -m "$mode" -o "$owner" -g "$group" "$source" "$temp" || { rm -f "$temp"; return 1; }
    mv -f "$temp" "$target" || { rm -f "$temp"; return 1; }
}

require_root() {
    is_root || die "请使用 root 运行：sudo bash hysteria.sh"
}

detect_os() {
    [[ -r /etc/os-release ]] || die "无法识别系统，仅支持使用 systemd 的主流 Linux 发行版。"
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu|kali|linuxmint) PACKAGE_FAMILY="apt" ;;
        centos|rhel|almalinux|rocky|fedora|ol) PACKAGE_FAMILY="rpm" ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*) PACKAGE_FAMILY="apt" ;;
                *rhel*|*fedora*) PACKAGE_FAMILY="rpm" ;;
                *) die "暂不支持此系统：${PRETTY_NAME:-unknown}" ;;
            esac
            ;;
    esac
    has_cmd systemctl || die "此脚本需要 systemd。"
}

install_dependencies() {
    local missing=() cmd
    for cmd in curl openssl awk sed grep ss socat; do
        has_cmd "$cmd" || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) && return 0
    info "安装基础依赖：${missing[*]}"
    if [[ "$PACKAGE_FAMILY" == "apt" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y || return 1
        apt-get install -y curl ca-certificates openssl iproute2 gawk sed grep socat || return 1
    else
        local manager="dnf"; has_cmd dnf || manager="yum"
        "$manager" install -y curl ca-certificates openssl iproute gawk sed grep socat || return 1
    fi
}

check_crypto_capabilities() {
    local req_help x509_help
    req_help="$(openssl req -help 2>&1)" || true
    x509_help="$(openssl x509 -help 2>&1)" || true
    if [[ "$req_help" != *"-addext"* || "$x509_help" != *"-checkip"* ]]; then
        error "OpenSSL 版本过旧；请使用带 OpenSSL 1.1.1+ 的受支持系统。"
        return 1
    fi
}

fetch_public_ip() {
    local candidate family url
    for family in 4 6; do
        for url in https://api64.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
            candidate="$(curl -"$family"fsS --connect-timeout 4 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')" || true
            if valid_ip "$candidate"; then
                PUBLIC_IP="$candidate"
                return 0
            fi
        done
    done
    return 1
}

ensure_hysteria_user() {
    if ! id hysteria >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin hysteria || return 1
    fi
}

download_checked_script() {
    local url="$1" output="$2"
    curl -fL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$output" || return 1
    [[ "$(head -n 1 "$output")" == '#!'* ]] || { error "下载内容不是脚本：$url"; return 1; }
    bash -n "$output" || { error "下载脚本语法检查失败：$url"; return 1; }
    chmod 700 "$output"
}

install_hysteria_core() {
    local installer
    installer="$(mktemp /tmp/hy2-core-installer.XXXXXX)" || return 1
    if ! download_checked_script "$CORE_INSTALLER_URL" "$installer"; then
        rm -f "$installer"
        return 1
    fi
    info "安装 Hysteria 2 官方内核"
    bash "$installer" || { rm -f "$installer"; return 1; }
    rm -f "$installer"
    [[ -x "$HYSTERIA_BIN" ]] || die "官方安装完成，但未找到内核：$HYSTERIA_BIN"
}

ensure_service_unit() {
    ensure_hysteria_user || return 1
    mkdir -p "$CONFIG_DIR" || return 1
    cat >"${SERVICE_FILE}.new" <<EOF || return 1
[Unit]
Description=Hysteria 2 Server
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria
ExecStart=${HYSTERIA_BIN} server -c ${CONFIG_FILE}
WorkingDirectory=${CONFIG_DIR}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF
    [[ -s "${SERVICE_FILE}.new" ]] || return 1
    chmod 644 "${SERVICE_FILE}.new" || return 1
    mv -f "${SERVICE_FILE}.new" "$SERVICE_FILE" || return 1
    if has_cmd restorecon; then restorecon -F "$SERVICE_FILE" >/dev/null 2>&1 || true; fi
    systemctl daemon-reload || return 1
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
}

secure_files() {
    mkdir -p "$CONFIG_DIR" "$CLIENT_DIR" "$BACKUP_DIR" || return 1
    chown root:hysteria "$CONFIG_DIR" "$BACKUP_DIR" || return 1
    chown root:root "$CLIENT_DIR" || return 1
    chmod 750 "$CONFIG_DIR" "$BACKUP_DIR" || return 1
    chmod 700 "$CLIENT_DIR" || return 1
    if [[ -f "$CONFIG_FILE" ]]; then chown root:hysteria "$CONFIG_FILE" && chmod 640 "$CONFIG_FILE" || return 1; fi
    if [[ -f "$CERT_FILE" ]]; then chown root:hysteria "$CERT_FILE" && chmod 640 "$CERT_FILE" || return 1; fi
    if [[ -f "$KEY_FILE" ]]; then chown root:hysteria "$KEY_FILE" && chmod 640 "$KEY_FILE" || return 1; fi
    if [[ -f "$STATE_FILE" ]]; then chmod 600 "$STATE_FILE" || return 1; fi
    find "$CLIENT_DIR" -maxdepth 1 -type f -exec chown root:root {} + -exec chmod 600 {} + || return 1
    if has_cmd restorecon; then restorecon -RF "$CONFIG_DIR" >/dev/null 2>&1 || true; fi
    return 0
}

remove_legacy_crontab_entry() {
    local crontab_file="/etc/crontab" temp exact mode owner group
    [[ -f "$crontab_file" ]] || return 0
    exact="0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1"
    grep -Fqx "$exact" "$crontab_file" || return 0
    temp="$(mktemp /tmp/hy2-crontab.XXXXXX)" || return 1
    grep -Fvx "$exact" "$crontab_file" >"$temp" || true
    mode="$(stat -c %a "$crontab_file")" || { rm -f "$temp"; return 1; }
    owner="$(stat -c %u "$crontab_file")" || { rm -f "$temp"; return 1; }
    group="$(stat -c %g "$crontab_file")" || { rm -f "$temp"; return 1; }
    atomic_install_file "$temp" "$crontab_file" "$mode" "$owner" "$group" || { rm -f "$temp"; return 1; }
    rm -f "$temp"
    if has_cmd restorecon; then restorecon -F "$crontab_file" >/dev/null 2>&1 || true; fi
}

cleanup_legacy_artifacts() {
    remove_legacy_crontab_entry || true
    rm -f /usr/local/bin/hy2-fix-cert-perms \
        /etc/letsencrypt/renewal-hooks/deploy/hy2-fix-cert-perms
}

snapshot_path() {
    local label="$1" path="$2"
    if [[ -e "$path" || -L "$path" ]]; then
        printf '%s=1\n' "$label" >>"$TRANSACTION_DIR/manifest"
        cp -a -- "$path" "$TRANSACTION_DIR/$label" || return 1
    else
        printf '%s=0\n' "$label" >>"$TRANSACTION_DIR/manifest"
    fi
}

abort_transaction_snapshot() {
    if [[ "$TRANSACTION_DIR" == /tmp/hy2-transaction.* ]]; then safe_remove_tree "$TRANSACTION_DIR" || true; fi
    TRANSACTION_DIR=""; TRANSACTION_ACTIVE="0"
}

begin_transaction() {
    [[ "$TRANSACTION_ACTIVE" == "0" ]] || return 1
    TRANSACTION_DIR="$(mktemp -d /tmp/hy2-transaction.XXXXXX)" || return 1
    : >"$TRANSACTION_DIR/manifest"
    snapshot_path config_dir "$CONFIG_DIR" || { abort_transaction_snapshot; return 1; }
    snapshot_path client_dir "$CLIENT_DIR" || { abort_transaction_snapshot; return 1; }
    snapshot_path service_file "$SERVICE_FILE" || { abort_transaction_snapshot; return 1; }
    snapshot_path service_template_file "$SERVICE_TEMPLATE_FILE" || { abort_transaction_snapshot; return 1; }
    snapshot_path management_bin "$MANAGEMENT_BIN" || { abort_transaction_snapshot; return 1; }
    snapshot_path hysteria_bin "$HYSTERIA_BIN" || { abort_transaction_snapshot; return 1; }
    snapshot_path acme_home "$ACME_HOME" || { abort_transaction_snapshot; return 1; }
    snapshot_path hysteria_home_dir "$HYSTERIA_HOME_DIR" || { abort_transaction_snapshot; return 1; }
    if id hysteria >/dev/null 2>&1; then printf 'hysteria_user=1\n' >>"$TRANSACTION_DIR/manifest"; else printf 'hysteria_user=0\n' >>"$TRANSACTION_DIR/manifest"; fi
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then printf 'service_active=1\n' >>"$TRANSACTION_DIR/manifest"; else printf 'service_active=0\n' >>"$TRANSACTION_DIR/manifest"; fi
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then printf 'service_enabled=1\n' >>"$TRANSACTION_DIR/manifest"; else printf 'service_enabled=0\n' >>"$TRANSACTION_DIR/manifest"; fi
    TRANSACTION_ACTIVE="1"
}

restore_snapshot_path() {
    local label="$1" path="$2" existed
    existed="$(state_get_from "$TRANSACTION_DIR/manifest" "$label" 2>/dev/null || printf '0')"
    if [[ -d "$path" && ! -L "$path" ]]; then
        safe_remove_tree "$path" || return 1
    else
        rm -f -- "$path"
    fi
    if [[ "$existed" == "1" ]]; then
        mkdir -p "$(dirname "$path")"
        cp -a -- "$TRANSACTION_DIR/$label" "$path" || return 1
    fi
}

rollback_transaction() {
    [[ "$TRANSACTION_ACTIVE" == "1" ]] || return 0
    warn "操作失败，正在恢复修改前状态。"
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    restore_snapshot_path config_dir "$CONFIG_DIR" || true
    restore_snapshot_path client_dir "$CLIENT_DIR" || true
    restore_snapshot_path service_file "$SERVICE_FILE" || true
    restore_snapshot_path service_template_file "$SERVICE_TEMPLATE_FILE" || true
    restore_snapshot_path management_bin "$MANAGEMENT_BIN" || true
    restore_snapshot_path hysteria_bin "$HYSTERIA_BIN" || true
    if [[ "$(state_get_from "$TRANSACTION_DIR/manifest" acme_home 2>/dev/null || printf '0')" == "0" && -x "$ACME_HOME/acme.sh" ]]; then
        "$ACME_HOME/acme.sh" --uninstall >/dev/null 2>&1 || true
    fi
    restore_snapshot_path acme_home "$ACME_HOME" || true
    restore_snapshot_path hysteria_home_dir "$HYSTERIA_HOME_DIR" || true
    if [[ "$(state_get_from "$TRANSACTION_DIR/manifest" hysteria_user 2>/dev/null || printf '0')" == "0" ]] && id hysteria >/dev/null 2>&1; then
        userdel hysteria >/dev/null 2>&1 || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ -f "$SERVICE_FILE" ]]; then
        if [[ "$(state_get_from "$TRANSACTION_DIR/manifest" service_enabled 2>/dev/null || printf '0')" == "1" ]]; then
            systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
        else
            systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        fi
        if [[ "$(state_get_from "$TRANSACTION_DIR/manifest" service_active 2>/dev/null || printf '0')" == "1" ]]; then
            systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
        else
            systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        fi
    fi
    if [[ "$TRANSACTION_DIR" == /tmp/hy2-transaction.* ]]; then safe_remove_tree "$TRANSACTION_DIR" || true; fi
    TRANSACTION_DIR=""; TRANSACTION_ACTIVE="0"
}

commit_transaction() {
    [[ "$TRANSACTION_ACTIVE" == "1" ]] || return 0
    if [[ "$TRANSACTION_DIR" == /tmp/hy2-transaction.* ]]; then safe_remove_tree "$TRANSACTION_DIR" || true; fi
    TRANSACTION_DIR=""; TRANSACTION_ACTIVE="0"
}

on_signal() {
    printf '\n' >&2
    rollback_transaction
    error "操作已中止。"
    exit 130
}
trap on_signal INT TERM

tcp_port_in_use() {
    local port="$1"
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
}

select_acme_challenge_port() {
    if ! tcp_port_in_use 443; then
        ACME_CHALLENGE_PORT="443"
    elif ! tcp_port_in_use 80; then
        ACME_CHALLENGE_PORT="80"
    else
        error "TCP 443 和 TCP 80 都被占用，无法自动完成 ACME 验证。"
        return 1
    fi
}

ensure_cron_available() {
    if ! has_cmd crontab; then
        info "安装证书自动续期所需的 cron。"
        if [[ "$PACKAGE_FAMILY" == "apt" ]]; then
            apt-get update -y || return 1
            apt-get install -y cron || return 1
        else
            local manager="dnf"; has_cmd dnf || manager="yum"
            "$manager" install -y cronie || return 1
        fi
    fi
    has_cmd crontab || { error "未找到 crontab，无法保证证书自动续期。"; return 1; }
    if systemctl cat cron.service >/dev/null 2>&1; then
        systemctl enable --now cron.service >/dev/null 2>&1 || return 1
    elif systemctl cat crond.service >/dev/null 2>&1; then
        systemctl enable --now crond.service >/dev/null 2>&1 || return 1
    else
        error "未找到 cron/crond 服务，无法保证证书自动续期。"
        return 1
    fi
}

install_acme_client() {
    local installer existed=0
    [[ -x "$ACME_HOME/acme.sh" ]] && return 0
    [[ -d "$ACME_HOME" ]] && existed=1
    installer="$(mktemp /tmp/hy2-acme-installer.XXXXXX)" || return 1
    curl -fL --retry 3 --connect-timeout 10 --max-time 120 https://get.acme.sh -o "$installer" || { rm -f "$installer"; return 1; }
    grep -q 'acme.sh' "$installer" || { rm -f "$installer"; error "ACME 安装器内容异常。"; return 1; }
    sh "$installer" --no-profile || { rm -f "$installer"; return 1; }
    rm -f "$installer"
    [[ -x "$ACME_HOME/acme.sh" ]] || return 1
    [[ "$existed" == "0" ]] && ACME_OWNED="1"
    return 0
}

certificate_pin() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

certificate_matches_key() {
    local cert_pub key_pub
    cert_pub="$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    key_pub="$(openssl pkey -in "$2" -pubout -outform DER 2>/dev/null | openssl sha256 2>/dev/null)" || return 1
    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

certificate_matches_name() {
    local cert="$1" name="$2"
    if valid_ip "$name"; then
        openssl x509 -in "$cert" -noout -checkip "$name" >/dev/null 2>&1
    else
        openssl x509 -in "$cert" -noout -checkhost "$name" >/dev/null 2>&1
    fi
}

validate_certificate_pair() {
    local cert="$1" key="$2" name="${3:-}"
    openssl x509 -in "$cert" -noout >/dev/null 2>&1 || { error "证书无法解析：$cert"; return 1; }
    openssl pkey -in "$key" -noout >/dev/null 2>&1 || { error "私钥无法解析：$key"; return 1; }
    certificate_matches_key "$cert" "$key" || { error "证书与私钥不匹配。"; return 1; }
    openssl x509 -in "$cert" -checkend 3600 -noout >/dev/null 2>&1 || { error "证书已过期或将在一小时内过期。"; return 1; }
    if [[ -n "$name" ]] && ! certificate_matches_name "$cert" "$name"; then
        error "证书的 SAN 不包含：$name"
        return 1
    fi
}

issue_acme_certificate() {
    local identifier="$1" mode="$2" acme=("$ACME_HOME/acme.sh") challenge_args=()
    ensure_cron_available || return 1
    if [[ -f "$STATE_FILE" && -x "$ACME_HOME/acme.sh" ]] &&
        [[ "$(state_get cert_mode 2>/dev/null || true)" == "$mode" ]] &&
        [[ "$(state_get tls_sni 2>/dev/null || true)" == "$identifier" ]] &&
        validate_certificate_pair "$CERT_FILE" "$KEY_FILE" "$identifier" &&
        certificate_is_system_trusted "$CERT_FILE"; then
        ACME_CHALLENGE_PORT="$(state_get acme_challenge_port 2>/dev/null || true)"
        TLS_SNI="$identifier"; TLS_INSECURE="0"; TLS_PIN_SHA256=""
        info "现有可信证书仍有效，继续使用并保留自动续期。"
        return 0
    fi
    install_acme_client || return 1
    select_acme_challenge_port || return 1
    if [[ "$ACME_CHALLENGE_PORT" == "443" ]]; then challenge_args=(--alpn); else challenge_args=(--standalone); fi

    if [[ "$mode" == "ip-acme" ]]; then
        info "申请 Let's Encrypt 短期公网 IP 证书（标识：$identifier）"
    else
        info "申请 Let's Encrypt 域名证书（标识：$identifier）"
    fi
    "${acme[@]}" --set-default-ca --server letsencrypt >/dev/null || return 1
    local issue_args=(--issue "${challenge_args[@]}" -d "$identifier" --server letsencrypt --keylength ec-256)
    [[ "$mode" == "ip-acme" ]] && issue_args+=(--certificate-profile shortlived --days -3)
    "${acme[@]}" "${issue_args[@]}" || return 1
    "${acme[@]}" --install-cert -d "$identifier" --ecc \
        --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" \
        --reloadcmd "systemctl try-restart $SERVICE_NAME || true" || return 1
    validate_certificate_pair "$CERT_FILE" "$KEY_FILE" "$identifier" || return 1
    certificate_is_system_trusted "$CERT_FILE" || { error "ACME 返回的证书链未通过系统信任校验。"; return 1; }
    CURRENT_CERT_FILE="$CERT_FILE"; CURRENT_KEY_FILE="$KEY_FILE"
    TLS_SNI="$identifier"; TLS_INSECURE="0"; TLS_PIN_SHA256=""
}

generate_self_signed_certificate() {
    local name="$1" san
    mkdir -p "$CONFIG_DIR" || return 1
    if valid_ip "$name"; then san="IP:$name"; else san="DNS:$name"; fi
    info "生成自签名证书（客户端将使用 SHA-256 指纹校验）"
    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
        -keyout "${KEY_FILE}.new" -out "${CERT_FILE}.new" \
        -subj "/CN=$name" -addext "subjectAltName=$san" >/dev/null 2>&1 || return 1
    validate_certificate_pair "${CERT_FILE}.new" "${KEY_FILE}.new" "$name" || return 1
    mv -f "${KEY_FILE}.new" "$KEY_FILE" || return 1
    mv -f "${CERT_FILE}.new" "$CERT_FILE" || return 1
    CURRENT_CERT_FILE="$CERT_FILE"; CURRENT_KEY_FILE="$KEY_FILE"
    TLS_SNI="$name"; TLS_INSECURE="1"; TLS_PIN_SHA256="$(certificate_pin "$CERT_FILE")"
    [[ -n "$TLS_PIN_SHA256" ]] || return 1
}

configure_existing_certificate() {
    local source_cert="$1" source_key="$2" name="$3"
    [[ -r "$source_cert" && -r "$source_key" ]] || { error "证书或私钥不可读。"; return 1; }
    validate_certificate_pair "$source_cert" "$source_key" "$name" || return 1
    certificate_is_system_trusted "$source_cert" || { error "现有证书不受系统信任；请改选【自签名 + 指纹校验】。"; return 1; }
    mkdir -p "$CONFIG_DIR" || return 1
    install -m 640 "$source_cert" "${CERT_FILE}.new" || return 1
    install -m 640 "$source_key" "${KEY_FILE}.new" || { rm -f "${CERT_FILE}.new"; return 1; }
    mv -f "${CERT_FILE}.new" "$CERT_FILE" || return 1
    mv -f "${KEY_FILE}.new" "$KEY_FILE" || return 1
    CURRENT_CERT_FILE="$CERT_FILE"; CURRENT_KEY_FILE="$KEY_FILE"
    TLS_SNI="$name"; TLS_INSECURE="0"; TLS_PIN_SHA256=""
}

configure_quick_certificate() {
    CERT_MODE="ip-acme"
    TLS_SNI="$PUBLIC_IP"
    if issue_acme_certificate "$PUBLIC_IP" ip-acme; then
        success "已启用可信 IP 证书，无需域名或跳过证书验证。"
        return 0
    fi
    warn "可信 IP 证书申请失败，自动改用带指纹校验的自签名证书。"
    FAILED_ACME_IDENTIFIER="$PUBLIC_IP"
    CERT_MODE="selfsigned"; ACME_CHALLENGE_PORT=""
    generate_self_signed_certificate "$PUBLIC_IP"
}

cleanup_previous_acme_certificate() {
    local previous_mode="$1" previous_identifier="$2" remaining
    [[ "$previous_mode" == "ip-acme" || "$previous_mode" == "domain-acme" ]] || return 0
    [[ -n "$previous_identifier" ]] || return 0
    if [[ "$previous_mode" == "$CERT_MODE" && "$previous_identifier" == "$TLS_SNI" ]]; then return 0; fi
    [[ -x "$ACME_HOME/acme.sh" ]] || return 0
    "$ACME_HOME/acme.sh" --remove -d "$previous_identifier" --ecc >/dev/null 2>&1 || true
    if [[ "$CERT_MODE" != "ip-acme" && "$CERT_MODE" != "domain-acme" && "$ACME_OWNED" == "1" ]]; then
        remaining="$("$ACME_HOME/acme.sh" --list 2>/dev/null | awk 'NR > 1 && NF {count++} END {print count+0}')"
        if [[ "$remaining" == "0" ]]; then
            "$ACME_HOME/acme.sh" --uninstall >/dev/null 2>&1 || true
            [[ -d "$ACME_HOME" ]] && safe_remove_tree "$ACME_HOME" || true
            ACME_OWNED="0"
        fi
    fi
}

cleanup_failed_acme_attempt() {
    local remaining
    [[ -n "$FAILED_ACME_IDENTIFIER" && -x "$ACME_HOME/acme.sh" ]] || return 0
    "$ACME_HOME/acme.sh" --remove -d "$FAILED_ACME_IDENTIFIER" --ecc >/dev/null 2>&1 || true
    if [[ "$CERT_MODE" != "ip-acme" && "$CERT_MODE" != "domain-acme" && "$ACME_OWNED" == "1" ]]; then
        remaining="$("$ACME_HOME/acme.sh" --list 2>/dev/null | awk 'NR > 1 && NF {count++} END {print count+0}')"
        if [[ "$remaining" == "0" ]]; then
            "$ACME_HOME/acme.sh" --uninstall >/dev/null 2>&1 || true
            [[ -d "$ACME_HOME" ]] && safe_remove_tree "$ACME_HOME" || true
            ACME_OWNED="0"
        fi
    fi
    FAILED_ACME_IDENTIFIER=""
}

save_installer_state() {
    local temp="${STATE_FILE}.new.$$"
    {
        printf 'version=%s\n' "$SCRIPT_VERSION"
        printf 'server_address=%s\n' "$SERVER_ADDRESS"
        printf 'public_ip=%s\n' "$PUBLIC_IP"
        printf 'server_port=%s\n' "$SERVER_PORT"
        printf 'auth_password=%s\n' "$AUTH_PASSWORD"
        printf 'obfs_password=%s\n' "$OBFS_PASSWORD"
        printf 'cert_mode=%s\n' "$CERT_MODE"
        printf 'tls_sni=%s\n' "$TLS_SNI"
        printf 'tls_insecure=%s\n' "$TLS_INSECURE"
        printf 'tls_pin_sha256=%s\n' "$TLS_PIN_SHA256"
        printf 'acme_challenge_port=%s\n' "$ACME_CHALLENGE_PORT"
        printf 'acme_owned=%s\n' "$ACME_OWNED"
        printf 'hysteria_user_owned=%s\n' "$HYSTERIA_USER_OWNED"
        printf 'hysteria_core_owned=%s\n' "$HYSTERIA_CORE_OWNED"
    } >"$temp" || return 1
    chmod 600 "$temp" || return 1
    mv -f "$temp" "$STATE_FILE"
}

render_server_config() {
    local output="$1"
    cat >"$output" <<EOF
# Managed by hy2 installer v${SCRIPT_VERSION}
listen: :${SERVER_PORT}

tls:
  cert: ${CERT_FILE}
  key: ${KEY_FILE}

auth:
  type: password
  password: $(yaml_quote "$AUTH_PASSWORD")

obfs:
  type: salamander
  salamander:
    password: $(yaml_quote "$OBFS_PASSWORD")

masquerade:
  type: string
  string:
    content: "Not Found"
    headers:
      content-type: "text/plain; charset=utf-8"
      cache-control: "no-store"
    statusCode: 404

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false
EOF
}

rotate_backups() {
    local old
    [[ -d "$BACKUP_DIR" ]] || return 0
    while (( $(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.yaml' | wc -l) > 3 )); do
        old="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.yaml' -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n1 | cut -d' ' -f2-)"
        [[ -n "$old" && "$old" == "$BACKUP_DIR"/* ]] || break
        rm -f -- "$old"
    done
}

activate_server_config() {
    local new_config="${CONFIG_FILE}.new.$$" backup
    render_server_config "$new_config" || return 1
    if [[ -f "$CONFIG_FILE" ]]; then
        mkdir -p "$BACKUP_DIR"
        backup="$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).yaml"
        cp -a "$CONFIG_FILE" "$backup" || return 1
    fi
    chown root:hysteria "$new_config" || return 1
    chmod 640 "$new_config" || return 1
    mv -f "$new_config" "$CONFIG_FILE" || return 1
    secure_files || return 1
    systemctl restart "$SERVICE_NAME" || return 1
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        error "Hysteria 服务启动失败，最近日志如下："
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager >&2 || true
        return 1
    fi
    rotate_backups
}

client_server_value() {
    local host="$SERVER_ADDRESS"
    valid_ipv6 "$host" && host="[$host]"
    printf '%s:%s' "$host" "$SERVER_PORT"
}

write_client_tls_block() {
    local output="$1"
    {
        printf 'tls:\n'
        printf '  sni: %s\n' "$(yaml_quote "$TLS_SNI")"
        if [[ "$TLS_INSECURE" == "1" ]]; then
            printf '  insecure: true\n'
            printf '  pinSHA256: %s\n' "$(yaml_quote "$TLS_PIN_SHA256")"
        else
            printf '  insecure: false\n'
        fi
    } >>"$output"
}

generate_client_configs() {
    local server_value socks_file tun_file url_file uri_host uri_port query uri candidate resolved seen="|" ipv4_yaml="" ipv6_yaml=""
    mkdir -p "$CLIENT_DIR" || return 1
    server_value="$(client_server_value)"
    socks_file="$CLIENT_DIR/hy-client.yaml"
    tun_file="$CLIENT_DIR/hy-client-tun.yaml"
    url_file="$CLIENT_DIR/url.txt"
    rm -f "$CLIENT_DIR/hy-client.json" || return 1

    {
        printf '# Hysteria 2 client - SOCKS5 mode\n'
        printf 'server: %s\n' "$(yaml_quote "$server_value")"
        printf 'auth: %s\n' "$(yaml_quote "$AUTH_PASSWORD")"
        printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$(yaml_quote "$OBFS_PASSWORD")"
    } >"$socks_file" || return 1
    write_client_tls_block "$socks_file" || return 1
    cat >>"$socks_file" <<'EOF' || return 1
socks5:
  listen: 127.0.0.1:1080
EOF
    [[ -s "$socks_file" ]] || return 1

    {
        printf '# Hysteria 2 client - native TUN mode (run as administrator/root)\n'
        printf 'server: %s\n' "$(yaml_quote "$server_value")"
        printf 'auth: %s\n' "$(yaml_quote "$AUTH_PASSWORD")"
        printf 'obfs:\n  type: salamander\n  salamander:\n    password: %s\n' "$(yaml_quote "$OBFS_PASSWORD")"
    } >"$tun_file" || return 1
    write_client_tls_block "$tun_file" || return 1
    if ! valid_ip "$SERVER_ADDRESS" && has_cmd getent; then
        resolved="$(getent ahosts "$SERVER_ADDRESS" 2>/dev/null | awk '{print $1}' || true)"
    fi
    while IFS= read -r candidate; do
        [[ -n "$candidate" && "$seen" != *"|${candidate}|"* ]] || continue
        if valid_ipv4 "$candidate"; then
            ipv4_yaml+="      - ${candidate}/32"$'\n'; seen+="${candidate}|"
        elif valid_ipv6 "$candidate"; then
            ipv6_yaml+="      - \"${candidate}/128\""$'\n'; seen+="${candidate}|"
        fi
    done <<<"${PUBLIC_IP}"$'\n'"${resolved:-}"
    cat >>"$tun_file" <<EOF || return 1
tun:
  name: hy2
  mtu: 1400
  timeout: 5m
  address:
    ipv4: 100.100.100.101/30
    ipv6: 2001:db8::101/126
  route:
    ipv4:
      - 0.0.0.0/0
    ipv6:
      - "2000::/3"
EOF
    [[ -s "$tun_file" ]] || return 1
    if [[ -n "$ipv4_yaml" ]]; then printf '    ipv4Exclude:\n%s' "$ipv4_yaml" >>"$tun_file" || return 1; fi
    if [[ -n "$ipv6_yaml" ]]; then printf '    ipv6Exclude:\n%s' "$ipv6_yaml" >>"$tun_file" || return 1; fi

    uri_host="$(host_for_uri "$SERVER_ADDRESS")"
    uri_port="$SERVER_PORT"
    query="sni=$(uri_encode "$TLS_SNI")&obfs=salamander&obfs-password=$(uri_encode "$OBFS_PASSWORD")"
    [[ "$TLS_INSECURE" == "1" ]] && query+="&insecure=1"
    [[ -n "$TLS_PIN_SHA256" ]] && query+="&pinSHA256=$(uri_encode "$TLS_PIN_SHA256")"
    uri="hysteria2://$(uri_encode "$AUTH_PASSWORD")@${uri_host}:${uri_port}/?${query}#hy2"
    printf '%s\n' "$uri" >"$url_file" || return 1
    chmod 600 "$socks_file" "$tun_file" "$url_file"
}

yaml_value_in_section() {
    local section="$1" key="$2" file="$3"
    awk -v wanted="$section" -v wanted_key="$key" '
        /^[[:alnum:]_-]+:[[:space:]]*$/ {
            top=$0; sub(/:.*/, "", top); in_section=(top == wanted); next
        }
        in_section && $0 ~ "^[[:space:]]+" wanted_key ":[[:space:]]*" {
            sub("^[[:space:]]+" wanted_key ":[[:space:]]*", ""); print; exit
        }
    ' "$file"
}

yaml_password_in_section() { yaml_value_in_section "$1" password "$2"; }

certificate_is_self_signed() {
    local cert="$1" subject issuer
    [[ -r "$cert" ]] || return 1
    subject="$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')" || return 1
    issuer="$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')" || return 1
    [[ -n "$subject" && "$subject" == "$issuer" ]]
}

certificate_is_system_trusted() {
    local cert="$1" temp count i result=1
    temp="$(mktemp -d /tmp/hy2-certcheck.XXXXXX)" || return 1
    if ! awk -v prefix="$temp/part-" '
        /-----BEGIN CERTIFICATE-----/ {part++}
        part > 0 {print > (prefix part ".pem")}
    ' "$cert"; then
        safe_remove_tree "$temp" || true
        return 1
    fi
    count="$(find "$temp" -maxdepth 1 -type f -name 'part-*.pem' | wc -l)"
    if [[ "$count" =~ ^[0-9]+$ ]] && ((count >= 1)); then
        if ((count == 1)); then
            openssl verify "$temp/part-1.pem" >/dev/null 2>&1 && result=0
        else
            : >"$temp/chain.pem"
            for ((i=2; i<=count; i++)); do cat "$temp/part-${i}.pem" >>"$temp/chain.pem" || break; done
            openssl verify -untrusted "$temp/chain.pem" "$temp/part-1.pem" >/dev/null 2>&1 && result=0
        fi
    fi
    safe_remove_tree "$temp" || true
    return "$result"
}

read_current_config() {
    local value listen has_state=0 legacy_cert legacy_key legacy_client legacy_insecure="" legacy_sni=""
    CURRENT_CERT_FILE="$CERT_FILE"; CURRENT_KEY_FILE="$KEY_FILE"
    if [[ -f "$STATE_FILE" ]]; then
        has_state=1
        SERVER_ADDRESS="$(state_get server_address 2>/dev/null || true)"
        PUBLIC_IP="$(state_get public_ip 2>/dev/null || true)"
        SERVER_PORT="$(state_get server_port 2>/dev/null || printf '443')"
        AUTH_PASSWORD="$(state_get auth_password 2>/dev/null || true)"
        OBFS_PASSWORD="$(state_get obfs_password 2>/dev/null || true)"
        CERT_MODE="$(state_get cert_mode 2>/dev/null || printf 'selfsigned')"
        TLS_SNI="$(state_get tls_sni 2>/dev/null || true)"
        TLS_INSECURE="$(state_get tls_insecure 2>/dev/null || printf '1')"
        TLS_PIN_SHA256="$(state_get tls_pin_sha256 2>/dev/null || true)"
        ACME_CHALLENGE_PORT="$(state_get acme_challenge_port 2>/dev/null || true)"
        ACME_OWNED="$(state_get acme_owned 2>/dev/null || printf '0')"
        HYSTERIA_USER_OWNED="$(state_get hysteria_user_owned 2>/dev/null || printf '0')"
        HYSTERIA_CORE_OWNED="$(state_get hysteria_core_owned 2>/dev/null || printf '0')"
    fi
    [[ -f "$CONFIG_FILE" ]] || return 1
    if [[ "$has_state" == "0" ]]; then
        SERVER_PORT=""
        AUTH_PASSWORD=""; OBFS_PASSWORD=""
        TLS_SNI=""; TLS_INSECURE="0"; TLS_PIN_SHA256=""
        legacy_cert="$(yaml_value_in_section tls cert "$CONFIG_FILE" 2>/dev/null || true)"
        legacy_key="$(yaml_value_in_section tls key "$CONFIG_FILE" 2>/dev/null || true)"
        legacy_cert="$(yaml_unquote "$legacy_cert")"; legacy_key="$(yaml_unquote "$legacy_key")"
        [[ -n "$legacy_cert" ]] && CURRENT_CERT_FILE="$legacy_cert"
        [[ -n "$legacy_key" ]] && CURRENT_KEY_FILE="$legacy_key"
        legacy_client="$CLIENT_DIR/hy-client.yaml"
        if [[ -f "$legacy_client" ]]; then
            legacy_insecure="$(awk '/^[[:space:]]+insecure:[[:space:]]*/ {print $2; exit}' "$legacy_client")"
            legacy_sni="$(awk '/^[[:space:]]+sni:[[:space:]]*/ {sub(/^[[:space:]]+sni:[[:space:]]*/, ""); print; exit}' "$legacy_client")"
            legacy_sni="$(yaml_unquote "$legacy_sni")"
            [[ -n "$legacy_sni" ]] && TLS_SNI="$legacy_sni"
        fi
        if [[ "$legacy_insecure" == "true" ]] || certificate_is_self_signed "$CURRENT_CERT_FILE"; then
            TLS_INSECURE="1"; CERT_MODE="selfsigned"
            TLS_PIN_SHA256="$(certificate_pin "$CURRENT_CERT_FILE")"
        else
            TLS_INSECURE="0"; TLS_PIN_SHA256=""; CERT_MODE="existing"
        fi
    fi
    if [[ -z "$AUTH_PASSWORD" ]]; then
        value="$(yaml_password_in_section auth "$CONFIG_FILE")"; AUTH_PASSWORD="$(yaml_unquote "$value")"
    fi
    if [[ -z "$OBFS_PASSWORD" ]]; then
        value="$(yaml_password_in_section obfs "$CONFIG_FILE")"; OBFS_PASSWORD="$(yaml_unquote "$value")"
    fi
    if [[ -z "$SERVER_PORT" ]]; then
        listen="$(awk '/^listen:[[:space:]]*/ {sub(/^listen:[[:space:]]*:*/, ""); print; exit}' "$CONFIG_FILE")"
        listen="${listen##*:}"
        SERVER_PORT="${listen%%-*}"
    fi
    if [[ -z "$PUBLIC_IP" ]]; then fetch_public_ip || return 1; fi
    [[ -n "$SERVER_ADDRESS" ]] || SERVER_ADDRESS="$PUBLIC_IP"
    [[ -n "$TLS_SNI" ]] || TLS_SNI="$SERVER_ADDRESS"
    if [[ "$TLS_INSECURE" == "1" && -z "$TLS_PIN_SHA256" && -f "$CURRENT_CERT_FILE" ]]; then
        TLS_PIN_SHA256="$(certificate_pin "$CURRENT_CERT_FILE")"
    fi
    valid_secret "$AUTH_PASSWORD" && valid_secret "$OBFS_PASSWORD" || return 1
    [[ "$TLS_INSECURE" != "1" || -n "$TLS_PIN_SHA256" ]]
}

install_management_command() {
    local source_path target_path
    source_path="$(readlink -f "${BASH_SOURCE[0]}")"
    target_path="$(readlink -f "$MANAGEMENT_BIN" 2>/dev/null || printf '%s' "$MANAGEMENT_BIN")"
    [[ "$source_path" == "$target_path" ]] && return 0
    atomic_install_file "$source_path" "$MANAGEMENT_BIN" 755 root root
}

print_client_result() {
    local url
    url="$(cat "$CLIENT_DIR/url.txt")"
    printf '\n%bHysteria 2 已可用%b\n' "$C_GREEN" "$C_RESET"
    printf '服务器：%s\n' "$(client_server_value)"
    printf '分享链接：\n%s\n' "$url"
    printf 'SOCKS5 配置：%s\n' "$CLIENT_DIR/hy-client.yaml"
    printf '原生 TUN 配置：%s\n' "$CLIENT_DIR/hy-client-tun.yaml"
    if [[ "$TLS_INSECURE" == "1" ]]; then
        warn "当前为自签名证书。链接已包含证书指纹；若客户端导入后丢失 pinSHA256，请使用生成的 YAML 或切换 sing-box/官方 Hysteria 内核。"
    fi
    warn "脚本不会修改防火墙；请自行放行 UDP ${SERVER_PORT}${ACME_CHALLENGE_PORT:+ 和 TCP ${ACME_CHALLENGE_PORT}}。"
}

prepare_runtime() {
    require_root || return 1
    detect_os || return 1
    install_dependencies || return 1
    check_crypto_capabilities || return 1
    if ! fetch_public_ip; then
        error "无法取得有效公网 IP。请检查 VPS 网络后重试。"
        return 1
    fi
}

ensure_install_scope_safe() {
    local -a conflicts=()
    managed_paths_are_safe || { error "检测到托管路径为符号链接或指向预期目录之外，已拒绝继续。"; return 1; }
    has_valid_installer_state && return 0
    if [[ -d "$CONFIG_DIR" ]] && find "$CONFIG_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then conflicts+=("$CONFIG_DIR"); fi
    if [[ -d "$CLIENT_DIR" ]] && find "$CLIENT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then conflicts+=("$CLIENT_DIR"); fi
    [[ -e "$SERVICE_FILE" || -L "$SERVICE_FILE" ]] && conflicts+=("$SERVICE_FILE")
    [[ -e "$MANAGEMENT_BIN" || -L "$MANAGEMENT_BIN" ]] && conflicts+=("$MANAGEMENT_BIN")
    if ((${#conflicts[@]} > 0)); then
        error "检测到没有本脚本有效状态记录的现有文件，已拒绝覆盖：${conflicts[*]}"
        error "请先备份并移走这些文件，再重新安装。现有 Hysteria 内核本身可以直接保留。"
        return 1
    fi
}

install_core_and_unit() {
    local user_preexisting=0
    id hysteria >/dev/null 2>&1 && user_preexisting=1
    if [[ -x "$HYSTERIA_BIN" ]] && "$HYSTERIA_BIN" version >/dev/null 2>&1; then
        info "保留当前可用的 Hysteria 内核；如需升级请使用菜单 7。"
    else
        install_hysteria_core || return 1
        HYSTERIA_CORE_OWNED="1"
    fi
    ensure_service_unit || return 1
    if [[ "$user_preexisting" == "0" ]] && id hysteria >/dev/null 2>&1; then HYSTERIA_USER_OWNED="1"; fi
}

perform_install() {
    local cert_strategy="$1" source_cert="${2:-}" source_key="${3:-}" previous_cert_mode="" previous_sni=""
    if [[ -f "$STATE_FILE" ]]; then
        previous_cert_mode="$(state_get cert_mode 2>/dev/null || true)"
        previous_sni="$(state_get tls_sni 2>/dev/null || true)"
        ACME_OWNED="$(state_get acme_owned 2>/dev/null || printf '0')"
        HYSTERIA_USER_OWNED="$(state_get hysteria_user_owned 2>/dev/null || printf '0')"
        HYSTERIA_CORE_OWNED="$(state_get hysteria_core_owned 2>/dev/null || printf '0')"
    fi
    begin_transaction || return 1
    if ! install_core_and_unit; then rollback_transaction; return 1; fi

    case "$cert_strategy" in
        quick) configure_quick_certificate || { rollback_transaction; return 1; } ;;
        ip-acme) CERT_MODE="ip-acme"; issue_acme_certificate "$PUBLIC_IP" ip-acme || { rollback_transaction; return 1; } ;;
        domain-acme) CERT_MODE="domain-acme"; issue_acme_certificate "$TLS_SNI" domain-acme || { rollback_transaction; return 1; } ;;
        existing) CERT_MODE="existing"; configure_existing_certificate "$source_cert" "$source_key" "$TLS_SNI" || { rollback_transaction; return 1; } ;;
        selfsigned) CERT_MODE="selfsigned"; ACME_CHALLENGE_PORT=""; generate_self_signed_certificate "$TLS_SNI" || { rollback_transaction; return 1; } ;;
        *) rollback_transaction; return 1 ;;
    esac

    if ! save_installer_state; then rollback_transaction; return 1; fi
    if ! activate_server_config; then rollback_transaction; return 1; fi
    if ! generate_client_configs || ! install_management_command; then rollback_transaction; return 1; fi
    if ! secure_files; then rollback_transaction; return 1; fi
    commit_transaction
    cleanup_legacy_artifacts
    cleanup_previous_acme_certificate "$previous_cert_mode" "$previous_sni"
    cleanup_failed_acme_attempt
    save_installer_state || warn "配置已生效，但安装器状态文件未能更新。"
    print_client_result
}

quick_install() {
    prepare_runtime || return 1
    ensure_install_scope_safe || return 1
    FAILED_ACME_IDENTIFIER=""
    SERVER_ADDRESS="$PUBLIC_IP"; SERVER_PORT="443"
    AUTH_PASSWORD="$(random_secret 32)" || return 1
    OBFS_PASSWORD="$(random_secret 32)" || return 1
    [[ -n "$AUTH_PASSWORD" && -n "$OBFS_PASSWORD" ]] || { error "无法生成安全随机密码。"; return 1; }
    TLS_SNI="$PUBLIC_IP"; TLS_INSECURE="0"; TLS_PIN_SHA256=""; ACME_CHALLENGE_PORT=""
    info "使用小白默认配置：UDP 443、随机双密码、可信 IP 证书优先、自动续期。"
    perform_install quick
}

prompt_value() {
    local prompt="$1" default="$2" answer
    read -r -p "$prompt [$default]: " answer
    printf '%s' "${answer:-$default}"
}

prompt_port_settings() {
    while true; do
        SERVER_PORT="$(prompt_value "UDP 端口" "${SERVER_PORT:-443}")"
        valid_port "$SERVER_PORT" && return 0
        warn "端口必须是 1-65535。"
    done
}

prompt_certificate_strategy() {
    local choice domain cert key
    CERT_STRATEGY=""; CERT_SOURCE_FILE=""; KEY_SOURCE_FILE=""
    while true; do
        printf '\n证书方式：\n  1) 可信公网 IP 证书（推荐，无需域名）\n  2) 域名 ACME 证书\n  3) 使用现有系统可信证书\n  4) 自签名 + 指纹校验\n'
        read -r -p "请选择 [1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            1) TLS_SNI="$PUBLIC_IP"; CERT_STRATEGY="ip-acme"; return 0 ;;
            2)
                read -r -p "已解析到本机公网 IP 的域名: " domain
                if valid_hostname "$domain"; then
                    SERVER_ADDRESS="$domain"; TLS_SNI="$domain"; CERT_STRATEGY="domain-acme"; return 0
                fi
                warn "域名格式无效。"
                ;;
            3)
                read -r -p "完整证书链路径: " cert
                read -r -p "私钥路径: " key
                read -r -p "证书中的域名或 IP [$SERVER_ADDRESS]: " domain
                TLS_SNI="${domain:-$SERVER_ADDRESS}"
                CERT_STRATEGY="existing"; CERT_SOURCE_FILE="$cert"; KEY_SOURCE_FILE="$key"; return 0
                ;;
            4) TLS_SNI="$SERVER_ADDRESS"; CERT_STRATEGY="selfsigned"; return 0 ;;
            *) warn "请输入 1-4。" ;;
        esac
    done
}

custom_install() {
    prepare_runtime || return 1
    ensure_install_scope_safe || return 1
    read_current_config >/dev/null 2>&1 || true
    SERVER_ADDRESS="$(prompt_value "客户端连接地址" "${SERVER_ADDRESS:-$PUBLIC_IP}")"
    if ! valid_ip "$SERVER_ADDRESS" && ! valid_hostname "$SERVER_ADDRESS"; then
        error "连接地址既不是有效 IP，也不是有效域名。"; return 1
    fi
    prompt_port_settings || return 1
    AUTH_PASSWORD="$(prompt_value "认证密码（Enter 自动生成）" "${AUTH_PASSWORD:-$(random_secret 32)}")"
    OBFS_PASSWORD="$(prompt_value "混淆密码（Enter 自动生成）" "${OBFS_PASSWORD:-$(random_secret 32)}")"
    valid_secret "$AUTH_PASSWORD" && valid_secret "$OBFS_PASSWORD" || { error "密码必须为 1-256 个字符，且不能包含控制字符。"; return 1; }
    prompt_certificate_strategy || return 1
    perform_install "$CERT_STRATEGY" "$CERT_SOURCE_FILE" "$KEY_SOURCE_FILE"
}

show_config() {
    if ! read_current_config; then error "尚未安装或配置不完整。"; return 1; fi
    [[ -f "$CLIENT_DIR/url.txt" ]] || generate_client_configs || return 1
    printf '\nHysteria 2 配置\n'
    printf '  状态：%s\n' "$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || printf 'unknown')"
    printf '  地址：%s\n' "$(client_server_value)"
    printf '  证书：%s\n' "$CERT_MODE"
    printf '  SNI：%s\n' "$TLS_SNI"
    printf '  认证密码：%s\n' "$AUTH_PASSWORD"
    printf '  混淆密码：%s\n' "$OBFS_PASSWORD"
    printf '  分享链接：%s\n' "$(cat "$CLIENT_DIR/url.txt")"
    printf '  SOCKS5：%s\n' "$CLIENT_DIR/hy-client.yaml"
    printf '  原生 TUN：%s\n' "$CLIENT_DIR/hy-client-tun.yaml"
    [[ "$TLS_INSECURE" == "1" ]] && warn "自签名模式必须保留 pinSHA256，不能只开启 insecure。"
    return 0
}

diagnose() {
    local failures=0 cert_end
    require_root || return 1
    printf 'Hysteria 2 诊断（脚本 %s）\n' "$SCRIPT_VERSION"
    if [[ -x "$HYSTERIA_BIN" ]]; then
        printf '[OK] 内核：%s\n' "$("$HYSTERIA_BIN" version 2>/dev/null | head -n1)"
    else
        printf '[FAIL] 未找到 Hysteria 内核：%s\n' "$HYSTERIA_BIN"; failures=$((failures + 1))
    fi
    if read_current_config; then
        printf '[OK] 配置已读取，auth/obfs 分区解析正常\n'
    else
        printf '[FAIL] 配置缺失或密码读取失败\n'; failures=$((failures + 1))
    fi
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        printf '[OK] 服务正在运行\n'
    else
        printf '[FAIL] 服务未运行\n'; failures=$((failures + 1))
        journalctl -u "$SERVICE_NAME" -n 15 --no-pager 2>/dev/null || true
    fi
    if ss -H -lun 2>/dev/null | grep -Eq ":${SERVER_PORT}([[:space:]]|$)"; then
        printf '[OK] 检测到 UDP 监听\n'
    else
        printf '[WARN] 未检测到 UDP %s 监听，请结合服务日志确认\n' "$SERVER_PORT"
    fi
    if [[ -f "$CURRENT_CERT_FILE" && -f "$CURRENT_KEY_FILE" ]] && validate_certificate_pair "$CURRENT_CERT_FILE" "$CURRENT_KEY_FILE" "$TLS_SNI"; then
        cert_end="$(openssl x509 -in "$CURRENT_CERT_FILE" -noout -enddate 2>/dev/null | cut -d= -f2-)"
        printf '[OK] 证书、私钥及 SAN 匹配；到期：%s\n' "$cert_end"
    else
        printf '[FAIL] 证书检查失败\n'; failures=$((failures + 1))
    fi
    if [[ "$TLS_INSECURE" == "1" ]]; then
        if [[ -n "$TLS_PIN_SHA256" ]]; then printf '[OK] 自签名证书已绑定 SHA-256 指纹\n'; else printf '[FAIL] 自签名证书缺少指纹\n'; failures=$((failures + 1)); fi
    else
        if certificate_is_system_trusted "$CURRENT_CERT_FILE"; then
            printf '[OK] 客户端使用系统信任链验证证书\n'
        else
            printf '[FAIL] 证书链未通过系统信任校验\n'; failures=$((failures + 1))
        fi
    fi
    if [[ "$CERT_MODE" == "ip-acme" || "$CERT_MODE" == "domain-acme" ]]; then
        if [[ -x "$ACME_HOME/acme.sh" ]] && "$ACME_HOME/acme.sh" --list 2>/dev/null | grep -Fq "$TLS_SNI"; then
            printf '[OK] ACME 续期配置存在\n'
        else
            printf '[FAIL] 未找到当前证书的 ACME 续期配置\n'; failures=$((failures + 1))
        fi
        if has_cmd crontab && crontab -l 2>/dev/null | grep -Fq 'acme.sh --cron'; then
            printf '[OK] ACME 定时续期任务存在\n'
        else
            printf '[FAIL] 未找到 ACME 定时续期任务\n'; failures=$((failures + 1))
        fi
        if systemctl is-active --quiet cron.service 2>/dev/null || systemctl is-active --quiet crond.service 2>/dev/null; then
            printf '[OK] cron 服务运行中\n'
        else
            printf '[FAIL] cron 服务未运行，续期任务不会执行\n'; failures=$((failures + 1))
        fi
        if [[ -n "$ACME_CHALLENGE_PORT" ]] && tcp_port_in_use "$ACME_CHALLENGE_PORT"; then
            printf '[WARN] TCP %s 当前被占用，下一次独立 ACME 验证可能无法绑定该端口\n' "$ACME_CHALLENGE_PORT"
        fi
    fi
    if [[ -f "$CLIENT_DIR/hy-client-tun.yaml" ]] && grep -qF "$PUBLIC_IP/" "$CLIENT_DIR/hy-client-tun.yaml"; then
        printf '[OK] TUN 配置已排除服务器公网 IP，避免代理回环\n'
    else
        printf '[WARN] TUN 配置未发现服务器 IP 排除项，请重新生成客户端配置\n'
    fi
    printf '[INFO] 脚本不修改本机防火墙；请自行放行 UDP %s%s\n' "$SERVER_PORT" "${ACME_CHALLENGE_PORT:+，TCP $ACME_CHALLENGE_PORT}"
    if ((failures == 0)); then success "本机检查未发现阻断项。云安全组、运营商 UDP 和客户端行为需在实机验证。"; else error "发现 $failures 个本机问题。"; return 1; fi
}

service_menu() {
    local choice
    printf '\n1) 启动  2) 停止  3) 重启  4) 状态  5) 实时日志  0) 返回\n'
    read -r -p "请选择: " choice
    case "$choice" in
        1) systemctl start "$SERVICE_NAME" && success "服务已启动。" ;;
        2) systemctl stop "$SERVICE_NAME" && success "服务已停止。" ;;
        3) systemctl restart "$SERVICE_NAME" && success "服务已重启。" ;;
        4) systemctl status "$SERVICE_NAME" --no-pager ;;
        5) journalctl -u "$SERVICE_NAME" -f ;;
        0|"") return 0 ;;
        *) warn "无效选项。" ;;
    esac
}

check_script_update() {
    local tmp_file="/tmp/hy2-latest.sh" current="$SCRIPT_VERSION" new="" confirm=""
    info "正在从 GitHub 下载最新脚本…"
    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 60 "$REPO_RAW_URL" -o "$tmp_file"; then
        error "下载最新脚本失败，请检查网络。"
        return 1
    fi
    [[ "$(head -n 1 "$tmp_file")" == '#!/usr/bin/env bash' ]] || { error "下载内容不是有效脚本（shebang 校验失败）。"; rm -f "$tmp_file"; return 1; }
    bash -n "$tmp_file" || { error "下载脚本语法检查失败。"; rm -f "$tmp_file"; return 1; }
    new="$(sed -n 's/^readonly SCRIPT_VERSION="\([^"]*\)"/\1/p' "$tmp_file" | head -n 1)"
    [[ -n "$new" ]] || { error "无法识别下载脚本的版本号。"; rm -f "$tmp_file"; return 1; }
    if [[ "$new" == "$current" ]]; then
        info "当前已是最新版本：$current"
        rm -f "$tmp_file"
        return 0
    fi
    info "发现新版本：$current → $new"
    read -r -p "是否立即安装新版本？（下载文件未经签名验证，请确认来源可信后选择）(y/N): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        install -m 755 "$tmp_file" "$MANAGEMENT_BIN" || { error "安装失败。"; rm -f "$tmp_file"; return 1; }
        rm -f "$tmp_file"
        success "已更新 $MANAGEMENT_BIN，下次运行 hy2 即生效（v$new）。"
        return 0
    fi
    warn "已保留下载文件：$tmp_file；可手动执行：install -m 755 $tmp_file $MANAGEMENT_BIN"
}

update_core() {
    require_root || return 1
    detect_os || return 1
    install_dependencies || return 1
    read_current_config || { error "尚未安装。"; return 1; }
    begin_transaction || return 1
    if ! install_hysteria_core || ! ensure_service_unit || ! systemctl restart "$SERVICE_NAME"; then
        rollback_transaction; return 1
    fi
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then rollback_transaction; return 1; fi
    commit_transaction
    success "内核已更新，服务运行正常。"
}

remove_acme_assets() {
    local identifier="$1" remaining
    [[ -x "$ACME_HOME/acme.sh" ]] || return 0
    if [[ "$CERT_MODE" == "ip-acme" || "$CERT_MODE" == "domain-acme" ]]; then
        "$ACME_HOME/acme.sh" --remove -d "$identifier" --ecc >/dev/null 2>&1 || true
    fi
    [[ "$ACME_OWNED" == "1" ]] || return 0
    remaining="$("$ACME_HOME/acme.sh" --list 2>/dev/null | awk 'NR > 1 && NF {count++} END {print count+0}')"
    if [[ "$remaining" == "0" ]]; then
        "$ACME_HOME/acme.sh" --uninstall >/dev/null 2>&1 || true
        [[ -d "$ACME_HOME" ]] && safe_remove_tree "$ACME_HOME" || true
    else
        warn "acme.sh 中仍有其他证书，已保留 ACME 客户端与续期任务。"
    fi
}

remove_managed_data_files() {
    rm -f "$CONFIG_FILE" "$STATE_FILE" "$CERT_FILE" "$KEY_FILE"
    if [[ -d "$BACKUP_DIR" ]]; then
        find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.yaml' -delete || return 1
        if ! rmdir "$BACKUP_DIR" 2>/dev/null; then warn "备份目录中存在非本脚本文件，已保留：$BACKUP_DIR"; fi
    fi
    if [[ -d "$CONFIG_DIR" ]] && ! rmdir "$CONFIG_DIR" 2>/dev/null; then
        warn "配置目录中存在非本脚本文件，已保留：$CONFIG_DIR"
    fi
    rm -f "$CLIENT_DIR/url.txt" "$CLIENT_DIR/hy-client.yaml" "$CLIENT_DIR/hy-client-tun.yaml" "$CLIENT_DIR/hy-client.json"
    if [[ -d "$CLIENT_DIR" ]] && ! rmdir "$CLIENT_DIR" 2>/dev/null; then
        warn "客户端目录中存在非本脚本文件，已保留：$CLIENT_DIR"
    fi
}

uninstall_hysteria() {
    local confirmation
    require_root || return 1
    managed_paths_are_safe || { error "检测到托管路径为符号链接或指向预期目录之外，已拒绝卸载。"; return 1; }
    has_valid_installer_state || { error "未找到本脚本的有效安装状态，拒绝删除可能由其他方式创建的 Hysteria。"; return 1; }
    read_current_config >/dev/null 2>&1 || true
    printf '将删除本脚本管理的服务、配置、客户端文件和内核；不会修改任何防火墙规则。\n'
    read -r -p "请输入 UNINSTALL 确认: " confirmation
    [[ "$confirmation" == "UNINSTALL" ]] || { warn "已取消。"; return 0; }

    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    cleanup_legacy_artifacts
    remove_acme_assets "$TLS_SNI"
    rm -f "$SERVICE_FILE" "$MANAGEMENT_BIN"
    if [[ "$HYSTERIA_CORE_OWNED" == "1" ]]; then
        rm -f "$SERVICE_TEMPLATE_FILE" "$HYSTERIA_BIN"
    else
        warn "Hysteria 内核在首次安装前已存在，已保留内核与官方模板服务。"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    remove_managed_data_files || return 1
    if [[ "$HYSTERIA_USER_OWNED" == "1" ]]; then
        if id hysteria >/dev/null 2>&1 && ! userdel hysteria >/dev/null 2>&1; then
            warn "hysteria 用户仍被占用，未删除其主目录。"
        elif [[ -d "$HYSTERIA_HOME_DIR" ]]; then
            safe_remove_tree "$HYSTERIA_HOME_DIR" || true
        fi
    fi
    success "卸载完成。未修改任何防火墙规则，也不会删除其他 ACME 证书。"
}

print_header() {
    printf '%bHysteria 2 小白一键脚本%b  v%s\n' "$C_BLUE" "$C_RESET" "$SCRIPT_VERSION"
}

main_menu() {
    local choice default_choice
    require_root || return 1
    while true; do
        print_header
        if [[ -f "$CONFIG_FILE" ]]; then default_choice=3; else default_choice=1; fi
        cat <<'EOF'
  1) 一键安装 / 重装（全自动推荐配置）
  2) 自定义安装 / 修改
  3) 查看配置与分享链接
  4) 重新生成客户端配置
  5) 服务管理
  6) 一键诊断
  7) 更新 Hysteria 内核
  8) 安全卸载
  9) 检查脚本更新（确认后安装）
  0) 退出
EOF
        read -r -p "请选择 [${default_choice}]: " choice
        choice="${choice:-$default_choice}"
        case "$choice" in
            1) quick_install || true ;;
            2) custom_install || true ;;
            3) show_config || true ;;
            4)
                if read_current_config && generate_client_configs; then success "客户端配置已重新生成。"; else error "无法读取现有配置。"; fi
                ;;
            5) service_menu || true ;;
            6) diagnose || true ;;
            7) update_core || true ;;
            8) uninstall_hysteria || true ;;
            9) check_script_update || true ;;
            0) return 0 ;;
            *) warn "无效选项，请输入 0-8。" ;;
        esac
        printf '\n'
    done
}

print_help() {
    cat <<EOF
用法：bash hysteria.sh [选项]
  --install       全自动安装（默认 UDP 443）
  --reinstall     使用全新随机密码重装
  --diagnose      本机诊断
  --uninstall     安全卸载（仍需输入 UNINSTALL）
  --check-update  检查脚本更新（确认后安装）
  --version       显示版本
  --help          显示帮助
EOF
}

main() {
    case "${1:-}" in
        --install|--reinstall) quick_install ;;
        --diagnose) diagnose ;;
        --uninstall) uninstall_hysteria ;;
        --check-update) check_script_update ;;
        --version) printf '%s\n' "$SCRIPT_VERSION" ;;
        --help|-h) print_help ;;
        "") main_menu ;;
        *) error "未知选项：$1"; print_help; return 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
