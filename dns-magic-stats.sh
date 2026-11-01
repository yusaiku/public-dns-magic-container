#!/bin/bash
# Public summary for the info page: query rate, cache, SERVFAIL, slow replies
# and lookup time. Counters only. No names, no client addresses, no block list.
set -euo pipefail
export LC_ALL=C

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sync-storage.sh"

STATEDIR="${DNS_MAGIC_STATS_STATE:-/var/lib/dns-magic/stats}"
WEB="${DNS_MAGIC_STATS_WEB:-/var/www/dns-magic/stats.html}"
WINDOW=300
MIN_SPAN=60
FRESH=180

comma() { printf '%s' "$1" | sed 's/\./,/' ; }

fmt_num() {
    awk -v v="$1" -v d="$2" 'BEGIN { if (v < 0) v = 0; printf "%.*f", d, v }'
}

write_page() {
    local note="$1" qps="$2" cache="$3" servfail="$4" slow="$5" latency="$6" tmp
    mkdir -p "$(dirname "$WEB")"
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>Betrieb</title>
<style>
html, body { margin: 0; background: #f4f1ea; color: #1a1814; }
body { font-family: Palatino, "Palatino Linotype", Georgia, serif; }
.note, h2, .n { font-family: system-ui, "Segoe UI", sans-serif; }
.note { margin: 0 0 0.7rem; color: #5e584e; font-size: 0.85rem; line-height: 1.35; }
.grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(7.2rem, 1fr));
    gap: 0.6rem;
}
article {
    background: #fbf9f4;
    border: 1px solid #d8d0c3;
    border-radius: 2px;
    padding: 0.75rem 0.8rem 0.85rem;
}
h2 {
    margin: 0;
    color: #5e584e;
    font-size: 0.68rem;
    font-weight: 650;
    letter-spacing: 0.12em;
    text-transform: uppercase;
}
.n {
    margin: 0.35rem 0 0;
    color: #1e4d3a;
    font-size: 1.55rem;
    font-weight: 650;
    letter-spacing: -0.03em;
    line-height: 1.1;
}
</style>
</head>
<body>
<p class="note">${note}</p>
<div class="grid">
<article><h2>Anfragen/s</h2><p class="n">${qps}</p></article>
<article><h2>Cache</h2><p class="n">${cache}</p></article>
<article><h2>SERVFAIL</h2><p class="n">${servfail}</p></article>
<article><h2>über 1 s</h2><p class="n">${slow}</p></article>
<article><h2>Antwortzeit</h2><p class="n">${latency}</p></article>
</div>
</body>
</html>
EOF
    chmod 644 "$tmp"
    mv "$tmp" "$WEB"
}

write_waiting() {
    write_page "Die erste Messung erscheint nach etwa einer Minute." "–" "–" "–" "–" "–"
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
    local qps cache servfail slow latency answers hits lookups sum sfail nslow mean
    answers="$(jq -r '.answers' <<<"$json")"
    hits="$(jq -r '.hits' <<<"$json")"
    qps="$(jq -r '.qps' <<<"$json")"
    lookups="$(jq -r '.lookups' <<<"$json")"
    sum="$(jq -r '.latency_ms_sum' <<<"$json")"
    sfail="$(jq -r '.servfails' <<<"$json")"
    nslow="$(jq -r '.slow' <<<"$json")"
    if [[ "$answers" -gt 0 ]]; then
        cache="$(comma "$(fmt_num "$(awk -v h="$hits" -v a="$answers" 'BEGIN { print (h / a) * 100 }')" 1)") %"
        servfail="$(comma "$(fmt_num "$(awk -v s="$sfail" -v a="$answers" 'BEGIN { print (s / a) * 100 }')" 2)") %"
        slow="$(comma "$(fmt_num "$(awk -v s="$nslow" -v a="$answers" 'BEGIN { print (s / a) * 100 }')" 2)") %"
    else
        cache="–"
        servfail="–"
        slow="–"
    fi
    if awk -v v="$qps" 'BEGIN { exit !(v < 10) }'; then
        qps="$(comma "$(fmt_num "$qps" 1)")"
    else
        qps="$(comma "$(fmt_num "$qps" 0)")"
    fi
    if [[ "$lookups" -gt 0 ]]; then
        mean="$(awk -v s="$sum" -v n="$lookups" 'BEGIN { print s / n }')"
        if awk -v v="$mean" 'BEGIN { exit !(v < 10) }'; then
            latency="$(comma "$(fmt_num "$mean" 1)") ms"
        else
            latency="$(comma "$(fmt_num "$mean" 0)") ms"
        fi
    else
        latency="–"
    fi
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
        note="Letzte fünf Minuten. Antwortzeit ohne Cache, gemessen im Resolver."
    else
        note="Letzte Minute. Antwortzeit ohne Cache, gemessen im Resolver."
    fi
    stampfile="$(mktemp)"
    printf '%s\n' "$stamped" >"$stampfile"
    if load_env && resolve_storage quiet; then
        if merged="$(merge_instances "$stampfile")"; then
            json="$merged"
        else
            json="$stamped"
            note="${note} Gerade nur dieser Server."
        fi
    else
        json="$stamped"
        note="${note} Gerade nur dieser Server."
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
