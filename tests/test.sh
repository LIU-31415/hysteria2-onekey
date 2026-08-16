#!/usr/bin/env bash
# Variables assigned here are consumed indirectly by functions from hysteria.sh.
# shellcheck disable=SC2034

set -euo pipefail

# Git Bash (MSYS2/MINGW) 会把 /CN=... 之类的参数误转成 Windows 路径；
# 关闭自动转换后，路径参数需手动转成 Windows 形式（openssl 是原生程序）。
# Linux 下无副作用（uname 不匹配则不设置）。
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        export MSYS2_ARG_CONV_EXCL='*'
        openssl() {
            local a
            local -a out=()
            for a in "$@"; do
                case "$a" in
                    /tmp/*) a="$(cygpath -w "$a")" ;;
                esac
                out+=("$a")
            done
            command openssl "${out[@]}"
        }
        ;;
esac

TEST_ROOT="$(mktemp -d /tmp/hy2-tests.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export HY2_TEST_MODE=1
export HY2_CONFIG_DIR="$TEST_ROOT/etc/hysteria"
export HY2_CLIENT_DIR="$TEST_ROOT/root/hy"
export HY2_BACKUP_DIR="$TEST_ROOT/etc/hysteria/backups"
export HY2_MANAGEMENT_BIN="$TEST_ROOT/usr/bin/hy2"
export HY2_BIN="$TEST_ROOT/usr/local/bin/hysteria"
export HY2_SERVICE_FILE="$TEST_ROOT/etc/systemd/system/hysteria-server.service"
export HY2_SERVICE_TEMPLATE_FILE="$TEST_ROOT/etc/systemd/system/hysteria-server@.service"
export HY2_ACME_HOME="$TEST_ROOT/root/.acme.sh"
export HY2_HYSTERIA_HOME_DIR="$TEST_ROOT/var/lib/hysteria"

# shellcheck source=../hysteria.sh
source "$(dirname "$0")/../hysteria.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }

valid_ipv4 203.0.113.10 || fail "valid IPv4 rejected"
! valid_ipv4 203.0.113.999 || fail "invalid IPv4 accepted"
valid_ipv6 2001:db8::1 || fail "valid IPv6 rejected"
valid_ipv6 ::ffff:192.0.2.128 || fail "valid IPv4-mapped IPv6 rejected"
! valid_ipv6 2001:db8::1::2 || fail "IPv6 with two compression markers accepted"
! valid_ipv6 2001:db8:::1 || fail "IPv6 with triple colon accepted"
! valid_ipv6 2001:db8:1:2:3:4:5 || fail "short uncompressed IPv6 accepted"
! valid_ipv6 not:an:ipv6 || fail "non-hex IPv6 accepted"
valid_hostname example.com || fail "valid hostname rejected"
! valid_hostname '-bad.example' || fail "invalid hostname accepted"
valid_port 443 || fail "valid port rejected"
! valid_port 65536 || fail "invalid port accepted"
valid_secret '中文-pass_123' || fail "valid secret rejected"
! valid_secret $'bad\tsecret' || fail "secret containing a control character was accepted"
check_crypto_capabilities || fail "required OpenSSL capabilities are unavailable"

secret_a="$(random_secret 32)"
secret_b="$(random_secret 32)"
assert_eq "${#secret_a}" "32"
assert_eq "${#secret_b}" "32"
[[ "$secret_a" != "$secret_b" ]] || fail "random secrets unexpectedly matched"

quoted="$(yaml_quote 'a"b\c')"
assert_eq "$(yaml_unquote "$quoted")" 'a"b\c'
quoted="$(yaml_quote '  leading and trailing  ')"
assert_eq "$(yaml_unquote "$quoted")" '  leading and trailing  '
assert_eq "$(yaml_unquote "  '  single quoted  '  ")" '  single quoted  '
assert_eq "$(uri_encode '中文 pass')" '%E4%B8%AD%E6%96%87%20pass'

mkdir -p "$CONFIG_DIR" "$CLIENT_DIR"
managed_paths_are_safe || fail "normal managed paths were rejected"
PUBLIC_IP="203.0.113.10"
SERVER_ADDRESS="$PUBLIC_IP"
SERVER_PORT="24443"
AUTH_PASSWORD="auth-only-value"
OBFS_PASSWORD="obfs-only-value"
TLS_SNI="$PUBLIC_IP"
TLS_INSECURE="0"
TLS_PIN_SHA256=""
CERT_MODE="ip-acme"

render_server_config "$CONFIG_FILE"
assert_contains "$CONFIG_FILE" 'listen: :24443'
assert_contains "$CONFIG_FILE" 'password: "auth-only-value"'
assert_contains "$CONFIG_FILE" 'password: "obfs-only-value"'
assert_not_contains "$CONFIG_FILE" 'fastOpen'
assert_not_contains "$CONFIG_FILE" 'bandwidth:'
assert_not_contains "$CONFIG_FILE" 'quic:'

AUTH_PASSWORD=""
OBFS_PASSWORD=""
SERVER_PORT=""
read_current_config || fail "legacy config read failed"
assert_eq "$AUTH_PASSWORD" "auth-only-value"
assert_eq "$OBFS_PASSWORD" "obfs-only-value"
assert_eq "$SERVER_PORT" "24443"

generate_client_configs
assert_contains "$CLIENT_DIR/hy-client.yaml" 'insecure: false'
assert_contains "$CLIENT_DIR/hy-client-tun.yaml" 'ipv4Exclude:'
assert_contains "$CLIENT_DIR/hy-client-tun.yaml" '203.0.113.10/32'
assert_contains "$CLIENT_DIR/hy-client-tun.yaml" 'timeout: 5m'
assert_not_contains "$CLIENT_DIR/url.txt" 'mport='
assert_not_contains "$CLIENT_DIR/url.txt" 'insecure='
assert_contains "$CLIENT_DIR/url.txt" '@203.0.113.10:24443/?'

generate_self_signed_certificate "$PUBLIC_IP"
assert_eq "$TLS_INSECURE" "1"
[[ -n "$TLS_PIN_SHA256" ]] || fail "self-signed fingerprint is empty"
! certificate_is_system_trusted "$CERT_FILE" || fail "self-signed certificate was treated as publicly trusted"
generate_client_configs
assert_contains "$CLIENT_DIR/hy-client.yaml" 'insecure: true'
assert_contains "$CLIENT_DIR/hy-client.yaml" 'pinSHA256:'
assert_contains "$CLIENT_DIR/url.txt" 'insecure=1'
assert_contains "$CLIENT_DIR/url.txt" 'pinSHA256='

PUBLIC_IP="2001:db8::1"
SERVER_ADDRESS="$PUBLIC_IP"
generate_client_configs
assert_contains "$CLIENT_DIR/hy-client-tun.yaml" '- "2000::/3"'
assert_contains "$CLIENT_DIR/hy-client-tun.yaml" '- "2001:db8::1/128"'
assert_contains "$CLIENT_DIR/url.txt" '@[2001:db8::1]:24443/?'
PUBLIC_IP="203.0.113.10"
SERVER_ADDRESS="$PUBLIC_IP"

HYSTERIA_CORE_OWNED="1"
save_installer_state
has_valid_installer_state || fail "fresh installer state was not recognized"
AUTH_PASSWORD="changed"
OBFS_PASSWORD="changed"
read_current_config
assert_eq "$AUTH_PASSWORD" "auth-only-value"
assert_eq "$OBFS_PASSWORD" "obfs-only-value"
assert_eq "$HYSTERIA_CORE_OWNED" "1"

legacy_cert="$TEST_ROOT/legacy-cert.crt"
legacy_key="$TEST_ROOT/legacy-key.pem"
cp "$CERT_FILE" "$legacy_cert"
cp "$KEY_FILE" "$legacy_key"
rm -f "$STATE_FILE"
cat >"$CONFIG_FILE" <<EOF
listen: :35555
tls:
  cert: "$legacy_cert"
  key: "$legacy_key"
auth:
  type: password
  password: "legacy-auth"
obfs:
  type: salamander
  salamander:
    password: "legacy-obfs"
EOF
cat >"$CLIENT_DIR/hy-client.yaml" <<EOF
server: "$PUBLIC_IP:35555"
tls:
  sni: "$PUBLIC_IP"
  insecure: true
EOF
AUTH_PASSWORD=""; OBFS_PASSWORD=""; SERVER_PORT=""; TLS_PIN_SHA256=""
read_current_config || fail "legacy self-signed migration failed"
assert_eq "$CURRENT_CERT_FILE" "$legacy_cert"
assert_eq "$CURRENT_KEY_FILE" "$legacy_key"
assert_eq "$CERT_MODE" "selfsigned"
assert_eq "$TLS_INSECURE" "1"
[[ -n "$TLS_PIN_SHA256" ]] || fail "legacy certificate pin was not recovered"
assert_eq "$AUTH_PASSWORD" "legacy-auth"
assert_eq "$OBFS_PASSWORD" "legacy-obfs"
assert_eq "$SERVER_PORT" "35555"
! ensure_install_scope_safe >/dev/null 2>&1 || fail "unmanaged existing configuration was considered safe to overwrite"

! is_safe_tree_path / || fail "unsafe root path accepted"
! is_safe_tree_path /etc || fail "unsafe /etc path accepted"

mkdir -p "$ACME_HOME"
printf '#!/bin/sh\nexit 0\n' >"$ACME_HOME/acme.sh"
chmod 700 "$ACME_HOME/acme.sh"
ACME_OWNED="0"
install_acme_client || fail "existing acme.sh was incorrectly treated as an install failure"
assert_eq "$ACME_OWNED" "0"

transaction_root="$TEST_ROOT/transaction"
CONFIG_DIR="$transaction_root/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
STATE_FILE="$CONFIG_DIR/installer-state.conf"
CERT_FILE="$CONFIG_DIR/server.crt"
KEY_FILE="$CONFIG_DIR/server.key"
CLIENT_DIR="$transaction_root/root/hy"
BACKUP_DIR="$CONFIG_DIR/backups"
SERVICE_FILE="$transaction_root/systemd/hysteria-server.service"
SERVICE_TEMPLATE_FILE="$transaction_root/systemd/hysteria-server@.service"
MANAGEMENT_BIN="$transaction_root/usr/bin/hy2"
HYSTERIA_BIN="$transaction_root/usr/local/bin/hysteria"
ACME_HOME="$transaction_root/root/.acme.sh"
HYSTERIA_HOME_DIR="$transaction_root/var/lib/hysteria"
mkdir -p "$CONFIG_DIR" "$CLIENT_DIR" "$(dirname "$SERVICE_FILE")" "$(dirname "$MANAGEMENT_BIN")" "$(dirname "$HYSTERIA_BIN")"
printf 'before-config\n' >"$CONFIG_FILE"
printf 'before-client\n' >"$CLIENT_DIR/client.txt"
printf 'before-service\n' >"$SERVICE_FILE"
printf 'before-management\n' >"$MANAGEMENT_BIN"
printf 'before-binary\n' >"$HYSTERIA_BIN"
MOCK_LOG="$TEST_ROOT/mock.log"
: >"$MOCK_LOG"
systemctl() {
    if [[ "$1" == "is-active" && "${3:-}" == "$SERVICE_NAME" ]]; then return 0; fi
    if [[ "$1" == "is-enabled" && "${3:-}" == "$SERVICE_NAME" ]]; then return 0; fi
    if [[ "$1" == "is-active" || "$1" == "is-enabled" ]]; then return 1; fi
    printf 'systemctl %s\n' "$*" >>"$MOCK_LOG"
}
begin_transaction || fail "transaction snapshot failed"
printf 'after-config\n' >"$CONFIG_FILE"
printf 'after-client\n' >"$CLIENT_DIR/client.txt"
printf 'after-service\n' >"$SERVICE_FILE"
rollback_transaction
assert_contains "$CONFIG_FILE" 'before-config'
assert_contains "$CLIENT_DIR/client.txt" 'before-client'
assert_contains "$SERVICE_FILE" 'before-service'
assert_contains "$MOCK_LOG" "systemctl enable $SERVICE_NAME"
assert_contains "$MOCK_LOG" "systemctl start $SERVICE_NAME"
[[ "$TRANSACTION_ACTIVE" == "0" ]] || fail "transaction remained active after rollback"

# --- script update check (mock curl + auto-confirm) ---
curl() {
    local out=""
    while (($# > 0)); do
        [[ "$1" == "-o" ]] && { out="$2"; shift 2; continue; }
        shift
    done
    cat >"$out" <<'EOF'
#!/usr/bin/env bash
readonly SCRIPT_VERSION="9.9.9"
EOF
}
read() { printf 'y\n'; confirm='y'; }
check_script_update || fail "script update check failed"
assert_contains "$MANAGEMENT_BIN" '9.9.9'
[[ -x "$MANAGEMENT_BIN" ]] || fail "updated management binary is not executable"

printf 'All tests passed.\n'
