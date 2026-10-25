#!/usr/bin/env bash
# shellcheck shell=bash
# Xray process management, API status, TUN setup and diagnostics.

PRIV=()

read_pid() {
    local pid
    [[ -r "$PID_FILE" ]] || return 1
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$pid"
}

is_running() {
    local pid comm state child
    pid="$(read_pid)" || return 1
    [[ -d "/proc/$pid" ]] || { rm -f "$PID_FILE" "$PROC_FILE"; return 1; }
    state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
    if [[ "$state" == "Z" ]]; then
        rm -f "$PID_FILE" "$PROC_FILE"
        return 1
    fi
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    if [[ "$comm" == "sudo" ]]; then
        child="$(pgrep -P "$pid" -x xray 2>/dev/null | head -n1 || true)"
        if [[ -n "$child" ]]; then
            printf '%s' "$child" >"$PID_FILE"
            pid="$child"
            comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        fi
    fi
    [[ "$comm" == "xray" ]] || { rm -f "$PID_FILE" "$PROC_FILE"; return 1; }
    return 0
}

pid_owner() {
    local pid="$1"
    stat -c %u "/proc/$pid" 2>/dev/null || true
}

ensure_sudo() {
    PRIV=()
    is_root && return 0
    have sudo || die "Для TUN нужен root, но sudo не найден."
    if sudo -n true 2>/dev/null; then
        PRIV=(sudo -n)
        return 0
    fi
    if [[ -t 0 ]]; then
        printf '%s\n' "${C_YELLOW}Для TUN нужны права root. Введите пароль sudo:${C_RESET}"
        sudo -v || die "sudo не подтверждён"
        PRIV=(sudo -n)
        return 0
    fi
    die "TUN требует root. Запустите из терминала или настройте sudo без пароля."
}

priv_run() {
    if (( ${#PRIV[@]} > 0 )); then
        "${PRIV[@]}" "$@"
    else
        "$@"
    fi
}

tun_cleanup_routes() {
    # Removes only the routes/interface recorded in TUN_STATE_FILE.
    [[ -f "$TUN_STATE_FILE" ]] || return 0
    local name gateway metric
    name="$(jq -r '.name // empty' "$TUN_STATE_FILE" 2>/dev/null || true)"
    gateway="$(jq -r '.gateway // empty' "$TUN_STATE_FILE" 2>/dev/null || true)"
    metric="$(jq -r '.metric // 1' "$TUN_STATE_FILE" 2>/dev/null || true)"
    if [[ -z "$name" ]]; then
        rm -f "$TUN_STATE_FILE"
        return 0
    fi
    if ! is_root && ! sudo -n true 2>/dev/null; then
        ensure_sudo
    fi
    priv_run ip route del default dev "$name" metric "$metric" 2>/dev/null || true
    [[ -n "$gateway" ]] && priv_run ip addr del "$gateway" dev "$name" 2>/dev/null || true
    priv_run ip link set dev "$name" down 2>/dev/null || true
    priv_run ip link del "$name" 2>/dev/null || true
    rm -f "$TUN_STATE_FILE"
    return 0
}

tun_setup_routes() {
    local name gateway metric
    name="$(setting_get tun_name)"; [[ -n "$name" ]] || name=xraybox0
    gateway="$(setting_get tun_gateway)"; [[ -n "$gateway" ]] || gateway="172.19.0.1/30"
    metric="$(setting_get tun_metric)"; [[ -n "$metric" ]] || metric=1

    if ! wait_interface "$name" 10; then
        err "Xray не создал TUN-интерфейс $name"
        return 1
    fi
    if ! priv_run ip link set dev "$name" up; then
        err "Не удалось поднять $name"
        return 1
    fi
    priv_run ip addr add "$gateway" dev "$name" 2>/dev/null || true
    priv_run ip route del default dev "$name" metric "$metric" 2>/dev/null || true
    if ! priv_run ip route add default dev "$name" metric "$metric" 2>/dev/null; then
        # A default route with our metric may already exist; check it.
        if ! priv_run ip route show default dev "$name" 2>/dev/null | grep -q .; then
            err "Не удалось добавить default route через $name"
            return 1
        fi
    fi
    if ! priv_run ip route show default dev "$name" 2>/dev/null | grep -q .; then
        err "Маршрут через $name не появился"
        return 1
    fi
    jq -n --arg name "$name" --arg gateway "$gateway" --argjson metric "$metric" \
        --argjson ts "$(date +%s)" \
        '{name:$name,gateway:$gateway,metric:$metric,created_at:$ts}' \
        >"$TUN_STATE_FILE" || true
    chmod 600 "$TUN_STATE_FILE" 2>/dev/null || true
    ok "TUN поднят: $name ($gateway), default route metric $metric"
    return 0
}

api_health() {
    is_running || return 1
    resolve_xray 2>/dev/null || return 1
    local port
    port="$(setting_get api_port)"; [[ -n "$port" ]] || port=10085
    timeout 5 "$XRAY_BIN" api lso -s "127.0.0.1:$port" >/dev/null 2>&1
}

start_xray() {
    init_data
    require_runtime
    require_cmd nohup

    if is_running; then
        local a
        a="$(active_id)"
        if [[ -n "$a" ]]; then
            api_set_balancer "$a" quiet || true
        fi
        ok "Xray уже запущен (PID $(cat "$PID_FILE"))"
        return 0
    fi

    local n
    n="$(server_count)"
    (( n > 0 )) || die "Нет серверов. Сначала добавьте ключ: $APP add 'vless://...'"

    local tun enabled
    tun="$(setting_get tun)"; [[ "$tun" == "true" ]] || tun=false
    if [[ "$tun" == "true" ]]; then
        ensure_sudo
        tun_cleanup_routes
        [[ -n "$(default_iface || true)" ]] || die "Не найден default interface для TUN"
    fi

    local mixed api
    mixed="$(setting_get mixed_port)"; [[ -n "$mixed" ]] || mixed=12080
    api="$(setting_get api_port)"; [[ -n "$api" ]] || api=10085
    if port_open 127.0.0.1 "$mixed"; then
        die "Порт $mixed уже занят. Остановите другой VPN/прокси или смените порт в настройках."
    fi
    if port_open 127.0.0.1 "$api"; then
        die "API-порт $api уже занят. Смените api_port в настройках."
    fi

    generate_config || die "Не удалось сгенерировать конфиг"
    rotate_log
    {
        printf '\n===== %s start =====\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'xray: %s\n' "$(xray_version)"
        printf 'config: %s\n' "$CONFIG_FILE"
        printf 'tun: %s\n' "$tun"
    } >>"$XRAY_LOG" 2>/dev/null || true

    local -a cmd
    if [[ "$tun" == "true" ]] && ! is_root; then
        cmd=("${PRIV[@]}" "$XRAY_BIN" run -c "$CONFIG_FILE")
    else
        cmd=("$XRAY_BIN" run -c "$CONFIG_FILE")
    fi

    nohup "${cmd[@]}" >>"$XRAY_LOG" 2>&1 </dev/null &
    local pid=$!
    printf '%s' "$pid" >"$PID_FILE"
    chmod 600 "$PID_FILE" 2>/dev/null || true

    local ready=false i
    for ((i = 0; i < 60; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        if port_open 127.0.0.1 "$api" && port_open 127.0.0.1 "$mixed"; then
            ready=true
            break
        fi
        sleep 0.2
    done
    if [[ "$ready" != true ]]; then
        err "Xray не запустился. Последние строки журнала:"
        tail -n 20 "$XRAY_LOG" 2>/dev/null | sed 's/^/  /' >&2 || true
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 0.2
        fi
        # If sudo forked xray, killing sudo alone may leave the child behind.
        if is_running; then
            stop_xray quiet || true
        fi
        rm -f "$PID_FILE" "$PROC_FILE"
        [[ "$tun" == "true" ]] && tun_cleanup_routes || true
        return 1
    fi

    if [[ "$tun" == "true" ]]; then
        if ! tun_setup_routes; then
            err "TUN не настроен; останавливаю Xray"
            kill "$pid" 2>/dev/null || true
            sleep 0.5
            kill -9 "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
            tun_cleanup_routes
            return 1
        fi
    fi

    local active
    active="$(active_id)"
    if [[ -z "$active" ]] || ! jq -e --arg id "$active" '.servers[] | select(.id == $id)' "$STATE_FILE" >/dev/null 2>&1; then
        active="$(jq -r '.servers[0].id' "$STATE_FILE")"
        state_update '.settings.active = $id' --arg id "$active" || true
    fi
    if ! api_set_balancer "$active" quiet; then
        err "API не подтвердил активный сервер; останавливаю Xray, чтобы не пускать трафик случайно."
        stop_xray quiet || true
        return 1
    fi

    jq -n --argjson pid "$pid" --argjson started "$(date +%s)" \
        --arg config "$CONFIG_FILE" --argjson tun "$([[ "$tun" == true ]] && echo true || echo false)" \
        --arg owner "$(id -un)" \
        '{pid:$pid,started_at:$started,config:$config,tun:$tun,owner:$owner}' \
        >"$PROC_FILE" 2>/dev/null || true
    chmod 600 "$PROC_FILE" 2>/dev/null || true
    ok "Xray запущен (PID $pid), mixed-прокси 127.0.0.1:$mixed, API 127.0.0.1:$api"
    return 0
}

stop_xray() {
    local quiet="${1:-}"
    init_data

    if [[ -f "$TUN_STATE_FILE" ]]; then
        tun_cleanup_routes || true
    fi

    if ! is_running; then
        rm -f "$PID_FILE" "$PROC_FILE"
        [[ "$quiet" == "quiet" ]] || info "Xray уже остановлен"
        return 0
    fi

    local pid owner
    pid="$(read_pid)"
    owner="$(pid_owner "$pid")"
    if [[ -n "$owner" && "$owner" != "$EUID" ]]; then
        ensure_sudo
    fi

    if ! priv_run kill -TERM "$pid" 2>/dev/null; then
        err "Не удалось отправить SIGTERM процессу $pid"
        return 1
    fi
    local i
    for ((i = 0; i < 50; i++)); do
        priv_run kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if priv_run kill -0 "$pid" 2>/dev/null; then
        priv_run kill -KILL "$pid" 2>/dev/null || true
        sleep 0.3
    fi
    rm -f "$PID_FILE" "$PROC_FILE"
    tun_cleanup_routes || true
    [[ "$quiet" == "quiet" ]] || ok "Xray остановлен"
    return 0
}

restart_xray() {
    init_data
    stop_xray quiet || true
    start_xray
}

process_uptime() {
    local pid started
    is_running || return 1
    pid="$(read_pid)"
    started="$(jq -r '.started_at // 0' "$PROC_FILE" 2>/dev/null || echo 0)"
    if [[ "$started" =~ ^[0-9]+$ ]] && (( started > 0 )); then
        human_duration "$(( $(date +%s) - started ))"
    else
        ps -o etimes= -p "$pid" 2>/dev/null | awk '{print $1"с"}'
    fi
}

status_xray() {
    init_data
    local active active_name n mixed api tun
    n="$(server_count)"
    active="$(active_id)"
    active_name="$(jq -r --arg id "$active" '.servers[] | select(.id == $id) | .name' "$STATE_FILE" 2>/dev/null | head -n1)"
    [[ -n "$active_name" ]] || active_name="—"
    mixed="$(setting_get mixed_port)"; [[ -n "$mixed" ]] || mixed=12080
    api="$(setting_get api_port)"; [[ -n "$api" ]] || api=10085
    tun="$(setting_get tun)"; [[ "$tun" == "true" ]] || tun=false

    if is_running; then
        local pid owner health
        pid="$(read_pid)"
        owner="$(pid_owner "$pid")"
        if api_health; then health="${C_GREEN}OK${C_RESET}"; else health="${C_RED}нет ответа${C_RESET}"; fi
        printf '%s\n' "${C_GREEN}● Xray запущен${C_RESET}  PID $pid  (uptime $(process_uptime))"
        printf '  Активный: %s\n' "$active_name"
        printf '  Серверов: %s   TUN: %s   owner uid: %s\n' "$n" "$([[ "$tun" == true ]] && echo "вкл" || echo "выкл")" "${owner:-?}"
        printf '  Mixed:   127.0.0.1:%s\n' "$mixed"
        printf '  API:     127.0.0.1:%s  %s\n' "$api" "$health"
        [[ -f "$CONFIG_FILE" ]] && printf '  Конфиг:  %s (%s)\n' "$CONFIG_FILE" "$(date -r "$CONFIG_FILE" '+%H:%M:%S')"
    else
        printf '%s\n' "${C_DIM}○ Xray остановлен${C_RESET}"
        printf '  Активный: %s   Серверов: %s   TUN: %s\n' "$active_name" "$n" "$([[ "$tun" == true ]] && echo "вкл" || echo "выкл")"
        [[ -f "$TUN_STATE_FILE" ]] && warn "Остались записи TUN-маршрутов: $TUN_STATE_FILE (очистятся при stop/start)"
    fi
    return 0
}

show_log() {
    local lines="${1:-80}" follow="${2:-}"
    [[ -f "$XRAY_LOG" ]] || { msg "Журнал пуст: $XRAY_LOG"; return 0; }
    if [[ "$follow" == "follow" ]]; then
        tail -n "$lines" -f "$XRAY_LOG"
    else
        tail -n "$lines" "$XRAY_LOG"
    fi
}

api_status() {
    init_data
    is_running || die "Xray не запущен"
    local api
    api="$(setting_get api_port)"; [[ -n "$api" ]] || api=10085
    info "API 127.0.0.1:$api"
    if ! timeout 6 "$XRAY_BIN" api lso -s "127.0.0.1:$api" >/dev/null 2>&1; then
        err "API не отвечает"
        return 1
    fi
    ok "HandlerService/RoutingService отвечают"
    msg "Активный по state: $(active_id)"
    msg ""
    msg "Outbounds в процессе:"
    timeout 6 "$XRAY_BIN" api lso -s "127.0.0.1:$api" 2>/dev/null \
        | jq -r '.outbounds[] | "  \(.tag)  \(.proxySettings._TypedMessage_ // "?")"' 2>/dev/null \
        || true
    msg ""
    msg "Balancer (bi; при strategy=random health-информации может не быть):"
    timeout 6 "$XRAY_BIN" api bi -s "127.0.0.1:$api" active 2>&1 | sed 's/^/  /' || true
}

doctor() {
    init_data
    local failures=0 warnings=0
    msg "${C_BOLD}$APP $VERSION — диагностика${C_RESET}"
    msg ""

    local xray=""
    if [[ -x "$XRAY_BIN" ]]; then
        xray="$XRAY_BIN"
        ok "Xray: $xray"
        msg "  $(xray_version)"
    else
        err "Бинарник xray не найден в папке bin/. Скопируйте его туда вручную: $XRAY_BIN"
        failures=$((failures + 1))
    fi

    local c
    for c in jq curl base64 sha1sum flock nohup timeout ip ss gum; do
        if have "$c"; then
            ok "Команда: $c"
        else
            if [[ "$c" == "gum" ]]; then
                warn "Нет gum — TUI недоступен, CLI работает"
                warnings=$((warnings + 1))
            elif [[ "$c" == "ip" || "$c" == "ss" ]]; then
                warn "Нет $c — часть диагностики/TUN недоступна"
                warnings=$((warnings + 1))
            else
                err "Не найдена команда: $c"
                failures=$((failures + 1))
            fi
        fi
    done

    if jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        ok "state.json: серверов $(server_count), подписок $(jq -r '.subscriptions|length' "$STATE_FILE")"
    else
        err "state.json повреждён"
        failures=$((failures + 1))
    fi

    local n
    n="$(server_count)"
    if (( n == 0 )); then
        warn "Нет серверов: добавьте ключ"
        warnings=$((warnings + 1))
    else
        local active
        active="$(active_id)"
        if [[ -n "$active" ]] && jq -e --arg id "$active" '.servers[]|select(.id==$id)' "$STATE_FILE" >/dev/null 2>&1; then
            ok "Активный сервер: $(jq -r --arg id "$active" '.servers[]|select(.id==$id)|.name' "$STATE_FILE")"
        else
            warn "Активный сервер не выбран"
            warnings=$((warnings + 1))
        fi
    fi

    if [[ -n "$xray" && -x "$xray" ]]; then
        if generate_config quiet >/dev/null 2>&1; then
            ok "Генерация и проверка config.json"
        else
            err "Конфиг не генерируется/не проходит xray run -test"
            failures=$((failures + 1))
        fi
    fi

    if is_running; then
        ok "Процесс запущен (PID $(read_pid))"
        if api_health; then ok "Xray API отвечает"; else err "Xray API не отвечает"; failures=$((failures + 1)); fi
        if port_open 127.0.0.1 "$(setting_get mixed_port)"; then
            ok "Mixed-порт $(setting_get mixed_port) слушается"
        else
            err "Mixed-порт не слушается"
            failures=$((failures + 1))
        fi
    else
        info "Процесс остановлен"
        local mixed api
        mixed="$(setting_get mixed_port)"; api="$(setting_get api_port)"
        port_open 127.0.0.1 "$mixed" && { warn "Порт $mixed занят другим процессом"; warnings=$((warnings + 1)); } || true
        port_open 127.0.0.1 "$api" && { warn "Порт $api занят другим процессом"; warnings=$((warnings + 1)); } || true
    fi

    # TUN capability: parse a minimal TUN config. As non-root Xray fails with
    # EPERM after successful parsing; that is enough to prove support.
    local tunfile tunout tunrc
    tunfile="$(mktemp "$DATA_DIR/.tun-doctor.XXXXXX.json")"
    cat >"$tunfile" <<'JSON'
{"log":{"loglevel":"none"},"inbounds":[{"tag":"t","protocol":"tun","settings":{"name":"xraybox-probe0","mtu":1500}}],"outbounds":[{"protocol":"freedom"}]}
JSON
    if [[ -n "$xray" && -x "$xray" ]]; then
        tunout="$("$xray" run -test -c "$tunfile" 2>&1)"; tunrc=$?
    else
        tunout="xray not found"; tunrc=127
    fi
    rm -f "$tunfile"
    if (( tunrc == 0 )) || grep -qiE 'operation not permitted|permission denied|failed to create (virtual )?tun|TUNSETIFF' <<<"$tunout"; then
        ok "TUN поддерживается Xray"
        if is_root; then
            ok "Права root есть"
        elif sudo -n true 2>/dev/null; then
            ok "sudo без пароля доступен (TUN можно запускать)"
        elif have sudo; then
            warn "TUN потребует пароль sudo"
            warnings=$((warnings + 1))
        else
            warn "TUN требует root, sudo не найден"
            warnings=$((warnings + 1))
        fi
    else
        warn "TUN не подтверждён этой сборкой Xray"
        warnings=$((warnings + 1))
    fi
    if [[ -c /dev/net/tun ]]; then
        ok "/dev/net/tun доступен"
    else
        warn "/dev/net/tun отсутствует — TUN не заработает"
        warnings=$((warnings + 1))
    fi
    local iface
    iface="$(default_iface || true)"
    if [[ -n "$iface" ]]; then
        ok "Default interface: $iface"
        if [[ "$(setting_get tun)" == "true" ]]; then
            ok "TUN включён в настройках"
        else
            info "TUN выключен в настройках"
        fi
    else
        warn "Не удалось определить default interface (ip route)"
        warnings=$((warnings + 1))
    fi

    msg ""
    if (( failures > 0 )); then
        err "Провалов: $failures, предупреждений: $warnings"
        return 1
    fi
    ok "Критичных проблем нет (предупреждений: $warnings)"
    return 0
}
