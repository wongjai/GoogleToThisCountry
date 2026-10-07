#!/usr/bin/env bash
# =========================================================
# Side-effect-free tests for gttc.sh country selection.
#
# gttc.sh runs check_warp / install_core / show_menu at top level, so it is
# NEVER executed here. Instead the function definitions are extracted into a
# sandbox copy (trailing top-level calls removed, fail-closed if the layout
# changes) and enable_target_country is run for real, with:
#   * every write path (tag file, ping script, service files, Xray config)
#     redirected into a throw-away directory under ./state/
#   * system commands (rc-service, rc-update) replaced by recording stubs and
#     installers/network tools (curl, apt-get, systemctl, ...) by tripwires
#   * a before/after snapshot of the live gttc/xray file footprint
#
# Usage: bash tests/test_country_selection.sh
# Log:   logs/test-<UTC timestamp>.log (gitignored); override with GTTC_TEST_LOG
# =========================================================

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GTTC="$ROOT/gttc.sh"
README="$ROOT/README.md"
STATE="$ROOT/state"
LOGS="$ROOT/logs"
mkdir -p "$STATE" "$LOGS"
export TMPDIR="$STATE"   # keep mktemp output inside the project, never /tmp

LOG_FILE="${GTTC_TEST_LOG:-$LOGS/test-$(date -u +%Y%m%dT%H%M%SZ).log}"
: > "$LOG_FILE"

PASS=0
FAIL=0

say() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
ok()  { PASS=$((PASS + 1)); say "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); say "FAIL: $1${2:+ -- $2}"; }

check_eq() { # name expected actual
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
check_contains() { # name file needle
    if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1" "[$3] not found in ${2#"$ROOT"/}"; fi
}
check_not_contains() { # name file needle
    if grep -qF -- "$3" "$2" 2>/dev/null; then bad "$1" "[$3] unexpectedly found in ${2#"$ROOT"/}"; else ok "$1"; fi
}

abort() { say "ABORT: $*"; exit 2; }

say "# gttc country-selection tests $(date -u +%FT%TZ)"
say "# repo HEAD: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo n/a) (dirty files: $(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l))"

# ---------------------------------------------------------
# Sandbox: extracted functions, shims, harness
# ---------------------------------------------------------
PY="/usr/bin/python3"
[[ -x "$PY" ]] || PY="$(command -v python3)" || abort "python3 not found"

SANDBOX="$(mktemp -d "$STATE/sandbox.XXXXXX")"
SHIM_DIR="$SANDBOX/shims"
FUNCS="$SANDBOX/gttc_funcs.sh"
HARNESS="$SANDBOX/harness.sh"
SEED_CONF="$SANDBOX/seed_config.json"
mkdir -p "$SHIM_DIR"

# Fail closed: the only top-level code in gttc.sh must be the three trailing calls.
mapfile -t LAST3 < <(grep -v '^[[:space:]]*$' "$GTTC" | tail -n 3)
[[ "${LAST3[*]}" == "check_warp install_core show_menu" ]] \
    || abort "gttc.sh trailing top-level calls changed (${LAST3[*]}); review extraction before running tests"
awk '!/^(check_warp|install_core|show_menu)$/' "$GTTC" > "$FUNCS"
if grep -nE '^(check_warp|install_core|show_menu)$' "$FUNCS" >/dev/null; then
    abort "top-level invocation still present in extracted functions"
fi
if bash -n "$FUNCS"; then ok "extracted functions pass bash -n"; else abort "extracted functions fail bash -n"; fi

# Recording stubs: calls that restart_service/create_ping_service legitimately make.
for name in rc-service rc-update; do
    cat > "$SHIM_DIR/$name" << 'EOF'
#!/bin/bash
printf 'STUB %s %s\n' "$(basename "$0")" "$*" >> "${SHIM_LOG:?}"
exit 0
EOF
done
# Tripwires: nothing in country selection may reach these.
for name in curl wget apt-get apk yum unzip dd mkswap swapon systemctl service sudo bash-install; do
    cat > "$SHIM_DIR/$name" << 'EOF'
#!/bin/bash
printf 'FORBIDDEN %s %s\n' "$(basename "$0")" "$*" >> "${SHIM_LOG:?}"
exit 99
EOF
done
chmod +x "$SHIM_DIR"/*

cat > "$SEED_CONF" << 'EOF'
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF

cat > "$HARNESS" << 'EOF'
#!/bin/bash
# Runs inside the sandbox. Sources the extracted functions only.
: "${SB:?}" "${SHIM_LOG:?}" "${GTTC_FUNCS:?}"
source "$GTTC_FUNCS"          # note: enables set -e

# Redirect every write path into the sandbox.
PING_SCRIPT="$SB/gttc_ping.sh"
SERVICE_FILE_SYSTEMD="$SB/gttc-ping.service"
SERVICE_FILE_OPENRC="$SB/init.d-gttc-ping"
CONFIG_TAG_FILE="$SB/gttc_country.conf"
find_config() { XRAY_CONF="$SB/xray/config.json"; }

# Anything outside country selection must never run.
for fn in check_warp install_core setup_shortcut show_menu disable_target_country; do
    eval "$fn() { echo \"FORBIDDEN function $fn\" >> \"\$SHIM_LOG\"; return 99; }"
done

for v in PING_SCRIPT SERVICE_FILE_SYSTEMD SERVICE_FILE_OPENRC CONFIG_TAG_FILE; do
    case "${!v}" in "$SB"/*) ;; *) echo "UNSAFE $v=${!v}"; exit 98 ;; esac
done

enable_target_country
echo "HARNESS_DONE"
EOF

run_case() { # choice -> sets CASE_DIR, CASE_RC
    CASE_DIR="$(mktemp -d "$SANDBOX/case.XXXXXX")"
    mkdir -p "$CASE_DIR/xray"
    cp "$SEED_CONF" "$CASE_DIR/xray/config.json"
    : > "$CASE_DIR/calls.log"
    printf '%s\n' "$1" | env -i \
        PATH="$SHIM_DIR:$(dirname "$PY"):/usr/bin:/bin" HOME="$CASE_DIR" LANG=C.UTF-8 \
        SB="$CASE_DIR" SHIM_LOG="$CASE_DIR/calls.log" GTTC_FUNCS="$FUNCS" \
        bash "$HARNESS" > "$CASE_DIR/stdout.txt" 2> "$CASE_DIR/stderr.txt"
    CASE_RC=$?
}

json_dns() { # config key
    "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["dns"]["servers"][0][sys.argv[2]])' "$1" "$2" 2>/dev/null || echo "<unreadable>"
}

# ---------------------------------------------------------
# Live footprint snapshot (proof the tests touched no live files)
# ---------------------------------------------------------
LIVE_PATHS=(
    /etc/xray/config.json /usr/local/etc/xray/config.json
    /etc/v2ray/config.json /usr/local/etc/v2ray/config.json
    /etc/gttc_country.conf /usr/local/bin/gttc_ping.sh /usr/local/bin/gttc_manager.sh
    /usr/local/bin/gttc /etc/systemd/system/gttc-ping.service /etc/init.d/gttc-ping
)
live_snapshot() {
    local p
    for p in "${LIVE_PATHS[@]}"; do
        stat -c '%n inode=%i size=%s mtime=%Y ctime=%Z' "$p" 2>/dev/null || echo "$p MISSING"
    done
}
LIVE_BEFORE="$(live_snapshot)"

# ---------------------------------------------------------
# Valid options: observable artifacts per option
# ---------------------------------------------------------
test_option() { # choice country doh ecs lang
    local choice="$1" country="$2" doh="$3" ecs="$4" lang="$5" l="option $1"
    run_case "$choice"
    local d="$CASE_DIR" tag
    tag="$(cat "$d/gttc_country.conf" 2>/dev/null || echo '<missing>')"

    check_contains "$l: reaches end of selection (no abort)" "$d/stdout.txt" "HARNESS_DONE"
    check_eq       "$l: country tag file" "$country" "$tag"
    check_eq       "$l: Xray DNS server address (DoH)" "$doh" "$(json_dns "$d/xray/config.json" address)"
    check_eq       "$l: Xray DNS clientSubnet (ECS)" "$ecs" "$(json_dns "$d/xray/config.json" clientSubnet)"
    check_contains "$l: keep-alive Accept-Language header" "$d/gttc_ping.sh" "Accept-Language: ${lang}\""
    check_contains "$l: success message names country" "$d/stdout.txt" "[${country}]"
    check_contains "$l: services restarted via stubs" "$d/calls.log" "STUB rc-service gttc-ping restart"
    check_not_contains "$l: no forbidden system/installer calls" "$d/calls.log" "FORBIDDEN"
}

say ""
say "## Original options 1-5 (regression) and new option 6 (UK)"
test_option 1 "🇹🇼 台湾"     "https://dns.google/dns-query"    "168.95.1.1/24"    "zh-TW,zh;q=0.9,en;q=0.8"
test_option 2 "🇨🇳 中国大陆" "https://dns.alidns.com/dns-query" "114.240.0.0/16"    "zh-CN,zh;q=0.9,en;q=0.8"
test_option 3 "🇯🇵 日本"     "https://dns.google/dns-query"    "133.242.0.0/16"   "ja-JP,ja;q=0.9,en;q=0.8"
test_option 4 "🇲🇴 澳门"     "https://dns.google/dns-query"    "202.175.3.3/24"   "zh-MO,zh-TW;q=0.9,zh;q=0.8,en;q=0.7"
test_option 5 "🇺🇸 美国"     "https://dns.google/dns-query"    "64.233.160.0/24"  "en-US,en;q=0.9"
test_option 6 "🇬🇧 United Kingdom" "https://dns.google/dns-query" "81.2.69.0/24"  "en-GB,en;q=0.9"

# ---------------------------------------------------------
# Invalid input: cancelled, nothing written, no system calls at all
# ---------------------------------------------------------
test_invalid() { # input description
    local input="$1" l="invalid input '$2'"
    run_case "$input"
    local d="$CASE_DIR"
    check_contains "$l: reports invalid selection" "$d/stdout.txt" "无效选择"
    check_contains "$l: returns to caller" "$d/stdout.txt" "HARNESS_DONE"
    check_eq "$l: no country tag written" "absent" "$([[ -e "$d/gttc_country.conf" ]] && echo present || echo absent)"
    check_eq "$l: Xray config untouched" "same" "$(cmp -s "$SEED_CONF" "$d/xray/config.json" && echo same || echo changed)"
    check_eq "$l: no config backup created" "absent" "$([[ -e "$d/xray/config.json.bak" ]] && echo present || echo absent)"
    check_eq "$l: no keep-alive script written" "absent" "$([[ -e "$d/gttc_ping.sh" ]] && echo present || echo absent)"
    check_eq "$l: no stubbed or forbidden commands called" "0" "$(wc -l < "$d/calls.log" | tr -d ' ')"
}

say ""
say "## Invalid inputs"
test_invalid "0"   "0"
test_invalid "7"   "7 (just past the new range)"
test_invalid ""    "empty"
test_invalid "abc" "abc"
test_invalid "-1"  "-1"
test_invalid "66"  "66"
test_invalid "6x"  "6x"
test_invalid "０"  "full-width zero"
# Not tested as invalid: padded input such as "1 ". `read` strips surrounding
# whitespace, so upstream already treats it as a valid "1".

# ---------------------------------------------------------
# Menu text (captured stdout of the real function) and static checks
# ---------------------------------------------------------
say ""
say "## Menu, header, fork URLs"
run_case "0"
for n in 1 2 3 4 5 6; do
    check_eq "menu lists option $n" "1" "$(grep -cE "^ ${n}\. " "$CASE_DIR/stdout.txt" | tr -d ' ')"
done
check_contains "menu option 6 is the UK with flag (Traditional 英國)" "$CASE_DIR/stdout.txt" "6. 🇬🇧 英國 (United Kingdom)"
check_contains "menu option 6 labelled experimental (Traditional 實驗性)" "$CASE_DIR/stdout.txt" "[實驗性]"
check_not_contains "menu has no Simplified 英国 for UK"    "$CASE_DIR/stdout.txt" "英国 (United Kingdom)"
check_not_contains "menu has no Simplified 实验性"         "$CASE_DIR/stdout.txt" "实验性"
check_contains "prompt range is [1-6]"                  "$GTTC" '请选择 [1-6]: '
check_not_contains "old prompt range [1-5] removed"     "$GTTC" '请选择 [1-5]: '
check_eq "header lists UK among supported regions" "1" "$(sed -n '1,6p' "$GTTC" | grep -c '🇬🇧')"
check_eq "header names UK in Traditional 英國 (實驗性)" "1" "$(sed -n '1,6p' "$GTTC" | grep -c '🇬🇧 英國 (實驗性)')"
check_not_contains "gttc.sh has no Simplified 英国/实验性" "$GTTC" "英国"
check_not_contains "gttc.sh has no Simplified 实验性"      "$GTTC" "实验性"
check_contains "upstream Simplified prose retained (option 1 台湾)" "$CASE_DIR/stdout.txt" "1. 🇹🇼 台湾"
check_contains "self-download URL points at wongjai fork" "$GTTC" "https://raw.githubusercontent.com/wongjai/GoogleToThisCountry/main/gttc.sh"
check_eq "no self-download URL left on upstream" "0" "$(grep -c 'edmond1294/GoogleToThisCountry/main/gttc.sh' "$GTTC" | tr -d ' ')"
check_contains "README one-line install uses wongjai fork" "$README" "bash <(curl -sSL https://raw.githubusercontent.com/wongjai/GoogleToThisCountry/main/gttc.sh)"
check_eq "README install command not on upstream" "0" "$(grep -c 'bash <(curl.*edmond1294' "$README" | tr -d ' ')"

# ---------------------------------------------------------
# README honesty checks for the experimental UK option
# ---------------------------------------------------------
say ""
say "## README experimental-UK labelling"
check_contains "README labels UK experimental (EN)"       "$README" "EXPERIMENTAL"
check_contains "README labels UK experimental (ZH, Traditional 實驗性)" "$README" "實驗性"
check_contains "README names UK in Traditional 英國"      "$README" "英國"
check_not_contains "README has no Simplified 实验性"       "$README" "实验性"
check_not_contains "README has no Simplified 英国"         "$README" "英国"
check_contains "README ZH: prefix verified as GB (RIPE)"  "$README" "已對照 RIPE 資料庫驗證"
check_contains "README ZH: prefix is GB (英國) address space" "$README" "屬於 GB（英國）"
check_contains "README ZH: not guaranteed to fix Google"  "$README" "不保證"
check_contains "README retains upstream Simplified prose" "$README" "多地区支持"
check_contains "README documents the UK ECS prefix"       "$README" "81.2.69.0/24"
check_contains "README links the RIPE verification URL"   "$README" "rest.db.ripe.net"
check_contains "README says script configures Xray"       "$README" "Xray"
check_contains "README says sing-box is not configured"   "$README" "sing-box"
check_contains "README: ECS cannot guarantee Google geolocation" "$README" "does not guarantee"
check_contains "README inherits upstream limitations"     "$README" "upstream"

# ---------------------------------------------------------
# Footprint: tests changed nothing live
# ---------------------------------------------------------
say ""
say "## Isolation"
LIVE_AFTER="$(live_snapshot)"
check_eq "live gttc/xray file footprint unchanged by tests" "$LIVE_BEFORE" "$LIVE_AFTER"

say ""
say "RESULT: ${PASS} passed, ${FAIL} failed (log: ${LOG_FILE#"$ROOT"/}, sandbox: ${SANDBOX#"$ROOT"/})"
[[ "$FAIL" -eq 0 ]]
