#!/usr/bin/env bash
# shellcheck shell=bash
# Server and subscription management.

api_set_balancer() {
    # api_set_balancer <server-id> [quiet]
    local id="$1" quiet="${2:-}"
    local port tag
    port="$(setting_get api_port)"
    [[ -n "$port" ]] || port=10085
    tag="srv_$id"
    resolve_xray
    local out
    if out="$(timeout 8 "$XRAY_BIN" api bo -s "127.0.0.1:$port" -b active "$tag" 2>&1)"; then
        [[ "$quiet" == "quiet" ]] || ok "Активный сервер переключён через Xray API (без перезапуска)"
        return 0
    fi
    err "Xray API не принял переключение: ${out:-нет ответа}"
    return 1
}

live_add_outbound() {
    # live_add_outbound <server-json>
    is_running || return 0
    local srv="$1" port tmp out rc=0 iface=""
    port="$(setting_get api_port)"
    [[ -n "$port" ]] || port=10085
    if [[ "$(setting_get tun)" == "true" ]]; then
        iface="$(default_iface || true)"
    fi
    tmp="$(mktemp "$DATA_DIR/.ado.XXXXXX.json")" || return 1
    if ! build_outbound "$srv" "$iface" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    # `xray api ado` expects a full config document with an outbounds array.
    jq -s '{outbounds: .}' "$tmp" >"$tmp.wrap" || rc=1
    if (( rc == 0 )); then
        out="$(timeout 8 "$XRAY_BIN" api ado -s "127.0.0.1:$port" "$tmp.wrap" 2>&1)" || rc=$?
    fi
    rm -f "$tmp" "$tmp.wrap"
    if (( rc != 0 )); then
        warn "Не удалось добавить outbound на лету: ${out:-ошибка API}"
        return 1
    fi
    return 0
}

finalize_servers_change() {
    # Regenerate config once, choose a default active server and apply it live.
    local active n first
    active="$(active_id)"
    n="$(server_count)"
    if (( n > 0 )) && [[ -z "$active" ]]; then
        first="$(jq -r '.servers[0].id' "$STATE_FILE")"
        state_update '.settings.active = $id' --arg id "$first" || true
        active="$first"
    fi
    generate_config quiet >/dev/null 2>&1 || {
        warn "Конфиг не удалось пересобрать; проверьте настройки через $APP gen"
    }
    if is_running && [[ -n "$active" ]]; then
        api_set_balancer "$active" quiet || true
    fi
}

add_uri() {
    # add_uri <uri> [source] [quiet] -> prints new id
    local uri="$1" source="${2:-manual}" quiet="${3:-}"
    local srv id rc active_before
    srv="$(parse_vless "$uri" "$source")" || return 1
    id="$(jq -r '.id' <<<"$srv")"

    if jq -e --arg id "$id" '.servers[] | select(.id == $id)' "$STATE_FILE" >/dev/null 2>&1; then
        [[ "$quiet" == "quiet" ]] || warn "Такой сервер уже есть (id $id), пропуск"
        return 2
    fi

    if [[ "$(jq -r '.host' <<<"$srv")" == "0.0.0.0" || "$(jq -r '.host' <<<"$srv")" == "::" ]]; then
        [[ "$quiet" == "quiet" ]] || warn "Пропущен адрес-заглушка 0.0.0.0/::"
        return 3
    fi

    active_before="$(active_id)"
    local was_empty=false
    [[ -z "$active_before" ]] && was_empty=true

    if ! state_update '
        .servers += [$s] |
        if (.settings.active // "") == "" then .settings.active = $s.id else . end
    ' --argjson s "$srv"; then
        err "Не удалось сохранить сервер"
        return 1
    fi

    if is_running; then
        live_add_outbound "$srv" >/dev/null 2>&1 || true
        if [[ "$was_empty" == true ]]; then
            api_set_balancer "$id" quiet >/dev/null 2>&1 || true
        fi
    fi

    [[ "$quiet" == "quiet" ]] || ok "Добавлен: $(server_label "$srv" "" "")"
    printf '%s\n' "$id"
    return 0
}

import_uri_text() {
    # import_uri_text <text> [source] [quiet]
    local text="$1" source="${2:-manual}" quiet="${3:-}"
    local line added=0 dup=0 skipped=0 failed=0 total=0 rc
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="$(trim "$line")"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        [[ "$line" != vless://* ]] && continue
        total=$((total + 1))
        add_uri "$line" "$source" quiet >/dev/null
        rc=$?
        case "$rc" in
            0) added=$((added + 1)) ;;
            2) dup=$((dup + 1)) ;;
            3) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done <<<"$text"
    finalize_servers_change
    if [[ "$quiet" != "quiet" ]]; then
        printf '%s\n' \
            "Добавлено: $added · дубликатов: $dup · пропущено: $skipped · ошибок: $failed"
    fi
    (( failed == 0 && (added + dup) > 0 ))
}

add_from_file() {
    local file="$1" source="${2:-manual}" quiet="${3:-}"
    [[ -r "$file" ]] || die "Файл недоступен: $file"
    local raw decoded
    raw="$(cat "$file")"
    [[ -n "$(trim "$raw")" ]] || die "Файл пуст: $file"
    if grep -q 'vless://' <<<"$raw"; then
        decoded="$raw"
    else
        decoded="$(b64_decode "$raw")"
        grep -q 'vless://' <<<"$decoded" || die "В файле нет ключей vless:// (и это не base64-подписка)"
    fi
    import_uri_text "$decoded" "$source" "$quiet"
}

default_sub_name() {
    local url="$1" host
    host="${url#*://}"
    host="${host%%/*}"
    printf '%s' "${host:-subscription}"
}

subscription_add() {
    # subscription_add <url> [name]
    local url="$1" name="${2:-}" id raw decoded rc
    [[ "$url" =~ ^https?:// ]] || die "URL подписки должен начинаться с http:// или https://"
    [[ -n "$name" ]] || name="$(default_sub_name "$url")"
    id="$(sha1 "$url" | cut -c1-12)"
    if jq -e --arg id "$id" '.subscriptions[] | select(.id == $id)' "$STATE_FILE" >/dev/null 2>&1; then
        warn "Такая подписка уже есть (id $id)"
    else
        state_update '
          .subscriptions += [{
            id: $id, name: $name, url: $url, updated_at: 0,
            last_count: 0, imported_total: 0, last_error: ""
          }]
        ' --arg id "$id" --arg name "$name" --arg url "$url" || die "Не удалось сохранить подписку"
        ok "Подписка добавлена: $name (id $id)"
    fi
    subscription_update_one "$id"
}

subscription_update_one() {
    local selector="$1" quiet="${2:-}" id url name raw decoded rc
    local rec added=0 dup=0 skipped=0 failed=0 total=0
    rec="$(jq -c --arg s "$selector" '
        [.subscriptions[] | select(.id == $s or .name == $s or (.id | startswith($s)))] |
        if length == 1 then .[0] else empty end
    ' "$STATE_FILE")"
    if [[ -z "$rec" ]]; then
        err "Подписка не найдена: $selector"
        return 1
    fi
    id="$(jq -r '.id' <<<"$rec")"
    url="$(jq -r '.url' <<<"$rec")"
    name="$(jq -r '.name' <<<"$rec")"
    [[ "$quiet" == "quiet" ]] || info "Обновляю подписку: $name"

    if ! raw="$(fetch_url "$url")"; then
        state_update '.subscriptions |= map(if .id == $id then .last_error = "fetch failed" else . end)' --arg id "$id" || true
        return 1
    fi
    decoded="$(decode_subscription "$raw")"; rc=$?
    if (( rc == 2 )); then
        state_update '.subscriptions |= map(if .id == $id then .last_error = "Clash YAML unsupported" else . end)' --arg id "$id" || true
        err "Подписка $name — Clash YAML; поддержан только список vless:// или base64."
        return 1
    elif (( rc != 0 )); then
        state_update '.subscriptions |= map(if .id == $id then .last_error = "no vless URIs" else . end)' --arg id "$id" || true
        err "В подписке $name нет ключей vless://."
        return 1
    fi

    local line add_rc
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        line="$(trim "$line")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" != vless://* ]] && continue
        total=$((total + 1))
        add_uri "$line" "sub:$id" quiet >/dev/null
        add_rc=$?
        case "$add_rc" in
            0) added=$((added + 1)) ;;
            2) dup=$((dup + 1)) ;;
            3) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done <<<"$decoded"

    state_update '
        .subscriptions |= map(if .id == $id then
            .updated_at = $ts | .last_count = $total |
            .imported_total = ((.imported_total // 0) + $added) |
            .last_error = ""
        else . end)
    ' --arg id "$id" --argjson ts "$(date +%s)" --argjson total "$total" --argjson added "$added" || true

    finalize_servers_change
    if [[ "$quiet" != "quiet" ]]; then
        ok "Подписка $name: добавлено $added, дубликатов $dup, пропущено $skipped, ошибок $failed"
    fi
    (( failed == 0 ))
}

subscription_update_all() {
    local ids id rc=0
    ids="$(jq -r '.subscriptions[].id' "$STATE_FILE")"
    [[ -n "$ids" ]] || { warn "Подписок нет"; return 0; }
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        subscription_update_one "$id" || rc=1
    done <<<"$ids"
    return "$rc"
}

subscription_list() {
    local n
    n="$(jq -r '.subscriptions | length' "$STATE_FILE")"
    if (( n == 0 )); then
        msg "Подписок нет. Добавьте: $APP sub add 'https://...'"
        return 0
    fi
    jq -r '.subscriptions[] |
        "\(.name)  [\(.id)]\n  URL: \((.url | capture("^(?<base>https?://[^/]+)").base) + "/…")\n  Обновлено: \(if .updated_at > 0 then (.updated_at | strflocaltime("%Y-%m-%d %H:%M")) else "—" end)  ключей: \(.last_count // 0)  ошибка: \(if (.last_error // "") == "" then "—" else .last_error end)"
    ' "$STATE_FILE"
}

subscription_remove() {
    local selector="$1" id
    id="$(jq -r --arg s "$selector" '
        [.subscriptions[] | select(.id == $s or .name == $s or (.id | startswith($s)))] |
        if length == 1 then .[0].id else empty end
    ' "$STATE_FILE")"
    [[ -n "$id" ]] || die "Подписка не найдена: $selector"
    state_update '.subscriptions |= map(select(.id != $id))' --arg id "$id" || die "Не удалось удалить"
    ok "Подписка удалена (серверы оставлены)"
}

remove_server() {
    local selector="$1" srv id active remaining active_after
    srv="$(resolve_server_or_die "$selector")" || return 1
    id="$(jq -r '.id' <<<"$srv")"
    active="$(active_id)"

    state_update '.servers |= map(select(.id != $id))' --arg id "$id" || die "Не удалось удалить сервер"
    remaining="$(server_count)"
    if [[ "$active" == "$id" ]]; then
        active_after="$(jq -r '.servers[0].id // ""' "$STATE_FILE")"
        state_update '.settings.active = $id' --arg id "$active_after" || true
        if is_running && [[ -n "$active_after" ]]; then
            api_set_balancer "$active_after" quiet || true
        fi
    fi
    generate_config quiet >/dev/null 2>&1 || warn "Конфиг пока не пересобран"
    ok "Сервер удалён: $(jq -r '.name' <<<"$srv")"
    if is_running; then
        warn "Для полной выгрузки outbound из процесса выполните перезапуск: $APP restart"
    fi
    return 0
}

rename_server() {
    local selector="$1" newname="$2" srv id
    srv="$(resolve_server_or_die "$selector")" || return 1
    id="$(jq -r '.id' <<<"$srv")"
    state_update '.servers |= map(if .id == $id then .name = $name else . end)' \
        --arg id "$id" --arg name "$newname" || die "Не удалось переименовать"
    ok "Переименовано: $newname"
}

use_server() {
    local selector="$1" srv id
    srv="$(resolve_server_or_die "$selector")" || return 1
    id="$(jq -r '.id' <<<"$srv")"
    state_update '.settings.active = $id' --arg id "$id" || die "Не удалось сохранить выбор"
    if is_running; then
        api_set_balancer "$id" || return 1
    else
        info "Активным выбран: $(jq -r '.name' <<<"$srv") (Xray не запущен)"
    fi
    return 0
}

migrate_legacy() {
    local file="${1:-$DATA_DIR/state.legacy.json}"
    [[ -r "$file" ]] || die "Нет legacy-файла: $file"
    local count
    count="$(jq -r '.servers | length' "$file" 2>/dev/null || echo 0)"
    (( count > 0 )) || die "В legacy-файле нет серверов"

    local mixed api loglevel lan domains
    mixed="$(jq -r '.settings.mixed_port // 12080' "$file")"
    api="$(jq -r '.settings.api_port // 10085' "$file")"
    loglevel="$(jq -r '.settings.log_level // "warning"' "$file")"
    lan="$(jq -r '(.settings.allow_lan // false) | tostring' "$file")"
    domains="$(jq -c '.settings.direct_domains // []' "$file")"
    state_update '
        .settings.mixed_port = $mixed | .settings.api_port = $api |
        .settings.log_level = $loglevel | .settings.allow_lan = ($lan == "true") |
        .settings.direct_domains = $domains
    ' --argjson mixed "$mixed" --argjson api "$api" --arg loglevel "$loglevel" \
      --arg lan "$lan" --argjson domains "$domains" || die "Не удалось перенести настройки"

    local old_active old_active_uri="" new_active="" uri srv id added=0
    old_active="$(jq -r '.settings.active // ""' "$file")"
    if [[ -n "$old_active" ]]; then
        old_active_uri="$(jq -r --arg id "$old_active" '.servers[] | select(.id == $id) | .uri' "$file" | head -n1)"
    fi
    while IFS= read -r uri; do
        [[ "$uri" == vless://* ]] || continue
        if srv="$(parse_vless "$uri" legacy 2>/dev/null)"; then
            id="$(jq -r '.id' <<<"$srv")"
            if add_uri "$uri" legacy quiet >/dev/null 2>&1; then
                added=$((added + 1))
            fi
            [[ -n "$old_active_uri" && "$uri" == "$old_active_uri" ]] && new_active="$id"
        fi
    done < <(jq -r '.servers[].uri' "$file")

    local sid sname surl
    while IFS=$'\t' read -r sid sname surl; do
        [[ "$surl" =~ ^https?:// ]] || continue
        local nid="$(sha1 "$surl" | cut -c1-12)"
        if ! jq -e --arg id "$nid" '.subscriptions[] | select(.id == $id)' "$STATE_FILE" >/dev/null 2>&1; then
            state_update '.subscriptions += [{id:$id,name:$name,url:$url,updated_at:0,last_count:0,imported_total:0,last_error:""}]' \
                --arg id "$nid" --arg name "${sname:-subscription}" --arg url "$surl" || true
        fi
    done < <(jq -r '.subscriptions[] | [.id, .name, .url] | @tsv' "$file")

    if [[ -n "$new_active" ]]; then
        state_update '.settings.active = $id' --arg id "$new_active" || true
    fi
    finalize_servers_change
    ok "Перенесено серверов: $added; подписок: $(jq -r '.subscriptions|length' "$STATE_FILE")"
}

# --- Ping -----------------------------------------------------------------

# Ультрабыстрый TCP-пинг: жёсткий таймаут 1 секунда на сервер.
probe_tcp_ms() {
    local host="$1" port="$2"
    local t0 t1 ms
    t0="$(date +%s%3N)"
    if timeout 1 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        t1="$(date +%s%3N)"
        ms=$(( t1 - t0 ))
        (( ms < 1 )) && ms=1
        printf '%d' "$ms"
        return 0
    fi
    printf '0'
    return 1
}

# Реальная проверка через запущенный Xray (HTTP 204 через mixed-прокси).
# ВНИМАНИЕ: переключает активный outbound на время проверки.
probe_xray_ms() {
    local id="$1"
    is_running || return 1
    local mixed prev_active ms=0 t0 t1
    mixed="$(setting_get mixed_port)"; [[ -n "$mixed" ]] || mixed=12080
    prev_active="$(active_id)"

    api_set_balancer "$id" quiet >/dev/null 2>&1 || return 1
    t0="$(date +%s%3N)"
    if curl -fsSL -x "socks5h://127.0.0.1:$mixed" \
        --connect-timeout 3 --max-time 5 \
        "https://cp.cloudflare.com/generate_204" >/dev/null 2>&1; then
        t1="$(date +%s%3N)"
        ms=$(( t1 - t0 ))
        (( ms < 1 )) && ms=1
    else
        ms=-1
    fi

    if [[ -n "$prev_active" && "$prev_active" != "$id" ]]; then
        api_set_balancer "$prev_active" quiet >/dev/null 2>&1 || true
    fi
    printf '%d' "$ms"
}

ping_all_servers() {
    local mode="${1:-tcp}"
    local n
    n="$(server_count)"
    (( n > 0 )) || { warn "Серверов нет"; return 1; }

    # ---- Xray-режим: только активный сервер, не трогаем сохранённые TCP-пинги.
    if [[ "$mode" == "xray" ]]; then
        if ! is_running; then
            warn "Xray не запущен — реальный отклик проверить нельзя"
            return 1
        fi
        local id name ms
        id="$(active_id)"
        if [[ -z "$id" ]]; then
            warn "Активный сервер не выбран"
            return 1
        fi
        name="$(jq -r --arg id "$id" '.servers[] | select(.id == $id) | .name' "$STATE_FILE" 2>/dev/null | head -n1)"
        [[ -n "$name" ]] || name="$id"
        info "Проверяю реальный отклик: $name"
        ms="$(probe_xray_ms "$id")"
        if (( ms < 0 )); then
            warn "$name: нет отклика (таймаут/ошибка)"
            return 1
        fi
        ok "$name: ${ms} ms"
        return 0
    fi

    # ---- TCP-режим: все серверы параллельно.
    local tmpdir
    tmpdir="$(mktemp -d "$DATA_DIR/.ping.XXXXXX")" || return 1

    local -a pids=()
    local id host port ms
    while IFS=$'\t' read -r id host port; do
        (
            ms="$(probe_tcp_ms "$host" "$port")"
            printf '%s\t%s\n' "$id" "$ms" >"$tmpdir/$id.res"
        ) &
        pids+=($!)
    done < <(jq -r '.servers[] | [.id, .host, (.port|tostring)] | @tsv' "$STATE_FILE")

    # Ждём завершения, но не дольше ~2 сек.
    local i alive pid
    for ((i = 0; i < 20; i++)); do
        alive=0
        for pid in "${pids[@]}"; do
            kill -0 "$pid" 2>/dev/null && { alive=1; break; }
        done
        (( alive == 0 )) && break
        sleep 0.1
    done
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    wait 2>/dev/null || true

    # Собираем результаты (без риска "cat: *.res: No such file").
    : >"$tmpdir/results.tsv"
    local f
    for f in "$tmpdir"/*.res; do
        [[ -f "$f" ]] && cat "$f" >>"$tmpdir/results.tsv"
    done

    local map_json
    map_json="$(awk -F'\t' 'NF==2 {printf "{\"id\":\"%s\",\"ping\":%d}\n", $1, $2}' "$tmpdir/results.tsv" | jq -s 'INDEX(.id)')"
    rm -rf "$tmpdir"

    state_update '
        .servers |= map(
            . as $s |
            if ($pings[$s.id] != null) then
                .ping = $pings[$s.id].ping
            else .ping = 0 end
        )
    ' --argjson pings "${map_json:-{}}" || true
}
