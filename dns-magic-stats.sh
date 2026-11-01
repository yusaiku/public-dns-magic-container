#!/bin/bash
# Feed Grafana the public counters through latency, plus country totals.
# Counters only. No names, no client addresses, no block list.
set -euo pipefail
export LC_ALL=C

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sync-storage.sh"

STATEDIR="${DNS_MAGIC_STATS_STATE:-/var/lib/dns-magic/stats}"
METRICS="${STATEDIR}/metrics.prom"
WINDOW=300
MIN_SPAN=60
FRESH=180

# Print a non-negative number, or fail.
prom_num() {
    awk -v v="$1" 'BEGIN {
        if (v !~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) exit 1
        if (v + 0 < 0) exit 1
        printf "%.6f", v + 0
    }'
}

gauge() {
    local name="$1" value="$2" tmp
    tmp="$(prom_num "$value")" || return 1
    printf '# TYPE %s gauge\n%s %s\n' "$name" "$name" "$tmp"
}

write_metrics() {
    # qps, cache percent, servfail percent, slow percent, latency ms, combined 0/1.
    # A negative percent or latency is left out so Grafana shows no data.
    # The seventh argument is a JSON object of country code to bytes per second.
    local qps="$1" cache="$2" servfail="$3" slow="$4" latency="$5" combined="$6"
    local countries="${7:-{}}" tmp cc val
    mkdir -p "$STATEDIR"
    find "$STATEDIR" -name '.metrics.*' -delete 2>/dev/null || true
    tmp="$(mktemp "${STATEDIR}/.metrics.XXXXXX")"
    {
        gauge dns_magic_queries_per_second "$qps"
        if awk -v v="$cache" 'BEGIN { exit !(v >= 0) }'; then
            gauge dns_magic_cache_ratio "$(awk -v v="$cache" 'BEGIN { print v / 100 }')"
        fi
        if awk -v v="$servfail" 'BEGIN { exit !(v >= 0) }'; then
            gauge dns_magic_servfail_ratio "$(awk -v v="$servfail" 'BEGIN { print v / 100 }')"
        fi
        if awk -v v="$slow" 'BEGIN { exit !(v >= 0) }'; then
            gauge dns_magic_slow_ratio "$(awk -v v="$slow" 'BEGIN { print v / 100 }')"
        fi
        if awk -v v="$latency" 'BEGIN { exit !(v >= 0) }'; then
            gauge dns_magic_latency_milliseconds "$latency"
        fi
        gauge dns_magic_combined "$combined"
        if [[ -n "$countries" && "$countries" != "{}" ]]; then
            printf '# TYPE dns_magic_country_bytes_per_second gauge\n'
            while IFS=' ' read -r cc val; do
                [[ "$cc" =~ ^([A-Z]{2}|OTHER)$ ]] || continue
                printf 'dns_magic_country_bytes_per_second{country="%s"} %.6f\n' "$cc" "$val"
            done < <(jq -r 'to_entries[] | select(.value > 0) | "\(.key) \(.value)"' <<<"$countries")
        fi
    } >"$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$METRICS"
}

clear_metrics() {
    local tmp
    mkdir -p "$STATEDIR"
    tmp="$(mktemp "${STATEDIR}/.metrics.XXXXXX")"
    printf '%s\n' '# dns-magic: no sample' >"$tmp"
    chmod 644 "$tmp"
    mv "$tmp" "$METRICS"
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

# Keep the largest country rates. The tail is one bucket, still without addresses.
fold_countries() {
    local keep="$1"
    jq -c --argjson keep "$keep" '
        def fold($n):
            to_entries
            | map(select(
                (.key | test("^[A-Z]{2}$|^OTHER$"))
                and (.value | type == "number")
                and .value > 0
                and .value <= 1000000000
            ))
            | sort_by(-.value)
            | (.[$n:] | map(.value) | add // 0) as $rest
            | (.[0:$n] | from_entries) as $head
            | if $rest > 0 then $head + {OTHER: (($head.OTHER // 0) + $rest)} else $head end;
        fold($keep)
    '
}

snapshot_geo() {
    local now="$1" src="$STATEDIR/country.cumul" dest="$STATEDIR/g-$now"
    if [[ -s "$src" ]] && jq -e 'type == "object"' "$src" >/dev/null 2>&1; then
        cp "$src" "$dest"
    else
        printf '%s\n' '{}' >"$dest"
    fi
    chmod 644 "$dest"
}

# Cumulative country files and the seconds between them. Prints bytes/second.
# A counter that went backwards is omitted. Keys that are not countries are omitted.
diff_countries() {
    local older="$1" newer="$2" span="$3"
    [[ -s "$older" ]] || printf '%s\n' '{}' >"$older"
    [[ -s "$newer" ]] || printf '%s\n' '{}' >"$newer"
    jq -n -c --argjson span "$span" --slurpfile older "$older" --slurpfile newer "$newer" '
        def n(v): if (v | type) == "number" then v else 0 end;
        ($older[0] // {}) as $a
        | ($newer[0] // {}) as $b
        | if ($a | type) != "object" or ($b | type) != "object" or $span <= 0 then {}
          else
            reduce (($a + $b) | keys[]) as $k ({};
                if (($k | test("^[A-Z]{2}$|^OTHER$")) and ((n($b[$k]) - n($a[$k])) > 0))
                then .[$k] = ((n($b[$k]) - n($a[$k])) / $span)
                else .
                end
            )
          end
    ' | fold_countries 24
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
    snapshot_geo "$now"
    find "$STATEDIR" -name 's-*' -mmin +20 -delete
    find "$STATEDIR" -name 'g-*' -mmin +20 -delete
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
        find "$STATEDIR" -name 'g-*' ! -name "g-$now" -delete
        return 1
    fi
    local cjson='{}'
    cjson="$(diff_countries "$STATEDIR/g-$ref" "$STATEDIR/g-$now" "$span")" || cjson='{}'
    [[ -n "$cjson" ]] || cjson='{}'
    json="$(jq -c --argjson countries "$cjson" '. + {countries: $countries}' <<<"$json")"
    printf '%s' "$json"
}

render_from_json() {
    local json="$1" combined="$2"
    local qps cache servfail slow latency answers hits lookups sum sfail nslow
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
        latency="$(awk -v s="$sum" -v n="$lookups" 'BEGIN { printf "%.6f", s / n }')"
    else
        latency=-1
    fi
    local countries='{}'
    countries="$(jq -c '(.countries // {}) | if type == "object" then . else {} end' <<<"$json" | fold_countries 10)" || countries='{}'
    [[ -n "$countries" ]] || countries='{}'
    write_metrics "$qps" "$cache" "$servfail" "$slow" "$latency" "$combined" "$countries"
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
        | if length == 0 then empty else
            . as $rows
            | {
                qps: ($rows | map(.qps) | add),
                answers: ($rows | map(.answers) | add),
                hits: ($rows | map(.hits) | add),
                servfails: ($rows | map(.servfails) | add),
                slow: ($rows | map(.slow) | add),
                lookups: ($rows | map(.lookups) | add),
                latency_ms_sum: ($rows | map(.latency_ms_sum) | add),
                countries: (
                    [ $rows[]
                      | (.countries // {})
                      | if type == "object" then . else {} end
                      | to_entries[]
                      | select(
                          (.key | test("^[A-Z]{2}$|^OTHER$"))
                          and (.value | type == "number")
                          and .value >= 0
                          and .value <= 1000000000
                      )
                    ]
                    | group_by(.key)
                    | map({key: .[0].key, value: (map(.value) | add)})
                    | from_entries
                )
            }
          end
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
    local json stamped oldest newest merged stampfile combined=0
    mkdir -p "$STATEDIR"
    chmod 755 "$STATEDIR" || true
    load_env || true
    exec 8>"$STATEDIR/run.lock"
    flock -n 8 || return 0
    if ! json="$(collect_window)"; then
        newest="$(find "$STATEDIR" -name 's-*' -printf '%f\n' 2>/dev/null | sed 's/^s-//' | sort -n | tail -1)"
        if [[ ! -s "$METRICS" || ! "$newest" =~ ^[0-9]+$ || $(( $(date +%s) - newest )) -gt $FRESH ]]; then
            clear_metrics
        fi
        return 0
    fi
    stamped="$(jq -c --argjson t "$(date +%s)" '. + {t:$t}' <<<"$json")"
    stampfile="$(mktemp)"
    printf '%s\n' "$stamped" >"$stampfile"
    if load_env && resolve_storage quiet && merged="$(merge_instances "$stampfile")"; then
        json="$merged"
        combined=1
    else
        json="$stamped"
        combined=0
    fi
    rm -f "$stampfile"
    render_from_json "$json" "$combined"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        diff) diff_dumps "$2" "$3" "$4" ;;
        countries) diff_countries "$2" "$3" "$4" ;;
        render)
            render_from_json "$(cat "$2")" "$3"
            ;;
        "") main_stats ;;
        *) printf 'usage: dns-magic-stats.sh [diff older newer span | countries older newer span | render json combined]\n' >&2; exit 1 ;;
    esac
fi
