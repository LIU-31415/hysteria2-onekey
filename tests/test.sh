#!/usr/bin/env bash
# Variables assigned here are consumed indirectly by functions from hysteria.sh.
# shellcheck disable=SC2034

set -Eeuo pipefail
trap 'printf "FAIL at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Git Bash (MSYS2/MINGW) 会把 /CN=... 之类的参数误转成 Windows 路径；
# 关闭自动转换后，路径参数需手动转成 Windows 形式（openssl 是原生程序）。
# Linux 下无副作用（uname 不匹配则不设置）。
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        export MSYS2_ARG_CONV_EXCL='*'
        openssl() {
            local a
            local -a openssl_args=()
            for a in "$@"; do
                case "$a" in
                    /tmp/*) a="$(cygpath -w "$a")" ;;
                esac
                openssl_args+=("$a")
            done
            command openssl "${openssl_args[@]}"
        }
        # Windows 没有 Linux 的 root 用户；本地只检查复制和权限模式。
        # Linux 下仍执行真实的属主设置，实机属主验收见 TESTING.md。
        install() {
            local -a install_args=()
            while (($#)); do
                case "$1" in
                    -o|-g) shift 2 ;;
                    *) install_args+=("$1"); shift ;;
                esac
            done
            command install "${install_args[@]}"
        }
        ;;
esac

TEST_ROOT="$(mktemp -d /tmp/hy2-tests.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export HY2_TEST_MODE=1
export HY2_TEST_ROOT="$TEST_ROOT"
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
! valid_port 18446744073709551617 || fail "overflowing port accepted"
! valid_port 000443 || fail "overlong port accepted"
! valid_ipv4 $'1.2.3.4\n9.9.9.9' || fail "multiline IPv4 accepted"
! valid_ipv4 '1.2.3.4.' || fail "IPv4 with a trailing dot accepted"
valid_secret '中文-pass_123' || fail "valid secret rejected"
! valid_secret $'bad\tsecret' || fail "secret containing a control character was accepted"
version_at_least 2.9.2 2.9.2 || fail "equal safe version was rejected"
version_at_least 2.12.2 2.9.2 || fail "newer version was rejected"
! version_at_least 2.9.1 2.9.2 || fail "unsafe old version was accepted"
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
(
    od() { return 1; }
    if uri_encode nonempty; then fail "URI encoding swallowed an od failure"; fi
)
(
    require_root() { return 0; }
    CONFIG_FILE="$TEST_ROOT/missing-config"
    quick_install() { fail "EOF triggered the default install"; }
    main_menu </dev/null >/dev/null
    if prompt_value example default </dev/null 2>/dev/null; then fail "EOF was treated as Enter"; fi
    if prompt_port_settings </dev/null 2>/dev/null; then fail "port prompt ignored EOF"; fi
    if prompt_certificate_strategy <<<'2' >/dev/null; then fail "domain prompt ignored EOF"; fi
)
if bash -s -- --version <"$(dirname "$0")/../hysteria.sh" >"$TEST_ROOT/stdin.log" 2>&1; then
    fail "stdin invocation silently succeeded"
fi
assert_contains "$TEST_ROOT/stdin.log" '请先下载为 hysteria.sh'

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
assert_not_contains "$CONFIG_FILE" 'sniff:'
assert_not_contains "$CONFIG_FILE" 'masquerade:'

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
assert_contains "$CLIENT_DIR/hy-client-tun.yaml" 'macOS: change tun.name'
assert_not_contains "$CLIENT_DIR/url.txt" 'mport='
assert_not_contains "$CLIENT_DIR/url.txt" 'insecure='
assert_contains "$CLIENT_DIR/url.txt" '@203.0.113.10:24443/?'
(
    SERVER_ADDRESS="2001:db8::10"
    generate_client_configs
    assert_contains "$CLIENT_DIR/hy-client-tun.yaml" '203.0.113.10/32'
    assert_contains "$CLIENT_DIR/hy-client-tun.yaml" '2001:db8::10/128'
    client_tun_excludes_server || fail "diagnosis did not find both server exclusions"
    sed -i '/2001:db8::10\/128/d' "$CLIENT_DIR/hy-client-tun.yaml"
    if client_tun_excludes_server; then fail "diagnosis accepted a missing connection IP exclusion"; fi
)
generate_client_configs

CERT_MODE="selfsigned"
generate_self_signed_certificate "$PUBLIC_IP"
assert_eq "$TLS_INSECURE" "1"
[[ -n "$TLS_PIN_SHA256" ]] || fail "self-signed fingerprint is empty"
! certificate_is_system_trusted "$CERT_FILE" || fail "self-signed certificate was treated as publicly trusted"
generate_client_configs
assert_contains "$CLIENT_DIR/hy-client.yaml" 'insecure: true'
assert_contains "$CLIENT_DIR/hy-client.yaml" 'pinSHA256:'
assert_contains "$CLIENT_DIR/url.txt" 'insecure=1'
assert_contains "$CLIENT_DIR/url.txt" 'pinSHA256='

# Detect the leaf public key, not the CA signature algorithm.
compat_log="$TEST_ROOT/certificate-compatibility.log"
warn_certificate_client_compatibility "$CERT_FILE" >"$compat_log" 2>&1
[[ ! -s "$compat_log" ]] || fail "RSA certificate triggered a compatibility warning"
ed_cert="$TEST_ROOT/ed25519.crt"
ed_key="$TEST_ROOT/ed25519.key"
openssl req -x509 -nodes -newkey ed25519 -days 2 \
    -keyout "$ed_key" -out "$ed_cert" -subj "/CN=$PUBLIC_IP" \
    -addext "subjectAltName=IP:$PUBLIC_IP" >/dev/null 2>&1
warn_certificate_client_compatibility "$ed_cert" >"$compat_log" 2>&1
assert_contains "$compat_log" 'Ed25519 公钥'
assert_contains "$compat_log" 'ECDSA 或 RSA'
ecdsa_cert="$TEST_ROOT/ecdsa.crt"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 2 \
    -keyout "$TEST_ROOT/ecdsa.key" -out "$ecdsa_cert" -subj "/CN=$PUBLIC_IP" >/dev/null 2>&1
warn_certificate_client_compatibility "$ecdsa_cert" >"$compat_log" 2>&1
[[ ! -s "$compat_log" ]] || fail "ECDSA certificate triggered a compatibility warning"
openssl req -new -key "$KEY_FILE" -out "$TEST_ROOT/rsa.csr" -subj "/CN=$PUBLIC_IP" >/dev/null 2>&1
openssl x509 -req -in "$TEST_ROOT/rsa.csr" -CA "$ed_cert" -CAkey "$ed_key" \
    -set_serial 1 -days 2 -out "$TEST_ROOT/rsa-ed25519-signed.crt" >/dev/null 2>&1
warn_certificate_client_compatibility "$TEST_ROOT/rsa-ed25519-signed.crt" >"$compat_log" 2>&1
[[ ! -s "$compat_log" ]] || fail "Ed25519 CA signature was mistaken for the leaf public key"

(
    CERT_FILE="$TEST_ROOT/imported.crt"; KEY_FILE="$TEST_ROOT/imported.key"
    if configure_existing_certificate "$ed_cert" "$ed_key" "$PUBLIC_IP" >"$compat_log" 2>&1; then
        fail "compatibility warning allowed an untrusted certificate to be imported"
    fi
    [[ ! -e "$CERT_FILE" ]] || fail "untrusted certificate was copied before rejection"
    # Trust is mocked only for the import/diagnosis integration checks below.
    certificate_is_system_trusted() { return 0; }
    configure_existing_certificate "$ed_cert" "$ed_key" "$PUBLIC_IP" >"$compat_log" 2>&1
    assert_contains "$compat_log" 'Ed25519 公钥'
    validate_certificate_pair "$CERT_FILE" "$KEY_FILE" "$PUBLIC_IP" || fail "imported certificate pair is invalid"
    assert_eq "$TLS_INSECURE" "0"
    assert_eq "$TLS_PIN_SHA256" ""
    if configure_existing_certificate "$ed_cert" "$TEST_ROOT/ecdsa.key" "$PUBLIC_IP" >"$compat_log" 2>&1; then
        fail "mismatched private key was accepted during import"
    fi
    HYSTERIA_BIN="$TEST_ROOT/diagnostic-hysteria"
    printf '#!/bin/sh\nprintf "Hysteria 2 version v2.12.3\\n"\n' >"$HYSTERIA_BIN"
    chmod 700 "$HYSTERIA_BIN"
    require_root() { return 0; }
    read_current_config() { return 0; }
    systemctl() { return 0; }
    ss() { printf ':24443\n'; }
    CERT_MODE="existing"
    diagnose >"$compat_log" 2>&1 || fail "compatibility warning was treated as a diagnostic failure"
    assert_contains "$compat_log" 'Ed25519 公钥'
    assert_not_contains "$compat_log" '[FAIL]'
)

PUBLIC_IP="2001:db8::1"
SERVER_ADDRESS="$PUBLIC_IP"
generate_client_configs
assert_contains "$CLIENT_DIR/hy-client-tun.yaml" '- "2000::/3"'
assert_contains "$CLIENT_DIR/hy-client-tun.yaml" '- "2001:db8::1/128"'
assert_contains "$CLIENT_DIR/url.txt" '@[2001:db8::1]:24443/?'
PUBLIC_IP="203.0.113.10"
SERVER_ADDRESS="$PUBLIC_IP"

HYSTERIA_CORE_OWNED="1"
ACME_CERT_OWNED="1"
save_installer_state
has_valid_installer_state || fail "fresh installer state was not recognized"
AUTH_PASSWORD="changed"
OBFS_PASSWORD="changed"
read_current_config
assert_eq "$AUTH_PASSWORD" "auth-only-value"
assert_eq "$OBFS_PASSWORD" "obfs-only-value"
assert_eq "$HYSTERIA_CORE_OWNED" "1"
assert_eq "$ACME_CERT_OWNED" "1"
(
    STATE_FILE="$TEST_ROOT/incomplete-state.conf"
    printf 'version=%s\n' "$SCRIPT_VERSION" >"$STATE_FILE"
    if state_get missing; then fail "missing state key returned success"; fi
    if load_installer_state; then fail "incomplete installer state was accepted"; fi
    begin_transaction() { fail "incomplete state reached an installation transaction"; }
    if perform_install selfsigned 2>/dev/null; then fail "incomplete state was overwritten by reinstall"; fi
    load_resource_ownership
    assert_eq "$ACME_OWNED" 0
    assert_eq "$HYSTERIA_CORE_OWNED" 0
)
(
    CONFIG_DIR="$TEST_ROOT/../outside-test-root"
    if test_paths_are_safe; then fail "test path outside root was accepted"; fi
    if is_safe_tree_path "$CONFIG_DIR"; then fail "unsafe test tree was accepted"; fi
)

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
(
    for version in 3.1.3 3.1.4; do
        printf '#!/bin/sh\nprintf "v%s\\n"\n' "$version" >"$ACME_HOME/acme.sh"
        if [[ "$version" == 3.1.3 ]]; then
            if check_acme_version 2>/dev/null; then fail "old acme.sh was accepted for short-lived certificates"; fi
            ensure_cron_available() { return 0; }
            acme_has_certificate() { fail "old acme.sh reached certificate reuse"; }
            if issue_acme_certificate "$PUBLIC_IP" ip-acme 2>/dev/null; then fail "old acme.sh reached issuance"; fi
        else
            check_acme_version || fail "supported acme.sh was rejected"
        fi
    done
)

ACME_TEST_LOG="$TEST_ROOT/acme.log"
export HY2_TEST_ACME_LOG="$ACME_TEST_LOG"
cat >"$ACME_HOME/acme.sh" <<'EOF'
#!/bin/sh
case "$1" in
    --list)
        printf 'Main_Domain KeyLength SAN_Domains CA Created Renew\n'
        printf 'example.com ec-256 no letsencrypt now later\n'
        ;;
    --remove) printf '%s\n' "$*" >>"$HY2_TEST_ACME_LOG" ;;
esac
EOF
chmod 700 "$ACME_HOME/acme.sh"
: >"$ACME_TEST_LOG"
acme_has_certificate example.com || fail "existing ACME order was not found"
! acme_has_certificate not-example.com || fail "partial ACME identifier match was accepted"
CERT_MODE="domain-acme"; TLS_SNI="example.com"; ACME_OWNED="0"; ACME_CERT_OWNED="0"
remove_acme_assets "$TLS_SNI"
[[ ! -s "$ACME_TEST_LOG" ]] || fail "unowned ACME order was removed"
ACME_CERT_OWNED="1"
remove_acme_assets "$TLS_SNI"
assert_contains "$ACME_TEST_LOG" '--remove -d example.com --ecc'
(
    ACME_OWNED=1
    CERT_MODE=selfsigned
    cat >"$ACME_HOME/acme.sh" <<'EOF'
#!/bin/sh
case "$1" in
    --list) exit 1 ;;
    --uninstall) printf 'unexpected-uninstall\n' >>"$HY2_TEST_ACME_LOG" ;;
esac
EOF
    if remove_acme_assets unused 2>/dev/null; then fail "failed ACME listing was treated as empty"; fi
    if cleanup_previous_acme_certificate ip-acme old-ip 0 2>/dev/null; then fail "previous ACME cleanup ignored listing failure"; fi
    FAILED_ACME_IDENTIFIER=""; FAILED_ACME_CERT_OWNED=0
    if cleanup_failed_acme_attempt 2>/dev/null; then fail "failed-attempt cleanup ignored listing failure"; fi
    [[ -f "$ACME_HOME/acme.sh" ]] || fail "ACME home was deleted after a failed listing"
    assert_not_contains "$ACME_TEST_LOG" 'unexpected-uninstall'
    cat >"$ACME_HOME/acme.sh" <<'EOF'
#!/bin/sh
case "$1" in
    --list) printf 'Main_Domain KeyLength SAN_Domains CA Created Renew\n' ;;
    --uninstall) exit 1 ;;
esac
EOF
    if cleanup_owned_acme_client 2>/dev/null; then fail "failed ACME uninstall returned success"; fi
    [[ -f "$ACME_HOME/acme.sh" ]] || fail "ACME account was removed after uninstall failed"
)

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

# A failed restore must keep the snapshot for manual recovery.
begin_transaction || fail "second transaction snapshot failed"
FAILED_SNAPSHOT="$TRANSACTION_DIR"
FAIL_RESTORE_COPY="1"
cp() {
    if [[ "$FAIL_RESTORE_COPY" == "1" && "${3:-}" == "$FAILED_SNAPSHOT/config_dir" ]]; then return 1; fi
    command cp "$@"
}
printf 'after-config\n' >"$CONFIG_FILE"
if rollback_transaction; then fail "incomplete rollback was reported as successful"; fi
assert_contains "$CONFIG_FILE" 'after-config'
[[ -d "$FAILED_SNAPSHOT" ]] || fail "failed rollback deleted its recovery snapshot"
[[ "$TRANSACTION_ACTIVE" == "0" ]] || fail "failed rollback remained active"
unset -f cp
safe_remove_tree "$FAILED_SNAPSHOT"
TRANSACTION_DIR=""

# Validate every record before changing any live path.
begin_transaction || fail "manifest-corruption snapshot failed"
FAILED_SNAPSHOT="$TRANSACTION_DIR"
sed -i '/^config_dir=/d' "$TRANSACTION_DIR/manifest"
printf 'keep-live-config\n' >"$CONFIG_FILE"
printf 'keep-live-client\n' >"$CLIENT_DIR/client.txt"
if rollback_transaction; then fail "missing snapshot record was accepted"; fi
assert_contains "$CONFIG_FILE" 'keep-live-config'
assert_contains "$CLIENT_DIR/client.txt" 'keep-live-client'
[[ -d "$FAILED_SNAPSHOT" ]] || fail "corrupt snapshot was discarded"
safe_remove_tree "$FAILED_SNAPSHOT"
TRANSACTION_DIR=""
(
    printf() {
        if [[ "$1" == '%s=1\n' || "$1" == '%s=0\n' ]]; then return 1; fi
        builtin printf "$@"
    }
    if begin_transaction; then fail "manifest write failure was ignored"; fi
    assert_contains "$CONFIG_FILE" 'keep-live-config'
    [[ -z "$TRANSACTION_DIR" && "$TRANSACTION_ACTIVE" == 0 ]] || fail "failed snapshot was not cleaned"
)
signal_snapshot="$(mktemp -d /tmp/hy2-transaction.XXXXXX)"
printf 'snapshot-secret\n' >"$signal_snapshot/partial"
if (
    TRANSACTION_DIR="$signal_snapshot"
    TRANSACTION_SNAPSHOTTING=1
    on_signal
) 2>/dev/null; then fail "signal handler returned success"; fi
[[ ! -d "$signal_snapshot" ]] || fail "interrupted snapshot was left behind"

(
    begin_transaction || fail "rename-failure snapshot failed"
    printf 'keep-on-rename-failure\n' >"$CONFIG_FILE"
    mv() {
        if [[ "${3:-}" == "${CONFIG_DIR}.restore.$$" ]]; then return 1; fi
        command mv "$@"
    }
    if rollback_transaction; then fail "failed replacement returned success"; fi
    assert_contains "$CONFIG_FILE" 'keep-on-rename-failure'
    [[ -d "$TRANSACTION_DIR" ]] || fail "failed replacement discarded its snapshot"
    safe_remove_tree "$TRANSACTION_DIR"
)

# A crontab filtering error must not overwrite unrelated jobs.
(
    mkdir -p "$HY2_TEST_ROOT/etc"
    cron_file="$HY2_TEST_ROOT/etc/crontab"
    printf '%s\n' 'unrelated-cron-job' '0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1' >"$cron_file"
    grep() { if [[ "$1" == -Fvx ]]; then return 2; fi; command grep "$@"; }
    if remove_legacy_crontab_entry; then fail "crontab read error returned success"; fi
    assert_contains "$cron_file" 'unrelated-cron-job'
    unset -f grep
    remove_legacy_crontab_entry
    assert_contains "$cron_file" 'unrelated-cron-job'
    assert_not_contains "$cron_file" 'acme.sh --cron'
)
(
    empty_dir="$TEST_ROOT/empty-directory"
    mkdir -p "$empty_dir"
    rmdir() { return 1; }
    if remove_empty_directory "$empty_dir"; then fail "empty-directory deletion failure was ignored"; fi
    printf 'keep\n' >"$empty_dir/unowned.txt"
    remove_empty_directory "$empty_dir" || fail "non-owned file was treated as a deletion error"
    assert_contains "$empty_dir/unowned.txt" keep
)

# Restart loops fail health checks even when both samples report active.
(
    restart_marker="$TEST_ROOT/restart-sample"
    systemctl() {
        if [[ "$1" == show ]]; then
            if [[ -f "$restart_marker" ]]; then printf '1\n'; else touch "$restart_marker"; printf '0\n'; fi
        else return 0; fi
    }
    sleep() { return 0; }
    if check_service_health; then fail "health check accepted a restarted service"; fi
    systemctl() { if [[ "$1" == show ]]; then printf '0\n'; else return 0; fi; }
    check_service_health || fail "healthy service was rejected"
)

# A late uninstall failure retains state and permits retry without config.yaml.
(
    require_root() { return 0; }
    cleanup_legacy_artifacts() { return 0; }
    remove_acme_assets() { return 0; }
    systemctl() { return 0; }
    PUBLIC_IP=203.0.113.10; SERVER_ADDRESS="$PUBLIC_IP"; SERVER_PORT=24443
    AUTH_PASSWORD=uninstall-auth; OBFS_PASSWORD=uninstall-obfs
    CERT_MODE=selfsigned; TLS_SNI="$PUBLIC_IP"; TLS_INSECURE=1; TLS_PIN_SHA256=example-pin
    ACME_CHALLENGE_PORT=""; ACME_OWNED=0; ACME_CERT_OWNED=0
    HYSTERIA_CORE_OWNED=1; HYSTERIA_USER_OWNED=0; UNINSTALL_PENDING=0
    save_installer_state
    rm() {
        if [[ "${2:-}" == "$MANAGEMENT_BIN" ]]; then return 1; fi
        command rm "$@"
    }
    if uninstall_hysteria <<<'UNINSTALL'; then fail "failed uninstall returned success"; fi
    [[ -f "$STATE_FILE" && -f "$MANAGEMENT_BIN" ]] || fail "retry state or management command was deleted"
    [[ ! -e "$CONFIG_FILE" ]] || fail "uninstall failure was not exercised after config removal"
    assert_eq "$(state_get uninstall_pending)" 1
    if read_current_config 2>/dev/null; then fail "pending uninstall was treated as a usable install"; fi
    if quick_install 0 2>/dev/null; then fail "pending uninstall was overwritten by installation"; fi
    unset -f rm
    uninstall_hysteria <<<'UNINSTALL' || fail "partial uninstall could not be resumed"
    [[ ! -e "$STATE_FILE" && ! -e "$MANAGEMENT_BIN" ]] || fail "completed uninstall left retry files"
)

# Installing an older local copy must not overwrite the management command.
mkdir -p "$CONFIG_DIR" "$(dirname "$MANAGEMENT_BIN")" "$(dirname "$HYSTERIA_BIN")"
printf 'readonly SCRIPT_VERSION="99.0.0"\n' >"$MANAGEMENT_BIN"
if install_management_command 2>/dev/null; then fail "management command downgrade was accepted"; fi
assert_contains "$MANAGEMENT_BIN" '99.0.0'
rm -f "$MANAGEMENT_BIN"

cat >"$HYSTERIA_BIN" <<'EOF'
#!/bin/sh
printf 'Hysteria 2 version v2.12.2\n'
EOF
chmod 700 "$HYSTERIA_BIN"
assert_eq "$(hysteria_core_version)" "2.12.2"

# --install is idempotent; only --reinstall may enter the installation path.
PREPARE_MARKER="$TEST_ROOT/prepare-called"
require_root() { return 0; }
has_valid_installer_state() { return 0; }
prepare_runtime() { : >"$PREPARE_MARKER"; return 1; }
mkdir -p "$CONFIG_DIR"
: >"$CONFIG_FILE"
quick_install 0 || fail "idempotent install returned failure"
[[ ! -e "$PREPARE_MARKER" ]] || fail "idempotent install entered the installation path"
if quick_install 1; then fail "mock reinstall unexpectedly completed"; fi
[[ -e "$PREPARE_MARKER" ]] || fail "explicit reinstall did not enter the installation path"

printf 'All tests passed.\n'
