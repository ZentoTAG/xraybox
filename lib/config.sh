#!/usr/bin/env bash
# shellcheck shell=bash
# Config generation and validation.

build_outbound() {
    local srv="$1" iface="${2:-}"
    jq -c --arg iface "$iface" -f "$ROOT_DIR/lib/outbound.jq" <<<"$srv"
}

validate_config_file() {
    # validate_config_file <file> [quiet]
    local file="$1" quiet="${2:-}"
    local testfile="$file" tmp=""
    local out rc=0
    resolve_xray

    # `xray run -test` actually creates a TUN device. Without root this always
    # fails with EPERM, so validate the rest of the config without the TUN
    # inbound and let `start` (with sudo) do the real check.
    if [[ "$(setting_get tun)" == "true" ]] && ! is_root; then
        tmp="$(mktemp "$DATA_DIR/.config-test.XXXXXX.json")"
        jq 'del(.inbounds[] | select(.tag == "tun-in"))' "$file" >"$tmp" || {
            rm -f "$tmp"
            return 1
        }
        testfile="$tmp"
    fi

    out="$("$XRAY_BIN" run -test -c "$testfile" 2>&1)" || rc=$?
    [[ -n "$tmp" ]] && rm -f "$tmp"
    if (( rc != 0 )); then
        err "Xray отверг конфиг:"
        printf '%s\n' "$out" | tail -n 25 >&2
        return 1
    fi
    [[ "$quiet" == "quiet" ]] || info "Конфиг проверен Xray: OK"
    return 0
}

generate_config() {
    # generate_config [quiet]
    local quiet="${1:-}"
    init_data
    resolve_xray
    require_cmd jq

    local mixed_port api_port log_level allow_lan tun_enabled tun_name tun_mtu
    local tun_gateway tun_metric direct_domains listen iface=""
    mixed_port="$(setting_get mixed_port)"; [[ -n "$mixed_port" ]] || mixed_port=12080
    api_port="$(setting_get api_port)"; [[ -n "$api_port" ]] || api_port=10085
    log_level="$(setting_get log_level)"; [[ -n "$log_level" ]] || log_level=warning
    allow_lan="$(setting_get allow_lan)"; [[ "$allow_lan" == "true" ]] || allow_lan=false
    tun_enabled="$(setting_get tun)"; [[ "$tun_enabled" == "true" ]] || tun_enabled=false
    tun_name="$(setting_get tun_name)"; [[ -n "$tun_name" ]] || tun_name=xraybox0
    tun_mtu="$(setting_get tun_mtu)"; [[ -n "$tun_mtu" ]] || tun_mtu=1500
    tun_gateway="$(setting_get tun_gateway)"; [[ -n "$tun_gateway" ]] || tun_gateway="172.19.0.1/30"
    tun_metric="$(setting_get tun_metric)"; [[ -n "$tun_metric" ]] || tun_metric=1
    direct_domains="$(jq -c '.settings.direct_domains // []' "$STATE_FILE")"

    is_uint "$mixed_port" && (( mixed_port >= 1 && mixed_port <= 65535 )) \
        || { err "Некорректный mixed_port: $mixed_port"; return 1; }
    is_uint "$api_port" && (( api_port >= 1 && api_port <= 65535 )) \
        || { err "Некорректный api_port: $api_port"; return 1; }
    (( mixed_port != api_port )) || { err "mixed_port и api_port не должны совпадать"; return 1; }
    [[ "$log_level" =~ ^(debug|info|warning|error|none)$ ]] \
        || { err "Некорректный log_level: $log_level"; return 1; }
    [[ "$tun_name" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] \
        || { err "Некорректное имя TUN-интерфейса: $tun_name (до 15 символов)"; return 1; }
    is_uint "$tun_mtu" && (( tun_mtu >= 576 && tun_mtu <= 65535 )) \
        || { err "Некорректный TUN MTU: $tun_mtu"; return 1; }
    [[ "$tun_gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] \
        || { err "Некорректный tun_gateway (нужен IPv4 CIDR): $tun_gateway"; return 1; }
    is_uint "$tun_metric" || { err "Некорректный tun_metric: $tun_metric"; return 1; }
    jq -e 'type == "array" and all(.[]; type == "string")' <<<"$direct_domains" >/dev/null \
        || { err "direct_domains должен быть массивом строк"; return 1; }

    if [[ "$tun_enabled" == "true" ]]; then
        iface="$(default_iface || true)"
        [[ -n "$iface" ]] || { err "TUN включён, но не удалось определить default interface (ip route)"; return 1; }
    fi

    listen="127.0.0.1"
    [[ "$allow_lan" == "true" ]] && listen="0.0.0.0"

    local tmpdir out_ndjson out_json cfg_tmp taglist
    tmpdir="$(mktemp -d "$DATA_DIR/.gen.XXXXXX")" || { err "Не удалось создать temp"; return 1; }
    out_ndjson="$tmpdir/outbounds.ndjson"
    out_json="$tmpdir/outbounds.json"
    cfg_tmp="$tmpdir/config.json"
    : >"$out_ndjson"

    local srv out
    while IFS= read -r srv; do
        [[ -n "$srv" ]] || continue
        out="$(build_outbound "$srv" "$iface")" || {
            rm -rf "$tmpdir"
            err "Не удалось собрать outbound"
            return 1
        }
        printf '%s\n' "$out" >>"$out_ndjson"
    done < <(jq -c '.servers[]' "$STATE_FILE")

    jq -s '.' "$out_ndjson" >"$out_json" || {
        rm -rf "$tmpdir"
        err "Не удалось собрать массив outbounds"
        return 1
    }

    taglist="$(server_tags)"
    [[ -n "$taglist" ]] || taglist='[]'

    local private_ips='["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","::1/128","fc00::/7","fe80::/10"]'

    jq -n \
        --slurpfile servers "$out_json" \
        --argjson mixed_port "$mixed_port" \
        --argjson api_port "$api_port" \
        --arg listen "$listen" \
        --arg loglevel "$log_level" \
        --argjson tun "$tun_enabled" \
        --arg tun_name "$tun_name" \
        --argjson tun_mtu "$tun_mtu" \
        --arg tun_gateway "$tun_gateway" \
        --arg iface "$iface" \
        --argjson direct_domains "$direct_domains" \
        --argjson server_tags "$taglist" \
        --argjson private_ips "$private_ips" \
        '{
            log: {loglevel: $loglevel, access: "none"},
            api: {
                tag: "api",
                services: ["HandlerService", "LoggerService", "StatsService", "RoutingService"]
            },
            inbounds: ([
                {
                    tag: "api",
                    listen: "127.0.0.1",
                    port: $api_port,
                    protocol: "dokodemo-door",
                    settings: {address: "127.0.0.1"}
                },
                {
                    tag: "mixed",
                    listen: $listen,
                    port: $mixed_port,
                    protocol: "mixed",
                    settings: {auth: "noauth", udp: true},
                    sniffing: {
                        enabled: true,
                        destOverride: ["http", "tls"],
                        routeOnly: false
                    }
                }
            ] + (if $tun then [{
                tag: "tun-in",
                protocol: "tun",
                settings: {
                    name: $tun_name,
                    mtu: $tun_mtu,
                    gateway: [$tun_gateway],
                    autoSystemRoutingTable: ["0.0.0.0/0"],
                    autoOutboundsInterface: "auto"
                },
                sniffing: {
                    enabled: true,
                    destOverride: ["http", "tls"],
                    routeOnly: false
                }
            }] else [] end)),
            outbounds: (
                $servers[0]
                + [{
                    tag: "direct",
                    protocol: "freedom"
                } + (if $iface != "" then {streamSettings: {sockopt: {interface: $iface}}} else {} end),
                {tag: "block", protocol: "blackhole"}]
            ),
            routing: {
                domainStrategy: "AsIs",
                rules: ([
                    {type: "field", inboundTag: ["api"], outboundTag: "api"},
                    {type: "field", ip: $private_ips, outboundTag: "direct"}
                ]
                + (if ($direct_domains | length) > 0
                   then [{type: "field", domain: $direct_domains, outboundTag: "direct"}]
                   else [] end)
                + [(if ($server_tags | length) > 0
                    then {type: "field", network: "tcp,udp", balancerTag: "active"}
                    else {type: "field", network: "tcp,udp", outboundTag: "direct"} end)]),
                balancers: (if ($server_tags | length) > 0 then [{
                    tag: "active",
                    selector: $server_tags,
                    strategy: {type: "random"}
                }] else [] end)
            }
        }' >"$cfg_tmp" || {
        rm -rf "$tmpdir"
        err "jq не смог собрать конфиг"
        return 1
    }

    if ! validate_config_file "$cfg_tmp" quiet; then
        rm -rf "$tmpdir"
        err "Конфиг не прошёл проверку; старый config.json не изменён"
        return 1
    fi

    chmod 600 "$cfg_tmp"
    mv -f "$cfg_tmp" "$CONFIG_FILE"
    rm -rf "$tmpdir"
    [[ "$quiet" == "quiet" ]] || ok "Конфиг записан: $CONFIG_FILE"
    return 0
}

check_current_config() {
    [[ -f "$CONFIG_FILE" ]] || die "Конфига нет. Выполните: $APP gen"
    validate_config_file "$CONFIG_FILE"
}

config_summary() {
    [[ -f "$CONFIG_FILE" ]] || { msg "Конфиг ещё не сгенерирован."; return 0; }
    jq -r '
        "Файл: '"$CONFIG_FILE"'",
        "Inbounds: " + ([.inbounds[] | "\(.tag)(\(.protocol):\(.port // "-"))"] | join(", ")),
        "Серверов в outbounds: " + (([.outbounds[] | select(.tag | startswith("srv_"))] | length) | tostring),
        "Balancer: " + ((.routing.balancers[0].tag // "—")),
        "TUN: " + (if ([.inbounds[] | select(.protocol == "tun")] | length) > 0 then "вкл" else "выкл" end),
        "",
        "Серверные outbounds:",
        (.outbounds[] | select(.tag | startswith("srv_")) |
            "  \(.tag)  \(.streamSettings.network)/\(.streamSettings.security)  \(.settings.vnext[0].address):\(.settings.vnext[0].port)")
    ' "$CONFIG_FILE"
}

config_redacted() {
    [[ -f "$CONFIG_FILE" ]] || { msg "Конфига нет."; return 0; }
    jq '{
        log,
        api,
        inbounds,
        outbounds: [.outbounds[] | {
            tag,
            protocol,
            network: (.streamSettings.network // null),
            security: (.streamSettings.security // null),
            address: (.settings.vnext[0].address // null),
            port: (.settings.vnext[0].port // null)
        }],
        routing
    }' "$CONFIG_FILE"
}
