#!/bin/bash
# Separate public stats page: the top counters through latency.
# Counters only. No names, no client addresses, no block list.
set -euo pipefail
export LC_ALL=C

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sync-storage.sh"

STATEDIR="${DNS_MAGIC_STATS_STATE:-/var/lib/dns-magic/stats}"
WEB="${DNS_MAGIC_STATS_WEB:-/var/www/dns-magic/stats.html}"
SERIES="${STATEDIR}/series"
WINDOW=300
MIN_SPAN=60
FRESH=180
HISTORY=$((12 * 3600))

fmt_num() {
    awk -v v="$1" -v d="$2" 'BEGIN { if (v < 0) v = 0; printf "%.*f", d, v }'
}

esc() {
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

# Column: 2 qps, 3 cache %, 4 SERVFAIL %, 5 slow %, 6 latency ms. -1 is a gap.
sparkline() {
    local col="$1"
    [[ -s "$SERIES" ]] || return 0
    awk -v col="$col" '
        $col ~ /^-?[0-9.]+$/ && $col + 0 >= 0 { n++; v[n] = $col + 0 }
        END {
            if (n < 2) exit
            min = max = v[1]
            for (i = 1; i <= n; i++) {
                if (v[i] < min) min = v[i]
                if (v[i] > max) max = v[i]
            }
            if (max == min) max = min + 1
            printf "<svg viewBox=\"0 0 100 28\" preserveAspectRatio=\"none\" aria-hidden=\"true\"><path d=\"M0,28 "
            for (i = 1; i <= n; i++) {
                x = (i - 1) * 100 / (n - 1)
                y = 26 - (v[i] - min) / (max - min) * 24
                printf "L%.2f,%.2f ", x, y
            }
            printf "L100,28 Z\"/></svg>"
        }
    ' "$SERIES"
}

range_label() {
    [[ -s "$SERIES" ]] || { printf '%s' "Last minute"; return; }
    awk '
        $1 ~ /^[0-9]+$/ { if (a == "") a = $1; b = $1 }
        END {
            d = b - a
            if (d >= 11 * 3600) print "Last 12 hours"
            else if (d >= 50 * 60) print "Last hour"
            else if (d >= 4 * 60) print "Last minutes"
            else print "Last minute"
        }
    ' "$SERIES"
}

append_history() {
    local now="$1" qps="$2" cache="$3" servfail="$4" slow="$5" latency="$6" tmp
    mkdir -p "$STATEDIR"
    tmp="$(mktemp)"
    [[ -f "$SERIES" ]] && cat "$SERIES" >>"$tmp" || true
    printf '%s %.6f %.4f %.4f %.4f %.4f\n' "$now" "$qps" "$cache" "$servfail" "$slow" "$latency" >>"$tmp"
    awk -v now="$now" -v keep="$HISTORY" '$1 ~ /^[0-9]+$/ && now - $1 <= keep { print }' "$tmp" >"$SERIES"
    rm -f "$tmp"
    chmod 600 "$SERIES" || true
}

panel() {
    local title="$1" value="$2" color="$3" col="$4" ink="" svg
    [[ "$color" == "#fade2a" ]] && ink=" ink"
    svg="$(sparkline "$col")"
    cat <<EOF
<article class="panel${ink}" style="background:${color}"><h2>${title}</h2><p class="value">${value}</p>${svg}</article>
EOF
}

tone() {
    # tone kind raw. kind is cache, bad (servfail/slow), or latency. -1 is empty.
    awk -v kind="$1" -v v="$2" 'BEGIN {
        if (v < 0) { print "#181b1f"; exit }
        if (kind == "cache") {
            if (v < 15) print "#e02f44"; else if (v < 30) print "#ff9830"; else print "#73bf69"
        } else if (kind == "servfail") {
            if (v < 3) print "#73bf69"; else if (v < 8) print "#ff9830"; else print "#e02f44"
        } else if (kind == "slow") {
            if (v < 2) print "#73bf69"; else if (v < 5) print "#ff9830"; else print "#e02f44"
        } else {
            if (v < 60) print "#73bf69"; else if (v < 120) print "#fade2a"; else if (v < 250) print "#ff9830"; else print "#e02f44"
        }
    }'
}

show_num() {
    local v="$1" digits="$2"
    awk -v v="$v" 'BEGIN { exit !(v < 0) }' && { printf '%s' "–"; return; }
    fmt_num "$v" "$digits"
}

write_page() {
    local note="$1" qps="$2" cache="$3" servfail="$4" slow="$5" latency="$6"
    local tmp host qps_s cache_s serv_s slow_s lat_s
    mkdir -p "$(dirname "$WEB")" "$STATEDIR"
    host="$(esc "${DOMAIN:-}")"
    [[ -n "$host" ]] && host="${host} · "
    qps_s="$(show_num "$qps" "$(awk -v v="$qps" 'BEGIN { print (v >= 0 && v < 10) ? 1 : 0 }')")"
    cache_s="$(show_num "$cache" 1)"; [[ "$cache_s" != "–" ]] && cache_s="${cache_s}%"
    serv_s="$(show_num "$servfail" 2)"; [[ "$serv_s" != "–" ]] && serv_s="${serv_s}%"
    slow_s="$(show_num "$slow" 2)"; [[ "$slow_s" != "–" ]] && slow_s="${slow_s}%"
    lat_s="$(show_num "$latency" "$(awk -v v="$latency" 'BEGIN { print (v >= 0 && v < 10) ? 1 : 0 }')")"
    [[ "$lat_s" != "–" ]] && lat_s="${lat_s} ms"
    tmp="$(mktemp)"
    {
        cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>DoH / DoT</title>
<style>
html, body { margin: 0; background: #111217; color: #d8d9da; }
body { font-family: Inter, Roboto, "Helvetica Neue", Arial, sans-serif; }
.bar { display: flex; align-items: center; gap: 1rem; height: 3rem; padding: 0 1rem; border-bottom: 1px solid #2c3235; }
.bar h1 { margin: 0; font-size: 1rem; font-weight: 500; }
.bar .meta { margin-left: auto; color: #8e8ea0; font-size: 0.82rem; }
.wrap { padding: 0.7rem 0.75rem 1.2rem; }
.grid { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 0.5rem; }
.row { margin: 0.85rem 0 0.45rem; font-size: 0.9rem; font-weight: 500; color: #d8d9da; }
.panel { position: relative; min-height: 7.6rem; overflow: hidden; border-radius: 2px; padding: 0.45rem 0.6rem 1.7rem; color: #fff; }
.panel h2 { margin: 0; font-size: 0.86rem; font-weight: 500; color: rgba(255,255,255,.9); }
.panel .value { margin: 0.85rem 0 0; text-align: center; font-size: 2rem; font-weight: 500; line-height: 1; }
.panel svg { position: absolute; left: 0; right: 0; bottom: 0; width: 100%; height: 1.7rem; }
.panel svg path { fill: rgba(255,255,255,.32); }
.panel.ink, .panel.ink h2 { color: #1f1f1f; }
.panel.ink svg path { fill: rgba(0,0,0,.22); }
.note { margin: 0.8rem 0.15rem 0; color: #8e8ea0; font-size: 0.78rem; line-height: 1.4; }
@media (max-width: 900px) { .grid { grid-template-columns: 1fr 1fr; } .panel .value { font-size: 1.7rem; } }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } .bar { height: auto; padding: 0.7rem 1rem; } .bar .meta { margin-left: 0; } }
</style>
</head>
<body>
<header class="bar"><h1>DoH / DoT</h1><p class="meta">${host}$(esc "$(range_label)")</p></header>
<main class="wrap">
<div class="grid">
EOF
        panel "Queries/s" "$qps_s" "#3274d9" 2
        panel "Cache hits" "$cache_s" "$(tone cache "$cache")" 3
        panel "SERVFAIL" "$serv_s" "$(tone servfail "$servfail")" 4
        panel "Slow &gt; 1 s" "$slow_s" "$(tone slow "$slow")" 5
        cat <<EOF
</div>
<h2 class="row">Latency</h2>
<div class="grid">
EOF
        panel "Latency" "$lat_s" "$(tone latency "$latency")" 6
        cat <<EOF
</div>
<p class="note">$(esc "$note")</p>
</main>
</body>
</html>
EOF
    } >"$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$WEB"
}

write_waiting() {
    write_page "The first reading appears in about a minute." -1 -1 -1 -1 -1
}

# Two unbound stats dumps and the seconds between them. Prints one JSON
# object. Exit 2 when counters went backwards (the process restarted).
diff_dumps() {
    local older="$1" newer="$2" span="$3"
    gawk -v span="$span" '
        function load(file, dest,    line, k, p, n) {
            while ((getline line < file) > 0) {
                p = index(line, "=")
                if (p == 0) continue
                k = substr(line, 1, p - 1)
                if (k ~ /^thread/) continue
                n = substr(line, p + 1) + 0
                if (k == "total.num.queries" || k == "total.num.cachehits" || k == "num.answer.rcode.SERVFAIL" || k ~ /^histogram\./) {
                    data[dest SUBSEP k] = n
                }
            }
            close(file)
        }
        function get(dest, k) { return data[dest SUBSEP k] + 0 }
        BEGIN {
            if (span + 0 <= 0) exit 1
            load(ARGV[1], "o")
            load(ARGV[2], "n")
            ARGV[1] = ""
            ARGV[2] = ""
            dq = get("n", "total.num.queries") - get("o", "total.num.queries")
            dh = get("n", "total.num.cachehits") - get("o", "total.num.cachehits")
            ds = get("n", "num.answer.rcode.SERVFAIL") - get("o", "num.answer.rcode.SERVFAIL")
            if (dq < 0 || dh < 0 || ds < 0) exit 2
            for (key in data) {
                split(key, parts, SUBSEP)
                k = parts[2]
                if (match(k, /^histogram\.([0-9.]+)\.to\.([0-9.]+)$/, m)) seen[k] = 1
            }
            lookups = 0
            slow = 0
            sum_ms = 0
            for (k in seen) {
                match(k, /^histogram\.([0-9.]+)\.to\.([0-9.]+)$/, m)
                lo = m[1] + 0
                hi = m[2] + 0
                c = get("n", k) - get("o", k)
                if (c < 0) exit 2
                if (c == 0) continue
                lookups += c
                if (lo >= 1) slow += c
                mid = (lo > 0) ? sqrt(lo * hi) : (hi / 2)
                if (mid > 60) mid = 60
                sum_ms += mid * 1000 * c
            }
            qps = dq / span
            printf "{\"qps\":%.6f,\"answers\":%d,\"hits\":%d,\"servfails\":%d,\"slow\":%d,\"lookups\":%d,\"latency_ms_sum\":%.4f}\n", qps, dq, dh, ds, slow, lookups, sum_ms
        }
    ' "$older" "$newer"
}

collect_window() {
    local now stats ref oldest f epoch span json
    now="$(date +%s)"
    stats="$(unbound-control -c /etc/unbound/unbound.conf stats_noreset 2>/dev/null || true)"
    if [[ -z "$stats" ]]; then
        # The first start runs before unbound is up. Log only after a
        # measurement existed, so a later failure is visible.
        if compgen -G "$STATEDIR/s-*" >/dev/null; then
            log "unbound-control returned no counters"
        fi
        return 1
    fi
    printf '%s\n' "$stats" >"$STATEDIR/s-$now"
    chmod 600 "$STATEDIR/s-$now"
    find "$STATEDIR" -name 's-*' -mmin +20 -delete
    ref=""
    oldest=""
    for f in "$STATEDIR"/s-*; do
        [[ -f "$f" ]] || continue
        epoch="${f##*-}"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        [[ "$epoch" -eq "$now" ]] && continue
        if [[ -z "$oldest" || "$epoch" -lt "$oldest" ]]; then
            oldest="$epoch"
        fi
        if [[ "$epoch" -le $((now - WINDOW)) ]]; then
            if [[ -z "$ref" || "$epoch" -gt "$ref" ]]; then
                ref="$epoch"
            fi
        fi
    done
    if [[ -z "$ref" && -n "$oldest" && $((now - oldest)) -ge $MIN_SPAN ]]; then
        ref="$oldest"
    fi
    [[ -n "$ref" ]] || return 1
    span=$((now - ref))
    [[ "$span" -ge $MIN_SPAN ]] || return 1
    if ! json="$(diff_dumps "$STATEDIR/s-$ref" "$STATEDIR/s-$now" "$span")"; then
        find "$STATEDIR" -name 's-*' ! -name "s-$now" -delete
        return 1
    fi
    printf '%s' "$json"
}

render_from_json() {
    local json="$1" note="$2"
    local qps cache servfail slow latency answers hits lookups sum sfail nslow now
    answers="$(jq -r '.answers' <<<"$json")"
    hits="$(jq -r '.hits' <<<"$json")"
    qps="$(jq -r '.qps' <<<"$json")"
    lookups="$(jq -r '.lookups' <<<"$json")"
    sum="$(jq -r '.latency_ms_sum' <<<"$json")"
    sfail="$(jq -r '.servfails' <<<"$json")"
    nslow="$(jq -r '.slow' <<<"$json")"
    if [[ "$answers" -gt 0 ]]; then
        cache="$(awk -v h="$hits" -v a="$answers" 'BEGIN { print (h / a) * 100 }')"
        servfail="$(awk -v s="$sfail" -v a="$answers" 'BEGIN { print (s / a) * 100 }')"
        slow="$(awk -v s="$nslow" -v a="$answers" 'BEGIN { print (s / a) * 100 }')"
    else
        cache=-1
        servfail=-1
        slow=-1
    fi
    if [[ "$lookups" -gt 0 ]]; then
        latency="$(awk -v s="$sum" -v n="$lookups" 'BEGIN { print s / n }')"
    else
        latency=-1
    fi
    now="$(date +%s)"
    append_history "$now" "$qps" "$cache" "$servfail" "$slow" "$latency"
    write_page "$note" "$qps" "$cache" "$servfail" "$slow" "$latency"
}

instance_id() {
    local idfile="$STATEDIR/id" id
    if [[ -s "$idfile" ]]; then
        id="$(<"$idfile")"
    else
        id="$(openssl rand -hex 8)"
        printf '%s\n' "$id" >"$idfile"
        chmod 600 "$idfile"
    fi
    [[ "$id" =~ ^[0-9a-f]{16}$ ]]
    printf '%s' "$id"
}

combine_json_files() {
    jq -s '
        map(select(
            (.answers | type) == "number" and .answers >= 0 and .answers <= 99999999 and .answers == (.answers | floor) and
            (.hits | type) == "number" and .hits >= 0 and .hits == (.hits | floor) and .hits <= .answers and
            (.qps | type) == "number" and .qps >= 0 and .qps <= 999999 and
            (.servfails | type) == "number" and .servfails >= 0 and .servfails == (.servfails | floor) and .servfails <= .answers and
            (.slow | type) == "number" and .slow >= 0 and .slow == (.slow | floor) and .slow <= .answers and
            (.lookups | type) == "number" and .lookups >= 0 and .lookups <= 99999999 and .lookups == (.lookups | floor) and
            (.latency_ms_sum | type) == "number" and .latency_ms_sum >= 0 and
            (.lookups == 0 or (.latency_ms_sum / .lookups) <= 60000)
        ))
        | if length == 0 then empty else {
            qps: (map(.qps) | add),
            answers: (map(.answers) | add),
            hits: (map(.hits) | add),
            servfails: (map(.servfails) | add),
            slow: (map(.slow) | add),
            lookups: (map(.lookups) | add),
            latency_ms_sum: (map(.latency_ms_sum) | add)
        } end
    ' "$@"
}

# Sum this container with the other containers that share the storage zone.
# A stale, huge or malformed file is ignored. Prints the combined JSON.
merge_instances() {
    local mine="$1" dir id now item name t file len merged="" status=0
    dir="$(mktemp -d)"
    cp "$mine" "$dir/self.json"
    id="$(instance_id)"
    now="$(date +%s)"
    storage_upload "$dir/self.json" "stats/instances/${id}.json" || true
    if storage_list "stats/instances" >"$dir/list" 2>/dev/null; then
        while IFS= read -r item; do
            [[ -n "$item" ]] || continue
            name="$(jq -r '.ObjectName // empty' <<<"$item" 2>/dev/null || true)"
            [[ "$(jq -r '.IsDirectory // false' <<<"$item" 2>/dev/null || echo true)" == "false" ]] || continue
            [[ "$name" =~ ^[0-9a-f]{16}\.json$ ]] || continue
            [[ "$name" == "${id}.json" ]] && continue
            len="$(jq -r '.Length // 0' <<<"$item" 2>/dev/null || echo 0)"
            [[ "$len" =~ ^[0-9]+$ && "$len" -le 4096 ]] || continue
            file="$dir/$name"
            storage_download "stats/instances/$name" "$file" || continue
            t="$(jq -r '.t // 0' "$file" 2>/dev/null || echo 0)"
            if [[ "$t" =~ ^[0-9]+$ && "$t" -lt $((now - 86400)) ]]; then
                storage_delete "stats/instances/$name" || true
                rm -f "$file"
            elif [[ ! "$t" =~ ^[0-9]+$ || "$t" -lt $((now - FRESH)) ]]; then
                rm -f "$file"
            fi
        done <"$dir/list"
    fi
    if ! merged="$(combine_json_files "$dir"/*.json)"; then
        status=1
    fi
    rm -rf "$dir"
    [[ "$status" -eq 0 && -n "$merged" ]] || return 1
    printf '%s\n' "$merged"
}

main_stats() {
    local json stamped note oldest newest merged stampfile
    mkdir -p "$STATEDIR" "$(dirname "$WEB")"
    chmod 755 "$STATEDIR" "$(dirname "$WEB")" || true
    load_env || true
    exec 8>"$STATEDIR/run.lock"
    flock -n 8 || return 0
    if ! json="$(collect_window)"; then
        newest="$(find "$STATEDIR" -name 's-*' -printf '%f\n' 2>/dev/null | sed 's/^s-//' | sort -n | tail -1)"
        if [[ ! -s "$WEB" || ! "$newest" =~ ^[0-9]+$ || $(( $(date +%s) - newest )) -gt $FRESH ]]; then
            write_waiting
        fi
        return 0
    fi
    stamped="$(jq -c --argjson t "$(date +%s)" '. + {t:$t}' <<<"$json")"
    newest="$(date +%s)"
    oldest="$(find "$STATEDIR" -name 's-*' -printf '%f\n' | sed 's/^s-//' | sort -n | head -1)"
    if [[ "$oldest" =~ ^[0-9]+$ && $((newest - oldest)) -ge $((WINDOW - 30)) ]]; then
        note="Last five minutes. Latency is the resolver time without cache."
    else
        note="Last minute. Latency is the resolver time without cache."
    fi
    stampfile="$(mktemp)"
    printf '%s\n' "$stamped" >"$stampfile"
    if load_env && resolve_storage quiet; then
        if merged="$(merge_instances "$stampfile")"; then
            json="$merged"
        else
            json="$stamped"
            note="${note} This server only."
        fi
    else
        json="$stamped"
        note="${note} This server only."
    fi
    rm -f "$stampfile"
    render_from_json "$json" "$note"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        diff) diff_dumps "$2" "$3" "$4" ;;
        render)
            WEB="$2"
            render_from_json "$(cat "$3")" "$4"
            ;;
        "") main_stats ;;
        *) printf 'usage: dns-magic-stats.sh [diff older newer span | render web json note]\n' >&2; exit 1 ;;
    esac
fi
