#!/usr/bin/env bash
# =========================================================
# Side-effect-free tests for gttc.sh country selection and network-stack
# (IPv4-only / IPv6-only / dual-stack) adaptation.
#
# gttc.sh runs check_warp / install_core / show_menu at top level, so it is
# NEVER executed here. Instead the function definitions are extracted into a
# sandbox copy (trailing top-level calls removed, fail-closed if the layout
# changes) and the functions under test are run for real, with:
#   * every write path (tag file, ping script, service files, Xray config)
#     redirected into a throw-away directory under ./state/
#   * system commands (rc-service, rc-update, sleep) replaced by recording
#     stubs and installers (apt-get, systemctl, ...) by tripwires
#   * curl replaced by an OFFLINE double: it answers only the known IP-probe
#     and keep-alive URLs from the simulated stack (FAKE_IP4 / FAKE_IP6) and
#     treats any other URL as a tripwire. No test ever touches the network.
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
# The keep-alive loop ends with `sleep 600`: the stub records it and stops the
# calling script, so exactly one loop iteration runs.
cat > "$SHIM_DIR/sleep" << 'EOF'
#!/bin/bash
printf 'STUB sleep %s\n' "$*" >> "${SHIM_LOG:?}"
kill -TERM "$PPID"
exit 0
EOF
# Tripwires: nothing in country selection may reach these.
for name in wget apt-get apk yum unzip dd mkswap swapon systemctl service sudo bash-install; do
    cat > "$SHIM_DIR/$name" << 'EOF'
#!/bin/bash
printf 'FORBIDDEN %s %s\n' "$(basename "$0")" "$*" >> "${SHIM_LOG:?}"
exit 99
EOF
done
# Offline curl double. FAKE_IP4 / FAKE_IP6 (possibly empty) describe the
# simulated host: a family with no address is unreachable (curl exit 7).
cat > "$SHIM_DIR/curl" << 'EOF'
#!/bin/bash
fam=x
url=""
for a in "$@"; do
    case "$a" in
        -4|-s4) fam=4 ;;
        -6|-s6) fam=6 ;;
        http*)  url="$a" ;;
    esac
done
printf 'CURL fam=%s url=%s args=%s\n' "$fam" "$url" "$*" >> "${SHIM_LOG:?}"
ip4="${FAKE_IP4:-}"
ip6="${FAKE_IP6:-}"
case "$url" in
    https://api.ipify.org)  [ "$fam" = 4 ] && [ -n "$ip4" ] && { echo "$ip4"; exit 0; }; exit 7 ;;
    https://api6.ipify.org) [ "$fam" = 6 ] && [ -n "$ip6" ] && { echo "$ip6"; exit 0; }; exit 7 ;;
    https://ifconfig.me)
        case "$fam" in
            4) [ -n "$ip4" ] && { echo "$ip4"; exit 0; } ;;
            6) [ -n "$ip6" ] && { echo "$ip6"; exit 0; } ;;
            *) [ -n "$ip6$ip4" ] && { echo "${ip6:-$ip4}"; exit 0; } ;;
        esac
        exit 7 ;;
    https://www.google.com/generate_204|https://connectivitycheck.gstatic.com/generate_204|\
    https://clients3.google.com/generate_204|https://location.services.mozilla.com/v1/geolocate|\
    https://play.googleapis.com/generate_204|https://safebrowsing.googleapis.com/v4/threatListUpdates:fetch)
        case "$fam" in
            4) [ -n "$ip4" ] || exit 7 ;;
            6) [ -n "$ip6" ] || exit 7 ;;
            *) [ -n "$ip4$ip6" ] || exit 7 ;;
        esac
        exit 0 ;;
esac
printf 'FORBIDDEN curl %s\n' "$*" >> "$SHIM_LOG"
exit 99
EOF
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
# Runs inside the sandbox. Sources the extracted functions only, then runs the
# single entry function named by GTTC_ENTRY.
: "${SB:?}" "${SHIM_LOG:?}" "${GTTC_FUNCS:?}"
ENTRY="${GTTC_ENTRY:-enable_target_country}"
source "$GTTC_FUNCS"          # note: enables set -e

# Redirect every write path into the sandbox.
PING_SCRIPT="$SB/gttc_ping.sh"
SERVICE_FILE_SYSTEMD="$SB/gttc-ping.service"
SERVICE_FILE_OPENRC="$SB/init.d-gttc-ping"
CONFIG_TAG_FILE="$SB/gttc_country.conf"
find_config() { XRAY_CONF="$SB/xray/config.json"; }

# Anything outside the function under test must never run.
for fn in check_warp install_core setup_shortcut show_menu enable_target_country disable_target_country; do
    [ "$fn" = "$ENTRY" ] && continue
    eval "$fn() { echo \"FORBIDDEN function $fn\" >> \"\$SHIM_LOG\"; return 99; }"
done

for v in PING_SCRIPT SERVICE_FILE_SYSTEMD SERVICE_FILE_OPENRC CONFIG_TAG_FILE; do
    case "${!v}" in "$SB"/*) ;; *) echo "UNSAFE $v=${!v}"; exit 98 ;; esac
done

"$ENTRY"
echo "HARNESS_DONE"
echo "NET_STACK=${NET_STACK:-}"
EOF

# Simulated hosts: name -> FAKE_IP4 / FAKE_IP6 (documentation addresses only;
# the warp* hosts egress through Cloudflare WARP ranges).
set_stack() { # name -> FAKE4 FAKE6
    case "$1" in
        ipv4)      FAKE4=203.0.113.10; FAKE6="" ;;
        ipv6)      FAKE4="";           FAKE6=2001:db8::10 ;;
        dual)      FAKE4=203.0.113.10; FAKE6=2001:db8::10 ;;
        none)      FAKE4="";           FAKE6="" ;;
        warp4)     FAKE4=104.28.10.10; FAKE6="" ;;
        warp6)     FAKE4="";           FAKE6=2a09:bac1:1:2::3 ;;
        dual_warp6) FAKE4=203.0.113.10; FAKE6=2A09:BAC3:1:2::3 ;;
        *) abort "unknown simulated stack $1" ;;
    esac
}

run_case() { # input [stack=ipv4] [entry=enable_target_country] -> sets CASE_DIR, CASE_RC
    local input="$1" stack="${2:-ipv4}" entry="${3:-enable_target_country}"
    set_stack "$stack"
    CASE_DIR="$(mktemp -d "$SANDBOX/case.XXXXXX")"
    mkdir -p "$CASE_DIR/xray"
    cp "$SEED_CONF" "$CASE_DIR/xray/config.json"
    : > "$CASE_DIR/calls.log"
    printf '%s\n' "$input" | env -i \
        PATH="$SHIM_DIR:$(dirname "$PY"):/usr/bin:/bin" HOME="$CASE_DIR" LANG=C.UTF-8 \
        SB="$CASE_DIR" SHIM_LOG="$CASE_DIR/calls.log" GTTC_FUNCS="$FUNCS" GTTC_ENTRY="$entry" \
        FAKE_IP4="$FAKE4" FAKE_IP6="$FAKE6" \
        bash "$HARNESS" > "$CASE_DIR/stdout.txt" 2> "$CASE_DIR/stderr.txt"
    CASE_RC=$?
}

run_ping() { # stack -> runs the generated keep-alive script of CASE_DIR once; sets PING_RC
    set_stack "$1"
    : > "$CASE_DIR/ping_calls.log"
    env -i PATH="$SHIM_DIR:$(dirname "$PY"):/usr/bin:/bin" HOME="$CASE_DIR" LANG=C.UTF-8 \
        SHIM_LOG="$CASE_DIR/ping_calls.log" FAKE_IP4="$FAKE4" FAKE_IP6="$FAKE6" \
        timeout 30 bash "$CASE_DIR/gttc_ping.sh" > "$CASE_DIR/ping_stdout.txt" 2> "$CASE_DIR/ping_stderr.txt"
    PING_RC=$?
}

# JSON helpers over a case's Xray config (python reads, never the shell).
json_query() { # config what -> addresses|ecs|has_ipv4|domains0|domain_strategy
    "$PY" - "$1" "$2" << 'PYEOF' 2>/dev/null || echo "<unreadable>"
import json, re, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
servers = data["dns"]["servers"]
what = sys.argv[2]
if what == "addresses":
    print("|".join(s["address"] if isinstance(s, dict) else s for s in servers))
elif what == "ecs":
    print("|".join(s["clientSubnet"] for s in servers if isinstance(s, dict)))
elif what == "has_ipv4":
    ipv4 = re.compile(r"\d+\.\d+\.\d+\.\d+")
    def walk(o):
        if isinstance(o, dict):
            return any(walk(v) for v in o.values())
        if isinstance(o, list):
            return any(walk(v) for v in o)
        return bool(isinstance(o, str) and ipv4.search(o))
    print("yes" if walk(servers) else "no")
elif what == "domains0":
    print(",".join(servers[0]["domains"]))
elif what == "domain_strategy":
    print(data.get("routing", {}).get("domainStrategy", "<none>"))
PYEOF
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
# Network stack detection
# ---------------------------------------------------------
say ""
say "## Network stack detection (offline curl double)"
test_detect() { # stack expected
    run_case "" "$1" detect_net_stack
    check_contains "detect [$1]: reaches end"        "$CASE_DIR/stdout.txt" "HARNESS_DONE"
    check_contains "detect [$1]: NET_STACK=$2"       "$CASE_DIR/stdout.txt" "NET_STACK=$2"
    check_not_contains "detect [$1]: no forbidden calls" "$CASE_DIR/calls.log" "FORBIDDEN"
}
test_detect ipv4 ipv4
test_detect ipv6 ipv6
test_detect dual dual
test_detect none none
test_detect warp4 ipv4
test_detect warp6 ipv6
test_detect dual_warp6 dual

# ---------------------------------------------------------
# WARP detection on either family
# ---------------------------------------------------------
say ""
say "## WARP detection (v4 104.28.x and v6 2a09:bac0::/29)"
test_warp() { # stack expected_rc
    run_case "" "$1" check_warp
    check_eq "check_warp [$1]: exit status" "$2" "$CASE_RC"
    if [[ "$2" == 1 ]]; then
        check_contains "check_warp [$1]: reports WARP (Traditional)" "$CASE_DIR/stdout.txt" "檢測到目前處於 Cloudflare WARP 環境"
        check_not_contains "check_warp [$1]: does not fall through" "$CASE_DIR/stdout.txt" "HARNESS_DONE"
    else
        check_contains "check_warp [$1]: passes through" "$CASE_DIR/stdout.txt" "HARNESS_DONE"
    fi
    check_not_contains "check_warp [$1]: no forbidden calls" "$CASE_DIR/calls.log" "FORBIDDEN"
}
test_warp ipv4 0
test_warp ipv6 0
test_warp dual 0
test_warp none 0
test_warp warp4 1
test_warp warp6 1
test_warp dual_warp6 1

# ---------------------------------------------------------
# Valid options x network stacks: observable artifacts
# ---------------------------------------------------------
V4_DOH_CF="https://1.1.1.1/dns-query"
V4_PLAIN_G="8.8.8.8"
V6_DOH_CF="https://[2606:4700:4700::1111]/dns-query"
V6_PLAIN_G="2001:4860:4860::8888"

test_option() { # choice country doh doh6 ecs ecs6 lang
    local choice="$1" country="$2" doh="$3" doh6="$4" ecs="$5" ecs6="$6" lang="$7" stack l d
    for stack in ipv4 ipv6 dual none; do
        l="option $choice [$stack]"
        run_case "$choice" "$stack"
        d="$CASE_DIR"
        local tag exp_addr exp_ecs
        tag="$(cat "$d/gttc_country.conf" 2>/dev/null || echo '<missing>')"
        case "$stack" in
            ipv4|none) exp_addr="$doh|$V4_DOH_CF|$V4_PLAIN_G"; exp_ecs="$ecs" ;;
            ipv6)      exp_addr="$doh6|$V6_DOH_CF|$V6_PLAIN_G"; exp_ecs="$ecs6" ;;
            dual)      exp_addr="$doh|$doh|$V4_DOH_CF|$V4_PLAIN_G|$V6_DOH_CF|$V6_PLAIN_G"; exp_ecs="$ecs|$ecs6" ;;
        esac

        check_contains "$l: reaches end of selection (no abort)" "$d/stdout.txt" "HARNESS_DONE"
        check_eq       "$l: country tag file" "$country" "$tag"
        check_eq       "$l: Xray DNS server addresses (DoH + fallbacks)" "$exp_addr" "$(json_query "$d/xray/config.json" addresses)"
        check_eq       "$l: Xray DNS clientSubnet (ECS) per family" "$exp_ecs" "$(json_query "$d/xray/config.json" ecs)"
        check_contains "$l: Google domains kept on country server" "$d/xray/config.json" "geosite:google"
        check_eq       "$l: routing domainStrategy kept" "IPIfNonMatch" "$(json_query "$d/xray/config.json" domain_strategy)"
        check_contains "$l: keep-alive Accept-Language header" "$d/gttc_ping.sh" "Accept-Language: ${lang}\""
        check_contains "$l: success message names country" "$d/stdout.txt" "[${country}]"
        check_contains "$l: services restarted via stubs" "$d/calls.log" "STUB rc-service gttc-ping restart"
        check_not_contains "$l: no forbidden system/installer calls" "$d/calls.log" "FORBIDDEN"
        if [[ "$stack" == ipv6 ]]; then
            check_eq "$l: IPv6-only config contains no IPv4 literal at all" "no" "$(json_query "$d/xray/config.json" has_ipv4)"
        fi
        if [[ "$stack" == ipv4 || "$stack" == none ]]; then
            check_not_contains "$l: IPv4 config has no IPv6 DoH" "$d/xray/config.json" "2606:4700"
        fi
    done
}

say ""
say "## Options 1-6 across IPv4-only / IPv6-only / dual-stack / undetected"
test_option 1 "🇹🇼 台灣"     "https://dns.google/dns-query"    "https://[2001:4860:4860::8888]/dns-query" "168.95.1.1/24"   "2403:a7c0::/32"    "zh-TW,zh;q=0.9,en;q=0.8"
test_option 2 "🇨🇳 中國大陸" "https://dns.alidns.com/dns-query" "https://[2400:3200::1]/dns-query"          "114.240.0.0/16"  "240e::/32"         "zh-CN,zh;q=0.9,en;q=0.8"
test_option 3 "🇯🇵 日本"     "https://dns.google/dns-query"    "https://[2001:4860:4860::8888]/dns-query" "133.242.0.0/16"  "2001:7fa:7::/48"   "ja-JP,ja;q=0.9,en;q=0.8"
test_option 4 "🇲🇴 澳門"     "https://dns.google/dns-query"    "https://[2001:4860:4860::8888]/dns-query" "202.175.3.3/24"  "2402:e940:20::/43" "zh-MO,zh-TW;q=0.9,zh;q=0.8,en;q=0.7"
test_option 5 "🇺🇸 美國"     "https://dns.google/dns-query"    "https://[2001:4860:4860::8888]/dns-query" "64.233.160.0/24" "2600:8000::/24"    "en-US,en;q=0.9"
test_option 6 "🇬🇧 英國"     "https://dns.google/dns-query"    "https://[2001:4860:4860::8888]/dns-query" "81.2.69.0/24"    "2001:8b0::/32"     "en-GB,en;q=0.9"

say ""
say "## Stack reporting in the success message"
run_case "1" ipv4;  check_contains "ipv4 host: message says IPv4-only"   "$CASE_DIR/stdout.txt" "僅 IPv4"
run_case "1" ipv6;  check_contains "ipv6 host: message says IPv6-only"   "$CASE_DIR/stdout.txt" "僅 IPv6"
run_case "1" dual;  check_contains "dual host: message says dual-stack"  "$CASE_DIR/stdout.txt" "雙堆疊 (IPv4 + IPv6)"
run_case "1" none;  check_contains "undetected host: message warns, falls back to IPv4" "$CASE_DIR/stdout.txt" "未能檢測到可用的網路協定"
run_case "1" ipv6
check_not_contains "ipv6 host: never probes 1.1.1.1/8.8.8.8 over the network" "$CASE_DIR/calls.log" "1.1.1.1"

# ---------------------------------------------------------
# Disable: resolvers restored for the detected stack only
# ---------------------------------------------------------
say ""
say "## disable_target_country restores resolvers for the detected stack"
test_disable() { # stack expected_addresses
    local l="disable [$1]"
    run_case "" "$1" disable_target_country
    check_contains "$l: reaches end" "$CASE_DIR/stdout.txt" "HARNESS_DONE"
    check_eq "$l: Xray DNS servers" "$2" "$(json_query "$CASE_DIR/xray/config.json" addresses)"
    check_eq "$l: no country tag file" "absent" "$([[ -e "$CASE_DIR/gttc_country.conf" ]] && echo present || echo absent)"
    check_contains "$l: success message (Traditional)" "$CASE_DIR/stdout.txt" "已成功關閉重新導向模式"
    check_not_contains "$l: no forbidden calls" "$CASE_DIR/calls.log" "FORBIDDEN"
}
test_disable ipv4 "$V4_DOH_CF|$V4_PLAIN_G|1.1.1.1"
test_disable none "$V4_DOH_CF|$V4_PLAIN_G|1.1.1.1"
test_disable ipv6 "$V6_DOH_CF|$V6_PLAIN_G|2606:4700:4700::1111"
test_disable dual "$V4_DOH_CF|$V4_PLAIN_G|1.1.1.1|$V6_DOH_CF|$V6_PLAIN_G|2606:4700:4700::1111"
run_case "" ipv6 disable_target_country
check_eq "disable [ipv6]: config contains no IPv4 literal" "no" "$(json_query "$CASE_DIR/xray/config.json" has_ipv4)"

# ---------------------------------------------------------
# Keep-alive script: probes through the active stack(s)
# ---------------------------------------------------------
say ""
say "## Generated keep-alive script (one loop iteration per run)"
KA_URL="https://www.google.com/generate_204"
test_ping() { # stack expect_fam4 expect_fam6 expect_famx
    local stack="$1" l="keep-alive [$1]" lang="en-US,en;q=0.9" per
    run_case "5" "$stack"
    check_eq "$l: generated script passes bash -n" "ok" "$(bash -n "$CASE_DIR/gttc_ping.sh" 2>/dev/null && echo ok || echo syntax-error)"
    run_ping "$stack"
    check_contains "$l: reached the end-of-iteration sleep" "$CASE_DIR/ping_calls.log" "STUB sleep 600"
    check_not_contains "$l: no forbidden calls" "$CASE_DIR/ping_calls.log" "FORBIDDEN"
    per() { grep -c "fam=$1 url=.*Accept-Language: ${lang}" "$CASE_DIR/ping_calls.log" | tr -d ' '; }
    check_eq "$l: IPv4 keep-alive requests (6 endpoints or none)"       "$2" "$(per 4)"
    check_eq "$l: IPv6 keep-alive requests (6 endpoints or none)"       "$3" "$(per 6)"
    check_eq "$l: family-agnostic keep-alive requests (undetected only)" "$4" "$(per x)"
    if [[ "$2" == 6 ]]; then
        check_contains "$l: IPv4 hits the google 204 endpoint" "$CASE_DIR/ping_calls.log" "fam=4 url=$KA_URL"
    fi
    if [[ "$3" == 6 ]]; then
        check_contains "$l: IPv6 hits the google 204 endpoint" "$CASE_DIR/ping_calls.log" "fam=6 url=$KA_URL"
    fi
}
test_ping ipv4 6 0 0
test_ping ipv6 0 6 0
test_ping dual 6 6 0
test_ping none 0 0 6

test_ping_warp() { # stack
    local l="keep-alive [$1]"
    run_case "5" ipv4
    run_ping "$1"
    check_eq "$l: exits 1 on WARP" "1" "$PING_RC"
    check_contains "$l: reports WARP" "$CASE_DIR/ping_stdout.txt" "Detected WARP environment"
    check_eq "$l: sends no keep-alive requests" "0" "$(grep -c 'Accept-Language' "$CASE_DIR/ping_calls.log" | tr -d ' ')"
    check_not_contains "$l: never reaches sleep" "$CASE_DIR/ping_calls.log" "STUB sleep"
}
test_ping_warp warp4
test_ping_warp warp6
test_ping_warp dual_warp6

check_not_contains "gttc.sh does not hardcode curl -s4" "$GTTC" "curl -s4"
check_not_contains "gttc.sh does not hardcode curl -s6" "$GTTC" "curl -s6"

# ---------------------------------------------------------
# Invalid input: cancelled, nothing written, no system calls at all
# ---------------------------------------------------------
test_invalid() { # input description
    local input="$1" l="invalid input '$2'"
    run_case "$input"
    local d="$CASE_DIR"
    check_contains "$l: reports invalid selection" "$d/stdout.txt" "無效選擇"
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
check_contains "menu option 1 (Traditional 台灣)"        "$CASE_DIR/stdout.txt" "1. 🇹🇼 台灣 (Taiwan)"
check_contains "menu option 2 (Traditional 中國大陸)"    "$CASE_DIR/stdout.txt" "2. 🇨🇳 中國大陸 (China)"
check_contains "menu option 3 (日本)"                    "$CASE_DIR/stdout.txt" "3. 🇯🇵 日本 (Japan)"
check_contains "menu option 4 (Traditional 澳門)"        "$CASE_DIR/stdout.txt" "4. 🇲🇴 澳門 (Macao)"
check_contains "menu option 5 (Traditional 美國)"        "$CASE_DIR/stdout.txt" "5. 🇺🇸 美國 (United States)"
check_contains "menu option 6 is the UK with flag (Traditional 英國)" "$CASE_DIR/stdout.txt" "6. 🇬🇧 英國 (United Kingdom)"
check_contains "menu option 6 labelled experimental (Traditional 實驗性)" "$CASE_DIR/stdout.txt" "[實驗性]"
check_contains "menu title (Traditional)"               "$CASE_DIR/stdout.txt" "請選擇目標國家 / 地區"
check_not_contains "menu has no Simplified 英国 for UK"    "$CASE_DIR/stdout.txt" "英国 (United Kingdom)"
check_not_contains "menu has no Simplified 实验性"         "$CASE_DIR/stdout.txt" "实验性"
check_contains "prompt range is [1-6] (Traditional)"    "$GTTC" '請選擇 [1-6]: '
check_not_contains "old Simplified prompt removed"      "$GTTC" '请选择 [1-6]: '
check_not_contains "old prompt range [1-5] removed"     "$GTTC" '請選擇 [1-5]: '
check_eq "header lists UK among supported regions" "1" "$(sed -n '1,6p' "$GTTC" | grep -c '🇬🇧')"
check_eq "header names UK in Traditional 英國 (實驗性)" "1" "$(sed -n '1,6p' "$GTTC" | grep -c '🇬🇧 英國 (實驗性)')"
check_eq "header lists all regions in Traditional" "1" "$(sed -n '1,6p' "$GTTC" | grep -c '🇹🇼 台灣 | 🇨🇳 中國大陸 | 🇯🇵 日本 | 🇲🇴 澳門 | 🇺🇸 美國')"
check_not_contains "gttc.sh has no Simplified 英国/实验性" "$GTTC" "英国"
check_not_contains "gttc.sh has no Simplified 实验性"      "$GTTC" "实验性"
check_contains "self-download URL points at wongjai fork" "$GTTC" "https://raw.githubusercontent.com/wongjai/GoogleToThisCountry/main/gttc.sh"
check_eq "no self-download URL left on upstream" "0" "$(grep -c 'edmond1294/GoogleToThisCountry/main/gttc.sh' "$GTTC" | tr -d ' ')"
check_contains "README one-line install uses wongjai fork" "$README" "bash <(curl -sSL https://raw.githubusercontent.com/wongjai/GoogleToThisCountry/main/gttc.sh)"
check_eq "README install command not on upstream" "0" "$(grep -c 'bash <(curl.*edmond1294' "$README" | tr -d ' ')"

# ---------------------------------------------------------
# Traditional Chinese localisation of gttc.sh
# ---------------------------------------------------------
say ""
say "## Traditional Chinese (繁體中文 書面語) in gttc.sh"
check_contains "status: enabled"            "$GTTC" "已開啟"
check_contains "status: disabled"           "$GTTC" "已關閉"
check_contains "status: not enabled"        "$GTTC" "未開啟"
check_contains "download message"           "$GTTC" "正在下載核心服務二進位檔案..."
check_contains "low-memory message"         "$GTTC" "檢測到虛擬機記憶體不足"
check_contains "menu prompt"                "$GTTC" "請選擇選項 [0-3]: "
check_contains "menu entry 1"               "$GTTC" "開啟/切換 目標國家重新導向"
check_contains "invalid option message"     "$GTTC" "無效選項，請重新輸入！"

# Characters that exist only in Simplified Chinese; none may remain in gttc.sh.
SIMPLIFIED_ONLY="湾国请选择标脚开关闭务载内检测忆体网络设启动误错无项际构环赖装议栈协发单键复线页终从对应时间现将为与会这来说并经过实验隐缓满临创钟机虚拟释态认状条户续级码"
simplified_hits() { # file -> unique Simplified-only characters found
    "$PY" - "$1" "$SIMPLIFIED_ONLY" << 'PYEOF'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
print("".join(sorted({c for c in text if c in sys.argv[2]})))
PYEOF
}
check_eq "gttc.sh contains no Simplified-only characters" "" "$(simplified_hits "$GTTC")"
# Guard the guard: the detector must flag a known Simplified sample.
SAMPLE="$SANDBOX/simplified_sample.txt"; printf '请选择目标国家 台湾\n' > "$SAMPLE"
check_eq "Simplified detector flags a Simplified sample" "国择标湾请选" "$(simplified_hits "$SAMPLE")"
printf '請選擇目標國家 台灣\n' > "$SAMPLE"
check_eq "Simplified detector passes a Traditional sample" "" "$(simplified_hits "$SAMPLE")"

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

say ""
say "## README dual-stack section (Traditional Chinese)"
README_DS="$SANDBOX/readme_dual_stack.md"
sed -n '/<!-- dual-stack:begin -->/,/<!-- dual-stack:end -->/p' "$README" > "$README_DS"
check_eq "README has a dual-stack section between markers" "1" "$([[ -s "$README_DS" ]] && echo 1 || echo 0)"
check_contains "README DS: names the three stacks"        "$README_DS" "僅 IPv4"
check_contains "README DS: names IPv6-only"               "$README_DS" "僅 IPv6"
check_contains "README DS: names dual-stack"              "$README_DS" "雙堆疊"
check_contains "README DS: documents v6 TW prefix"        "$README_DS" "2403:a7c0::/32"
check_contains "README DS: documents v6 CN prefix"        "$README_DS" "240e::/32"
check_contains "README DS: documents v6 JP prefix"        "$README_DS" "2001:7fa:7::/48"
check_contains "README DS: documents v6 MO prefix"        "$README_DS" "2402:e940:20::/43"
check_contains "README DS: documents v6 US prefix"        "$README_DS" "2600:8000::/24"
check_contains "README DS: documents v6 UK prefix"        "$README_DS" "2001:8b0::/32"
check_contains "README DS: IPv6-only avoids IPv4 resolvers" "$README_DS" "1.1.1.1"
check_contains "README DS: keep-alive probes both families" "$README_DS" "保活"
check_contains "README DS: states WARP v6 detection"      "$README_DS" "2a09:bac0::/29"
check_contains "README DS: honest about GitHub on IPv6-only" "$README_DS" "NAT64"
check_eq "README dual-stack section has no Simplified-only characters" "" "$(simplified_hits "$README_DS")"

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
