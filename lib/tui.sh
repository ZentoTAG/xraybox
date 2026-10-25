#!/usr/bin/env bash
# shellcheck shell=bash
# gum-based TUI.

TUI_ACTIVE=0

tui_cleanup() {
    TUI_ACTIVE=0
    printf '\n'
    exit 0
}

tui_need_gum() {
    have gum || die "TUI требует gum. Установите gum или используйте CLI-команды."
    [[ -t 0 && -t 1 ]] || die "TUI запускается только в интерактивном терминале."
}

tui_clear() {
    [[ -t 1 ]] && clear 2>/dev/null || true
}

tui_menu() {
    local header="$1"; shift
    gum choose --header "$header" --height 15 --cursor "› " \
        --cursor.foreground "212" \
        --item.foreground "252" \
        --selected.foreground "212" \
        "$@"
}

tui_header() {
    local state_line active tun mixed api n
    n="$(server_count)"
    active="$(active_id)"
    mixed="$(setting_get mixed_port)"; [[ -n "$mixed" ]] || mixed=12080
    api="$(setting_get api_port)"; [[ -n "$api" ]] || api=10085
    tun="$(setting_get tun)"; [[ "$tun" == "true" ]] && tun="TUN: вкл" || tun="TUN: выкл"
    if is_running; then
        state_line="${C_GREEN}● запущен${C_RESET} (PID $(read_pid))"
    else
        state_line="${C_DIM}○ остановлен${C_RESET}"
    fi
    local active_name="—"
    if [[ -n "$active" ]]; then
        active_name="$(jq -r --arg id "$active" '.servers[]|select(.id==$id)|.name' "$STATE_FILE" 2>/dev/null | head -n1)"
        [[ -n "$active_name" ]] || active_name="—"
    fi
    printf '%s\n' "$(gum style --border rounded --border-foreground 212 --padding '0 2' --width 78 \
        "xraybox $VERSION" \
        "Xray: $state_line   Серверов: $n   $tun" \
        "Активный: $active_name" \
        "Прокси: 127.0.0.1:$mixed   API: 127.0.0.1:$api")"
}

tui_pause() {
    [[ -t 0 ]] || return 0
    printf '\n%s' "${C_DIM}Enter — продолжить...${C_RESET}"
    read -r _ || true
}

tui_choose_server_prompt() {
    # Вспомогательная функция выбора сервера: список отсортирован по пингу,
    # но номера остаются «постоянными» (индекс в state.json), чтобы `use N`
    # работал предсказуемо и после сортировки.
    local header="$1"
    local n active labels=() srv i selection idx
    n="$(server_count)"
    if (( n == 0 )); then
        ui_warn "Серверов нет. Сначала добавьте ключ." >&2
        return 1
    fi
    active="$(active_id)"
    while IFS=$'\t' read -r i srv; do
        [[ -n "$srv" ]] || continue
        labels+=("$(server_label "$srv" "$i" "$active")")
    done < <(servers_sorted | jq -r '[.idx, (.srv | tojson)] | @tsv')
    labels+=("← Назад")

    selection="$(gum choose \
        --header "$header · ↑/↓ — выбор, / — поиск, Enter — ОК, Esc — назад" \
        --height 22 \
        --cursor "› " \
        --cursor.foreground "212" \
        --header.foreground "99" \
        --item.foreground "252" \
        --selected.foreground "212" \
        "${labels[@]}")" || return 1

    [[ -n "$selection" && "$selection" != "← Назад" ]] || return 1
    idx="$(sed -n 's/^ *\([0-9][0-9]*\)\..*/\1/p' <<<"$selection" | head -n1)"
    [[ -n "$idx" ]] || return 1
    printf '%s' "$idx"
}

tui_maybe_start_xray() {
    if ! is_running; then
        if gum confirm --affirmative "Запустить" --negative "Позже" "Xray не запущен. Запустить сейчас?"; then
            (start_xray) || true
        fi
    fi
}

tui_pick_server() {
    local have_pings
    have_pings="$(jq '[.servers[] | select((.ping // null) != null)] | length' "$STATE_FILE" 2>/dev/null)"
    if [[ "${have_pings:-0}" == "0" ]]; then
        tui_clear
        (ping_all_servers tcp quiet) || true
    fi

    local idx
    idx="$(tui_choose_server_prompt "Выберите сервер (сортировка по пингу)")" || return 0
    if ! (use_server "$idx"); then
        tui_pause
        return 0
    fi
    tui_maybe_start_xray
    tui_pause
}

tui_ping_all() {
    tui_clear
    (ping_all_servers tcp) || true
    tui_pause
}

tui_ping_active_http() {
    tui_clear
    local id
    id="$(active_id)"
    if [[ -z "$id" ]]; then
        ui_warn "Активный сервер не выбран."
    elif ! is_running; then
        ui_warn "Для реальной проверки через туннель сначала запустите Xray."
    else
        (ping_server_http "$id") || true
    fi
    tui_pause
}

tui_auto_fastest() {
    tui_clear
    if ! (auto_select_fastest); then
        tui_pause
        return 0
    fi
    tui_maybe_start_xray
    tui_pause
}

tui_remove_server() {
    local idx srv
    idx="$(tui_choose_server_prompt "Удалить сервер")" || return 0
    srv="$(resolve_server "$idx" 2>/dev/null)" || return 0
    if ! gum confirm --affirmative "Удалить" --negative "Отмена" \
        "Удалить «$(jq -r '.name' <<<"$srv")»?"; then
        return 0
    fi
    (remove_server "$idx") || true
    if [[ "$(server_count)" == "0" ]] && is_running; then
        if gum confirm --affirmative "Остановить" --negative "Оставить" "Серверов не осталось. Остановить Xray?"; then
            (stop_xray) || true
        fi
    fi
    tui_pause
}

tui_rename_server() {
    local idx srv newname
    idx="$(tui_choose_server_prompt "Переименовать сервер")" || return 0
    srv="$(resolve_server "$idx" 2>/dev/null)" || return 0
    newname="$(gum input --header "Новое имя" --value "$(jq -r '.name' <<<"$srv")" --width 70)" || return 0
    [[ -n "$(trim "$newname")" ]] || return 0
    (rename_server "$idx" "$newname") || true
    tui_pause
}

tui_add_key() {
    local text
    if ! text="$(gum write --header "Вставьте vless:// ключ(и). Ctrl+D — сохранить, Esc — отмена" \
        --placeholder "vless://…" --height 8 --width 100 2>/dev/null)"; then
        return 0
    fi
    [[ -n "$(trim "$text")" ]] || return 0
    (import_uri_text "$text" manual) || true
    tui_pause
}

tui_import_file() {
    local path
    if ! path="$(gum file --file --all --header "Файл с vless:// ключами (Esc — отмена)" "$HOME" 2>/dev/null)"; then
        return 0
    fi
    [[ -n "$path" ]] || return 0
    (add_from_file "$path" manual) || true
    tui_pause
}

tui_server_menu() {
    while true; do
        tui_clear
        tui_header
        local choice
        if ! choice="$(tui_menu "Серверы" \
            "Выбрать / переключить сервер" \
            "Автоматически выбрать самый быстрый" \
            "Проверить пинг всех (TCP)" \
            "Проверить активный сервер через Xray (HTTP)" \
            "Добавить ключ" \
            "Импорт из файла" \
            "Удалить сервер" \
            "Переименовать сервер" \
            "Назад")"; then
            return 0
        fi
        case "$choice" in
            "Выбрать / переключить сервер") tui_pick_server ;;
            "Автоматически выбрать самый быстрый") tui_auto_fastest ;;
            "Проверить пинг всех (TCP)") tui_ping_all ;;
            "Проверить активный сервер через Xray (HTTP)") tui_ping_active_http ;;
            "Добавить ключ") tui_add_key ;;
            "Импорт из файла") tui_import_file ;;
            "Удалить сервер") tui_remove_server ;;
            "Переименовать сервер") tui_rename_server ;;
            "Назад") return 0 ;;
        esac
    done
}

tui_subscriptions() {
    local choice
    while true; do
        tui_clear
        tui_header
        if ! choice="$(tui_menu "Подписки" \
            "Список подписок" \
            "Добавить подписку" \
            "Обновить все" \
            "Обновить одну" \
            "Удалить подписку" \
            "Назад")"; then
            return 0
        fi
        case "$choice" in
            "Список подписок")
                tui_clear
                (subscription_list)
                tui_pause
                ;;
            "Добавить подписку")
                local url name
                url="$(gum input --header "URL подписки" --placeholder "https://…" --width 90)" || continue
                [[ -n "$(trim "$url")" ]] || continue
                name="$(gum input --header "Имя (пусто — авто)" --width 50)" || true
                tui_clear
                (subscription_add "$(trim "$url")" "$(trim "$name")") || true
                tui_pause
                ;;
            "Обновить все")
                tui_clear
                (subscription_update_all) || true
                tui_pause
                ;;
            "Обновить одну")
                local n labels=() selection idx sub_name
                n="$(jq -r '.subscriptions|length' "$STATE_FILE")"
                if (( n == 0 )); then
                    ui_warn "Подписок нет"
                    tui_pause
                    continue
                fi
                while IFS=$'\t' read -r idx sub_name; do
                    labels+=("$idx — $sub_name")
                done < <(jq -r '.subscriptions[] | [.id, .name] | @tsv' "$STATE_FILE")
                labels+=("← Назад")
                if ! selection="$(tui_menu "Обновить подписку" "${labels[@]}")"; then
                    continue
                fi
                [[ "$selection" != "← Назад" ]] || continue
                idx="${selection%% — *}"
                tui_clear
                (subscription_update_one "$idx") || true
                tui_pause
                ;;
            "Удалить подписку")
                local n labels=() selection idx sub_name
                n="$(jq -r '.subscriptions|length' "$STATE_FILE")"
                if (( n == 0 )); then
                    ui_warn "Подписок нет"
                    tui_pause
                    continue
                fi
                while IFS=$'\t' read -r idx sub_name; do
                    labels+=("$idx — $sub_name")
                done < <(jq -r '.subscriptions[] | [.id, .name] | @tsv' "$STATE_FILE")
                labels+=("← Назад")
                if ! selection="$(tui_menu "Удалить подписку" "${labels[@]}")"; then
                    continue
                fi
                [[ "$selection" != "← Назад" ]] || continue
                idx="${selection%% — *}"
                if gum confirm --affirmative "Удалить" --negative "Отмена" "Удалить подписку $idx? Серверы останутся."; then
                    (subscription_remove "$idx") || true
                fi
                tui_pause
                ;;
            "Назад") return 0 ;;
        esac
    done
}

tui_tun() {
    local tun
    tun="$(setting_get tun)"; [[ "$tun" == "true" ]] || tun=false
    if [[ "$tun" == "true" ]]; then
        if ! gum confirm --affirmative "Выключить" --negative "Оставить" "TUN сейчас включён. Выключить?"; then
            return 0
        fi
        state_update '.settings.tun = false' || { ui_err "Не удалось сохранить"; return 0; }
        if is_running; then
            if gum confirm --affirmative "Перезапустить" --negative "Позже" "Для применения TUN нужен перезапуск Xray. Сделать сейчас?"; then
                (restart_xray) || true
            fi
        else
            (tun_cleanup_routes) || true
            ui_ok "TUN выключен"
        fi
    else
        ui_warn "TUN в Xray требует root/sudo и меняет системный default route."
        if ! gum confirm --affirmative "Включить" --negative "Отмена" "Включить TUN?"; then
            return 0
        fi
        state_update '.settings.tun = true' || { ui_err "Не удалось сохранить"; return 0; }
        if ! (ensure_sudo); then
            state_update '.settings.tun = false' || true
            ui_err "Без root TUN включить нельзя."
            tui_pause
            return 0
        fi
        if is_running; then
            if gum confirm --affirmative "Перезапустить" --negative "Позже" "Перезапустить Xray с TUN сейчас?"; then
                (restart_xray) || true
            fi
        fi
    fi
    tui_pause
}

tui_settings() {
    while true; do
        tui_clear
        tui_header
        local choice
        if ! choice="$(tui_menu "Настройки" \
            "Mixed-порт" \
            "API-порт" \
            "Уровень логов" \
            "Разрешить LAN" \
            "TUN: имя / MTU / gateway" \
            "Домены напрямую" \
            "Назад")"; then
            return 0
        fi
        local val old changed=false other old_settings out
        old_settings="$(jq -c '.settings' "$STATE_FILE" 2>/dev/null)"
        [[ -n "$old_settings" ]] || old_settings='{}'
        case "$choice" in
            "Mixed-порт")
                old="$(setting_get mixed_port)"
                other="$(setting_get api_port)"
                val="$(gum input --header "Mixed HTTP/SOCKS порт" --value "$old" --width 20)" || continue
                val="$(trim "$val")"
                is_uint "$val" && (( val > 0 && val < 65536 )) || { ui_err "Некорректный порт"; tui_pause; continue; }
                [[ "$val" != "$other" ]] || { ui_err "Порт совпадает с API-портом"; tui_pause; continue; }
                if is_running && [[ "$val" != "$old" ]] && port_open 127.0.0.1 "$val"; then
                    ui_err "Порт $val уже занят"; tui_pause; continue
                fi
                state_update '.settings.mixed_port = $v' --argjson v "$val" && changed=true
                ;;
            "API-порт")
                old="$(setting_get api_port)"
                other="$(setting_get mixed_port)"
                val="$(gum input --header "Xray API порт" --value "$old" --width 20)" || continue
                val="$(trim "$val")"
                is_uint "$val" && (( val > 0 && val < 65536 )) || { ui_err "Некорректный порт"; tui_pause; continue; }
                [[ "$val" != "$other" ]] || { ui_err "Порт совпадает с Mixed-портом"; tui_pause; continue; }
                if is_running && [[ "$val" != "$old" ]] && port_open 127.0.0.1 "$val"; then
                    ui_err "Порт $val уже занят"; tui_pause; continue
                fi
                state_update '.settings.api_port = $v' --argjson v "$val" && changed=true
                ;;
            "Уровень логов")
                old="$(setting_get log_level)"
                val="$( tui_menu "Уровень логов" debug info warning error none )" || continue
                state_update '.settings.log_level = $v' --arg v "$val" && changed=true
                ;;
            "Разрешить LAN")
                old="$(setting_get allow_lan)"
                if gum confirm --affirmative "Да" --negative "Нет" "Слушать mixed-прокси на 0.0.0.0? (сейчас $old)"; then
                    state_update '.settings.allow_lan = true' && changed=true
                else
                    state_update '.settings.allow_lan = false' && changed=true
                fi
                ;;
            "TUN: имя / MTU / gateway")
                local name mtu gw metric
                name="$(setting_get tun_name)"; mtu="$(setting_get tun_mtu)"
                gw="$(setting_get tun_gateway)"; metric="$(setting_get tun_metric)"
                name="$(gum input --header "Имя TUN-интерфейса (до 15 симв.)" --value "$name" --width 30)" || continue
                name="$(trim "$name")"
                [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$ ]] || { ui_err "Имя TUN: до 15 символов [A-Za-z0-9_.-]"; tui_pause; continue; }
                mtu="$(gum input --header "MTU (576..65535)" --value "$mtu" --width 12)" || continue
                mtu="$(trim "$mtu")"
                is_uint "$mtu" && (( mtu >= 576 && mtu <= 65535 )) || { ui_err "MTU должен быть 576..65535"; tui_pause; continue; }
                gw="$(gum input --header "Gateway CIDR (IPv4)" --value "$gw" --width 30)" || continue
                gw="$(trim "$gw")"
                [[ "$gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && is_ipv4_cidr "$gw" || { ui_err "Нужен IPv4 CIDR, например 172.19.0.1/30"; tui_pause; continue; }
                metric="$(gum input --header "Metric default route" --value "$metric" --width 12)" || continue
                metric="$(trim "$metric")"
                is_uint "$metric" || { ui_err "Metric должен быть числом"; tui_pause; continue; }
                state_update '.settings.tun_name=$n | .settings.tun_mtu=$m | .settings.tun_gateway=$g | .settings.tun_metric=$x' \
                    --arg n "$name" --argjson m "$mtu" --arg g "$gw" --argjson x "$metric" && changed=true
                ;;
            "Домены напрямую")
                old="$(jq -r '.settings.direct_domains | join(", ")' "$STATE_FILE")"
                val="$(gum input --header "Домены через direct (через запятую)" --value "$old" --width 90)" || continue
                local arr
                arr="$(jq -cn --arg s "$val" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length>0))')"
                state_update '.settings.direct_domains = $a' --argjson a "$arr" && changed=true
                ;;
            "Назад") return 0 ;;
        esac
        if [[ "$changed" == true ]]; then
            if out="$(generate_config quiet 2>&1)"; then
                ui_ok "Настройки сохранены"
            else
                # Never leave state.json with settings that Xray rejects.
                state_update '.settings = $s' --argjson s "$old_settings" >/dev/null 2>&1 || true
                generate_config quiet >/dev/null 2>&1 || true
                ui_err "Конфиг не прошёл проверку — изменения отменены"
                printf '%s\n' "$out" | tail -n 5 >&2
            fi
            if is_running; then
                if gum confirm --affirmative "Перезапустить" --negative "Позже" "Перезапустить Xray для применения?"; then
                    (restart_xray) || true
                fi
            fi
        fi
        tui_pause
    done
}

tui_status() {
    tui_clear
    (status_xray) || true
    msg ""
    (api_status) 2>/dev/null || true
    msg ""
    (config_summary) || true
    tui_pause
}

tui_log() {
    tui_clear
    if [[ -f "$XRAY_LOG" ]]; then
        local content
        content="$(show_log 300)"
        if have gum && [[ -t 1 ]]; then
            printf '%s\n' "$content" | gum pager --height 25 2>/dev/null || true
        else
            printf '%s\n' "$content"
        fi
    else
        ui_warn "Журнал пока пуст"
    fi
    tui_pause
}

tui_config() {
    tui_clear
    (config_summary) || true
    msg ""
    ui_warn "Ниже — конфиг без UUID/ключей."
    local content
    content="$(config_redacted)"
    if have gum && [[ -t 1 ]]; then
        printf '%s\n' "$content" | gum pager --height 25 2>/dev/null || true
    else
        printf '%s\n' "$content" | head -n 100
    fi
    tui_pause
}

tui_doctor() {
    tui_clear
    (doctor) || true
    tui_pause
}

tui_main() {
    tui_need_gum
    init_data
    require_runtime
    TUI_ACTIVE=1
    trap 'tui_cleanup' INT TERM
    while true; do
        tui_clear
        tui_header
        local choice
        if ! choice="$(tui_menu "Главное меню" \
            "Серверы / переключить" \
            "Запустить Xray" \
            "Остановить Xray" \
            "Перезапустить Xray" \
            "Добавить ключ" \
            "Импорт из файла" \
            "Подписки" \
            "TUN вкл/выкл" \
            "Настройки" \
            "Статус" \
            "Журнал" \
            "Конфиг" \
            "Диагностика" \
            "Выход")"; then
            TUI_ACTIVE=0
            exit 0
        fi
        case "$choice" in
            "Серверы / переключить") tui_server_menu ;;
            "Запустить Xray")
                tui_clear
                if is_running; then ui_info "Xray уже запущен"; else (start_xray) || true; fi
                tui_pause
                ;;
            "Остановить Xray")
                if is_running; then
                    if gum confirm --affirmative "Остановить" --negative "Отмена" "Остановить Xray?"; then
                        (stop_xray) || true
                    fi
                else
                    ui_info "Xray уже остановлен"
                fi
                tui_pause
                ;;
            "Перезапустить Xray")
                if gum confirm --affirmative "Перезапустить" --negative "Отмена" "Перезапустить Xray?"; then
                    tui_clear
                    (restart_xray) || true
                    tui_pause
                fi
                ;;
            "Добавить ключ") tui_add_key ;;
            "Импорт из файла") tui_import_file ;;
            "Подписки") tui_subscriptions ;;
            "TUN вкл/выкл") tui_tun ;;
            "Настройки") tui_settings ;;
            "Статус") tui_status ;;
            "Журнал") tui_log ;;
            "Конфиг") tui_config ;;
            "Диагностика") tui_doctor ;;
            "Выход") TUI_ACTIVE=0; exit 0 ;;
        esac
    done
}
