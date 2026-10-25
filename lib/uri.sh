#!/usr/bin/env bash
# shellcheck shell=bash
# VLESS URI parser. Supports the transports/security combinations Xray uses,
# including XHTTP and REALITY.

# Reads the value of a query parameter from an already undecoded query string.
uri_q() {
    local q="$1" key="$2" tmp v
    [[ -n "$q" ]] || return 0
    tmp="&$q&"
    [[ "$tmp" == *"&$key="* ]] || return 0
    v="${tmp#*&$key=}"
    v="${v%%&*}"
    url_decode "$v"
}

# parse_vless <uri> [source] -> compact JSON on stdout
parse_vless() {
    local uri source body frag userinfo rest hostport host port query
    uri="$(trim "$1")"
    source="${2:-manual}"

    if [[ "$uri" != vless://* ]]; then
        err "Ожидается ключ vless://"
        return 1
    fi

    body="${uri#vless://}"
    frag=""
    if [[ "$body" == *#* ]]; then
        frag="${body#*#}"
        body="${body%%#*}"
    fi

    if [[ "$body" != *@* ]]; then
        err "Некорректный VLESS-ключ: отсутствует UUID@host"
        return 1
    fi
    userinfo="${body%@*}"
    userinfo="${userinfo##*@}"   # last @ is the separator
    rest="${body##*@}"

    if [[ -z "$userinfo" ]]; then
        err "Некорректный VLESS-ключ: пустой UUID"
        return 1
    fi
    if [[ ! "$userinfo" =~ ^[A-Za-z0-9._~-]{1,64}$ ]]; then
        err "Некорректный VLESS UUID: $userinfo"
        return 1
    fi

    hostport="${rest%%[\/?]*}"
    query=""
    if [[ "$rest" == *\?* ]]; then
        query="${rest#*\?}"
        query="${query%%#*}"
    fi

    host=""
    port=""
    if [[ "$hostport" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$hostport" =~ ^\[([^]]+)\]$ ]]; then
        host="${BASH_REMATCH[1]}"
        port=443
    elif [[ "$hostport" == *:* ]]; then
        host="${hostport%:*}"
        port="${hostport##*:}"
    elif [[ -n "$hostport" ]]; then
        host="$hostport"
        port=443
    fi

    [[ -n "$host" ]] || { err "Некорректный VLESS-ключ: пустой адрес"; return 1; }
    if [[ ! "$host" =~ ^[A-Za-z0-9._:%-]+$ ]]; then
        err "Некорректный адрес сервера в ключе: $host"
        return 1
    fi
    [[ "$port" =~ ^[0-9]+$ ]] || { err "Некорректный порт: $port"; return 1; }
    (( port >= 1 && port <= 65535 )) || { err "Порт вне диапазона: $port"; return 1; }

    local type security encryption flow sni fp alpn_raw path host_header mode
    local extra_raw extra_json service_name header_type allow_insecure_raw
    local allow_insecure=false pcs vcn spider_x short_id public_key
    local name

    type="$(uri_q "$query" type)"; type="${type,,}"
    [[ -z "$type" ]] && type=tcp
    case "$type" in
        raw) type=tcp ;;
        splithttp) type=xhttp ;;
        tcp|ws|grpc|xhttp|httpupgrade) ;;
        http)
            err "Транспорт HTTP удалён из Xray 26. Используйте httpupgrade или ws."
            return 1
            ;;
        *)
            err "Неподдерживаемый транспорт Xray: type=$type"
            return 1
            ;;
    esac

    security="$(uri_q "$query" security)"; security="${security,,}"
    [[ -z "$security" ]] && security=none
    case "$security" in
        none|tls|reality) ;;
        xtls)
            err "Устаревший security=xtls не поддерживается. Нужен tls или reality."
            return 1
            ;;
        *)
            err "Неподдерживаемый security: $security"
            return 1
            ;;
    esac

    encryption="$(uri_q "$query" encryption)"; encryption="${encryption,,}"
    [[ -z "$encryption" ]] && encryption=none
    if [[ "$encryption" != none ]]; then
        err "VLESS encryption=$encryption не поддерживается этим менеджером (нужен none)."
        return 1
    fi

    flow="$(uri_q "$query" flow)"
    if [[ "$type" != tcp ]]; then
        flow=""
    fi
    if [[ -n "$flow" && "$flow" != "xtls-rprx-vision" ]]; then
        err "Неизвестный flow: $flow"
        return 1
    fi
    if [[ -n "$flow" && "$security" == "none" ]]; then
        err "flow=$flow требует security=tls или reality"
        return 1
    fi
    if [[ "$security" == reality && "$type" != tcp && "$type" != xhttp && "$type" != grpc ]]; then
        err "REALITY в Xray поддерживает только TCP/RAW, XHTTP и gRPC (у вас $type)."
        return 1
    fi

    sni="$(uri_q "$query" sni)"
    [[ -z "$sni" ]] && sni="$(uri_q "$query" serverName)"
    fp="$(uri_q "$query" fp)"
    [[ -z "$fp" ]] && fp="$(uri_q "$query" fingerprint)"
    fp="${fp,,}"
    if [[ "$security" == reality && -z "$fp" ]]; then
        fp=chrome
    fi
    if [[ "$security" != reality && "$security" != tls ]]; then
        fp=""
    fi

    alpn_raw="$(uri_q "$query" alpn)"
    path="$(uri_q "$query" path)"
    host_header="$(uri_q "$query" host)"
    mode="$(uri_q "$query" mode)"
    service_name="$(uri_q "$query" serviceName)"
    [[ -z "$service_name" ]] && service_name="$(uri_q "$query" service)"
    header_type="$(uri_q "$query" headerType)"

    if [[ "$type" == xhttp ]]; then
        [[ -z "$path" ]] && path="/"
        case "$mode" in
            ""|auto) mode=auto ;;
            packet-up|stream-up|stream-one) ;;
            *) err "Некорректный XHTTP mode=$mode (auto|packet-up|stream-up|stream-one)"; return 1 ;;
        esac
    elif [[ "$type" == ws || "$type" == httpupgrade ]]; then
        [[ -z "$path" ]] && path="/"
        [[ -z "$mode" ]] && mode=""
    elif [[ "$type" == grpc ]]; then
        case "$mode" in
            ""|gun) mode="" ;;
            multi) ;;
            *) err "Некорректный gRPC mode=$mode (gun|multi)"; return 1 ;;
        esac
        path=""
    elif [[ "$type" == tcp ]]; then
        [[ -z "$header_type" ]] && header_type=none
        header_type="${header_type,,}"
        case "$header_type" in
            none|http) ;;
            *) err "Некорректный headerType=$header_type (none|http)"; return 1 ;;
        esac
    fi

    extra_raw="$(uri_q "$query" extra)"
    extra_json=null
    if [[ -n "$extra_raw" ]]; then
        if ! jq -e 'type == "object"' <<<"$extra_raw" >/dev/null 2>&1; then
            err "Параметр extra в ключе — невалидный JSON-объект"
            return 1
        fi
        extra_json="$extra_raw"
    fi

    allow_insecure_raw="$(uri_q "$query" allowInsecure)"
    [[ -z "$allow_insecure_raw" ]] && allow_insecure_raw="$(uri_q "$query" insecure)"
    case "${allow_insecure_raw,,}" in
        1|true|yes)
            allow_insecure=true
            # Xray 26 removed allowInsecure; emitting it makes the whole config
            # invalid. Keep the key importable and warn instead.
            warn "allowInsecure=1 не поддерживается Xray 26 — ключ импортируется без этой опции"
            allow_insecure=false
            ;;
    esac

    pcs="$(uri_q "$query" pcs)"
    vcn="$(uri_q "$query" vcn)"

    public_key="$(uri_q "$query" pbk)"
    short_id="$(uri_q "$query" sid)"
    spider_x="$(uri_q "$query" spx)"
    [[ -z "$spider_x" ]] && spider_x="/"

    if [[ "$security" == reality ]]; then
        if [[ -z "$public_key" ]]; then
            err "Для REALITY нужен параметр pbk (public key)"
            return 1
        fi
        if [[ ! "$public_key" =~ ^[A-Za-z0-9_-]{43}=?$ ]]; then
            err "Некорректный REALITY public key (pbk): ожидается 43 символа base64url"
            return 1
        fi
        if [[ -n "$short_id" && ! "$short_id" =~ ^[0-9A-Fa-f]{1,16}$ ]]; then
            err "Некорректный REALITY shortId (sid): до 16 hex-символов"
            return 1
        fi
        if [[ -z "$sni" ]]; then
            sni="$host"
        fi
    elif [[ "$security" == tls ]]; then
        [[ -z "$sni" ]] && sni="$host"
        if [[ -n "$pcs" && ! "$pcs" =~ ^[0-9A-Fa-f]{64}$ ]]; then
            err "Некорректный pcs: ожидается SHA-256 в hex (64 символа)"
            return 1
        fi
    fi

    name=""
    if [[ -n "$frag" ]]; then
        name="$(url_decode "$frag")"
    fi
    name="$(sanitize_text "$name")"
    name="$(trim "$name")"
    [[ -z "$name" ]] && name="$host:$port"

    # Normalized key for deduplication: no fragment, query kept as-is.
    local normalized id alpn_json added_at
    normalized="vless://${userinfo}@${hostport}?${query}"
    id="$(sha1 "$normalized" | cut -c1-12)"
    added_at="$(date +%s)"

    alpn_json="$(jq -cn --arg s "$alpn_raw" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"

    jq -cn \
        --arg id "$id" \
        --arg name "$name" \
        --arg protocol "vless" \
        --arg host "$host" \
        --argjson port "$port" \
        --arg uuid "$userinfo" \
        --arg transport "$type" \
        --arg security "$security" \
        --arg flow "$flow" \
        --arg sni "$sni" \
        --arg fingerprint "$fp" \
        --argjson alpn "$alpn_json" \
        --arg public_key "$public_key" \
        --arg short_id "$short_id" \
        --arg spider_x "$spider_x" \
        --arg path "$path" \
        --arg host_header "$host_header" \
        --arg mode "$mode" \
        --argjson extra "$extra_json" \
        --arg service_name "$service_name" \
        --arg header_type "$header_type" \
        --argjson allow_insecure "$allow_insecure" \
        --arg pcs "$pcs" \
        --arg vcn "$vcn" \
        --arg source "$source" \
        --arg uri "$uri" \
        --argjson added_at "$added_at" \
        '{
            id: $id,
            name: $name,
            protocol: $protocol,
            host: $host,
            port: $port,
            uuid: $uuid,
            transport: $transport,
            security: $security,
            flow: $flow,
            sni: $sni,
            fingerprint: $fingerprint,
            alpn: $alpn,
            public_key: $public_key,
            short_id: $short_id,
            spider_x: $spider_x,
            path: $path,
            host_header: $host_header,
            mode: $mode,
            extra: $extra,
            service_name: $service_name,
            header_type: $header_type,
            allow_insecure: $allow_insecure,
            pinned_peer_cert_sha256: $pcs,
            verify_peer_cert_by_name: $vcn,
            source: $source,
            added_at: $added_at,
            uri: $uri
        }'
}
