#!/usr/bin/env bash
# shellcheck shell=bash
# Shared utilities for xraybox. Sourced by the main script.

APP="xraybox"
VERSION="2.0.0"
STATE_VERSION=2

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$SCRIPT_DIR"
DATA_DIR="${XRAYBOX_HOME:-$ROOT_DIR/data}"
STATE_FILE="$DATA_DIR/state.json"
CONFIG_FILE="$DATA_DIR/config.json"
PID_FILE="$DATA_DIR/xray.pid"
PROC_FILE="$DATA_DIR/process.json"
LOG_DIR="$DATA_DIR/logs"
XRAY_LOG="$LOG_DIR/xray.log"
LOCK_FILE="$DATA_DIR/.lock"
TUN_STATE_FILE="$DATA_DIR/tun-routes.json"

# Default path from the user's v2rayN install; can be overridden.
DEFAULT_XRAY="$HOME/data/tools/v2rayN-linux-64/bin/xray/xray"
XRAY_BIN="${XRAYBOX_XRAY:-$DEFAULT_XRAY}"

# Populated by resolve_xray.
XRAY_VERSION=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
    C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""
    C_CYAN=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

msg()  { printf '%s\n' "$*"; }
info() { printf '%s %s\n' "${C_BLUE}→${C_RESET}" "$*"; }
ok()   { printf '%s %s\n' "${C_GREEN}✓${C_RESET}" "$*"; }
warn() { printf '%s %s\n' "${C_YELLOW}!${C_RESET}" "$*" >&2; }
err()  { printf '%s %s\n' "${C_RED}✗${C_RESET}" "$*" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    local c
    for c in "$@"; do
        have "$c" || die "Не найдена команда: $c"
    done
}

pause() {
    [[ -t 0 ]] || return 0
    printf '\n%s' "${C_DIM}Enter — продолжить...${C_RESET}"
    read -r _ || true
}

confirm() {
    local prompt="${1:-Продолжить?}"
    if [[ -t 0 ]] && have gum; then
        gum confirm --affirmative "Да" --negative "Нет" "$prompt"
        return $?
    fi
    [[ -t 0 ]] || return 1
    local answer
    read -r -p "$prompt [y/N] " answer || return 1
    [[ "$answer" =~ ^[YyДд]$ ]]
}

# UI helpers (gum if available)
ui_title() {
    if have gum && [[ -t 1 ]]; then
        gum style --bold --foreground 212 "$*"
    else
        printf '%s\n' "$*"
    fi
}

ui_ok() {
    if have gum && [[ -t 1 ]]; then
        gum style --foreground 42 "✓ $*"
    else
        ok "$*"
    fi
}

ui_warn() {
    if have gum && [[ -t 1 ]]; then
        gum style --foreground 214 "! $*"
    else
        warn "$*"
    fi
}

ui_err() {
    if have gum && [[ -t 1 ]]; then
        gum style --foreground 196 "✗ $*"
    else
        err "$*"
    fi
}

ui_info() {
    if have gum && [[ -t 1 ]]; then
        gum style --foreground 39 "→ $*"
    else
        info "$*"
    fi
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

json_escape() {
    jq -Rn --arg s "$1" '$s'
}

sha1() {
    printf '%s' "$1" | sha1sum | cut -d' ' -f1
}

url_decode() {
    local v="$1"
    # jq's @urid handles %XX; '+' is a literal plus in URI queries.
    jq -rn --arg v "$v" '$v | @urid' 2>/dev/null
}

b64_decode() {
    local s="$1" pad
    s="${s//-/+}"
    s="${s//_//}"
    s="$(printf '%s' "$s" | tr -d '\r\n[:space:]')"
    pad=$(( (4 - ${#s} % 4) % 4 ))
    if (( pad > 0 )); then
        s+="$(printf '%*s' "$pad" '' | tr ' ' '=')"
    fi
    printf '%s' "$s" | base64 -d 2>/dev/null
}

human_duration() {
    local secs=${1:-0}
    local d=$((secs / 86400))
    local h=$(((secs % 86400) / 3600))
    local m=$(((secs % 3600) / 60))
    local s=$((secs % 60))
    if (( d > 0 )); then printf '%dд %dч %dм' "$d" "$h" "$m"
    elif (( h > 0 )); then printf '%dч %dм' "$h" "$m"
    elif (( m > 0 )); then printf '%dм %dс' "$m" "$s"
    else printf '%dс' "$s"
    fi
}

human_ts() {
    local ts=${1:-0}
    (( ts > 0 )) || { printf '—'; return; }
    date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$ts"
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

is_root() { (( EUID == 0 )); }

port_open() {
    local host="$1" port="$2"
    (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null
}

wait_port() {
    local host="$1" port="$2" timeout="${3:-10}" i
    for ((i = 0; i < timeout * 10; i++)); do
        port_open "$host" "$port" && return 0
        sleep 0.1
    done
    return 1
}

wait_interface() {
    local name="$1" timeout="${2:-10}" i
    for ((i = 0; i < timeout * 10; i++)); do
        # /sys/class/net can be stale inside a fresh network namespace, so
        # fall back to `ip link` when available.
        if [[ -d "/sys/class/net/$name" ]]; then
            return 0
        fi
        if have ip && ip link show dev "$name" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

default_iface() {
    have ip || return 1
    ip -4 route show default 2>/dev/null \
        | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

mask_url() {
    local url="$1" rest host
    rest="${url#*://}"
    host="${rest%%/*}"
    if [[ "$rest" == */* ]]; then
        printf '%s://%s/…' "${url%%://*}" "$host"
    else
        printf '%s://%s' "${url%%://*}" "$host"
    fi
}

# ---------------------------------------------------------------------------
# Dependencies / paths
# ---------------------------------------------------------------------------

resolve_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        return 0
    fi
    XRAY_BIN="$(command -v xray 2>/dev/null || true)"
    [[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]] || die \
        "Xray не найден. Укажите путь: XRAYBOX_XRAY=/path/to/xray $APP ..."
}

xray_version() {
    if [[ -z "$XRAY_VERSION" ]]; then
        resolve_xray
        XRAY_VERSION="$("$XRAY_BIN" version 2>/dev/null | head -n1)"
    fi
    printf '%s' "$XRAY_VERSION"
}

require_runtime() {
    require_cmd jq curl base64 sha1sum flock
    resolve_xray
}

init_data() {
    mkdir -p "$DATA_DIR" "$LOG_DIR" || die "Не удалось создать $DATA_DIR"
    chmod 700 "$DATA_DIR" "$LOG_DIR" 2>/dev/null || true
    if [[ ! -f "$STATE_FILE" ]]; then
        local tmp
        tmp="$(mktemp "$DATA_DIR/.state-init.XXXXXX")" || die "mktemp failed"
        jq -n '{
            version: 2,
            servers: [],
            subscriptions: [],
            settings: {
                active: "",
                mixed_port: 12080,
                api_port: 10085,
                log_level: "warning",
                allow_lan: false,
                direct_domains: [],
                tun: false,
                tun_name: "xraybox0",
                tun_mtu: 1500,
                tun_gateway: "172.19.0.1/30",
                tun_metric: 1
            }
        }' >"$tmp" || { rm -f "$tmp"; die "jq failed"; }
        chmod 600 "$tmp"
        mv -f "$tmp" "$STATE_FILE"
    fi
    chmod 600 "$STATE_FILE" 2>/dev/null || true
    if ! jq -e '.version == 2 and (.servers|type=="array") and (.settings|type=="object")' \
        "$STATE_FILE" >/dev/null 2>&1; then
        die "Повреждён state.json: $STATE_FILE"
    fi
}

# ---------------------------------------------------------------------------
# State access
# ---------------------------------------------------------------------------

state_update() {
    # state_update '<jq filter>' [jq options...]
    local filter="$1"
    shift
    init_data
    local tmp
    exec 9>"$LOCK_FILE" || return 1
    flock -x 9 || { exec 9>&-; return 1; }
    tmp="$(mktemp "$DATA_DIR/.state.XXXXXX")" || { exec 9>&-; return 1; }
    if jq "$@" "$filter" "$STATE_FILE" >"$tmp"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$STATE_FILE"
        exec 9>&-
        return 0
    fi
    rm -f "$tmp"
    exec 9>&-
    return 1
}

state_write() {
    # state_write '<json>'
    init_data
    local json="$1" tmp
    exec 9>"$LOCK_FILE" || return 1
    flock -x 9 || { exec 9>&-; return 1; }
    tmp="$(mktemp "$DATA_DIR/.state.XXXXXX")" || { exec 9>&-; return 1; }
    if printf '%s\n' "$json" | jq -e . >"$tmp"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$STATE_FILE"
        exec 9>&-
        return 0
    fi
    rm -f "$tmp"
    exec 9>&-
    return 1
}

state_get() { jq -r "$1" "$STATE_FILE" 2>/dev/null; }

setting_get() {
    jq -r --arg k "$1" '.settings[$k] // empty' "$STATE_FILE" 2>/dev/null
}

server_count() { jq -r '.servers | length' "$STATE_FILE" 2>/dev/null; }

active_id() { jq -r '.settings.active // ""' "$STATE_FILE" 2>/dev/null; }

active_server() {
    local id
    id="$(active_id)"
    [[ -n "$id" ]] || return 1
    jq -c --arg id "$id" '.servers[] | select(.id == $id)' "$STATE_FILE" 2>/dev/null
}

server_by_id() {
    jq -c --arg id "$1" '.servers[] | select(.id == $id)' "$STATE_FILE" 2>/dev/null
}

server_ids() {
    jq -r '.servers[].id' "$STATE_FILE" 2>/dev/null
}

server_tags() {
    jq -c '[.servers[].id | "srv_" + .]' "$STATE_FILE" 2>/dev/null
}

server_label() {
    # server_label '<server json>' [index] [active-id]
    local srv="$1" idx="${2:-}" active="${3:-}"
    local name transport security host port ping_ms ping_str mark=" "
    name="$(jq -r '.name' <<<"$srv")"
    transport="$(jq -r '.transport // "tcp"' <<<"$srv")"
    security="$(jq -r '.security // "none"' <<<"$srv")"
    host="$(jq -r '.host' <<<"$srv")"
    port="$(jq -r '.port' <<<"$srv")"
    ping_ms="$(jq -r '.ping // empty' <<<"$srv")"

    if [[ -n "$active" && "$(jq -r '.id' <<<"$srv")" == "$active" ]]; then
        mark="●"
    fi

    if [[ -z "$ping_ms" ]]; then
        ping_str="  —   "
    elif (( ping_ms <= 0 )); then
        ping_str="✗ недоступен"
    else
        ping_str="${ping_ms} ms"
    fi

    local prefix=""
    [[ -n "$idx" ]] && prefix="$(printf '%2s. ' "$idx")"
    printf '%s[%s] %-36s  %-10s  %-13s  %s:%s' \
        "$prefix" "$mark" "$name" "$ping_str" "[$transport/$security]" "$host" "$port"
}

resolve_server() {
    # Prints server JSON. Returns 1 if not found, 2 if ambiguous.
    local sel="$1" n match
    n="$(server_count)"
    (( n > 0 )) || return 1
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
        (( sel >= 1 && sel <= n )) || return 1
        jq -c --argjson i "$((sel - 1))" '.servers[$i]' "$STATE_FILE"
        return 0
    fi
    match="$(jq -c --arg s "$sel" '
        [.servers[] | select(.id == $s)] | if length == 1 then .[0] else empty end
    ' "$STATE_FILE")"
    if [[ -n "$match" ]]; then printf '%s\n' "$match"; return 0; fi
    match="$(jq -c --arg s "$sel" '
        [.servers[] | select(.id | startswith($s))] |
        if length == 1 then .[0] else empty end
    ' "$STATE_FILE")"
    if [[ -n "$match" ]]; then printf '%s\n' "$match"; return 0; fi
    match="$(jq -c --arg s "$sel" '
        [.servers[] | select(.name == $s)] |
        if length == 1 then .[0] else empty end
    ' "$STATE_FILE")"
    if [[ -n "$match" ]]; then printf '%s\n' "$match"; return 0; fi
    local lower="${sel,,}"
    # Bash case folding understands Unicode (unlike jq's ascii_downcase), so
    # Cyrillic server names can be matched in any case.
    local ids count
    ids="$(jq -r '.servers[] | [.id, .name] | @tsv' "$STATE_FILE" | while IFS=$'\t' read -r id name; do
        [[ "${name,,}" == *"$lower"* ]] && printf '%s\n' "$id"
    done)"
    count="$(printf '%s\n' "$ids" | grep -c . || true)"
    if (( count == 1 )); then
        server_by_id "$ids"
        return 0
    fi
    (( count > 1 )) && return 2
    return 1
}

resolve_server_or_die() {
    local srv rc
    srv="$(resolve_server "$1")"; rc=$?
    if (( rc == 0 )); then printf '%s\n' "$srv"; return 0; fi
    if (( rc == 2 )); then
        err "Несколько серверов подходят под «$1». Уточните имя или используйте номер."
    else
        err "Сервер не найден: $1"
    fi
    return 1
}

list_servers() {
    local n active i srv
    n="$(server_count)"
    active="$(active_id)"
    if (( n == 0 )); then
        msg "Серверов пока нет. Добавьте ключ: $APP add 'vless://...'"
        return 0
    fi
    printf '%s\n' "${C_DIM}   #  имя                              транспорт      адрес${C_RESET}"
    for ((i = 1; i <= n; i++)); do
        srv="$(jq -c --argjson i "$((i - 1))" '.servers[$i]' "$STATE_FILE")"
        server_label "$srv" "$i" "$active"
        printf '\n'
    done
}

# ---------------------------------------------------------------------------
# Network / subscriptions
# ---------------------------------------------------------------------------

fetch_url() {
    local url="$1" out err
    local errfile
    errfile="$(mktemp "$DATA_DIR/.curl.XXXXXX")"
    if out="$(curl -fsSL --compressed --max-time 30 --retry 2 \
        --user-agent "$APP/$VERSION" --max-filesize 5242880 \
        "$url" 2>"$errfile")"; then
        rm -f "$errfile"
        printf '%s' "$out"
        return 0
    fi
    local detail
    detail="$(tr '\n' ' ' <"$errfile" | cut -c1-300)"
    rm -f "$errfile"
    err "Не удалось скачать подписку $(mask_url "$url"): $detail"
    return 1
}

decode_subscription() {
    # Reads raw subscription; prints URI lines. Returns:
    #   1 undecodable, 2 Clash YAML
    local raw="$1" dec
    if grep -q 'vless://' <<<"$raw"; then
        printf '%s\n' "$raw"
        return 0
    fi
    if grep -qiE '^[[:space:]]*proxies:' <<<"$raw"; then
        return 2
    fi
    dec="$(b64_decode "$raw")"
    if [[ -n "$dec" ]] && grep -q 'vless://' <<<"$dec"; then
        printf '%s\n' "$dec"
        return 0
    fi
    if [[ -n "$dec" ]] && grep -qiE '^[[:space:]]*proxies:' <<<"$dec"; then
        return 2
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------

rotate_log() {
    [[ -f "$XRAY_LOG" ]] || return 0
    local size
    size="$(stat -c %s "$XRAY_LOG" 2>/dev/null || echo 0)"
    if (( size > 5242880 )); then
        mv -f "$XRAY_LOG" "$XRAY_LOG.1" 2>/dev/null || true
        chmod 600 "$XRAY_LOG.1" 2>/dev/null || true
    fi
}

json_type() { jq -r "type" <<<"$1" 2>/dev/null; }

# Prints a short error line from a command log.
last_error_line() {
    local file="$1"
    [[ -f "$file" ]] || { printf 'нет файла'; return; }
    grep -E 'Failed|failed|error|Error|FATAL|panic' "$file" | tail -n 1 | cut -c1-400
}
