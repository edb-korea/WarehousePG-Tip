#!/usr/bin/env bash
# Parse a whpg-copy log and print per-table row counts for tables it copied.
#
# Usage:
#   whpg_copy_table_counts.sh /path/to/whpg_copy.*.log
#
# whpg-copy tags each table's log lines with the same data_task span id
# (e.g. "data_task(){id=34359738368}:"). This joins the "Finished data
# task. dst_name=..." line with that id's "Row count validation passed.
# Count: N" line to report rows copied per table. Tables copied without
# count validation, or whose validation failed, are reported too.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <whpg_copy_log_file>" >&2
    exit 1
fi

logfile="$1"

if [[ ! -r "$logfile" ]]; then
    echo "Cannot read log file: $logfile" >&2
    exit 1
fi

rows="$(awk '
    match($0, /data_task\(\)\{id=([0-9]+)\}/, m) { id = m[1] }

    /Finished data task\. dst_name=/ {
        if (match($0, /dst_name="([^"]+)"/, t)) {
            table[id] = t[1]
        }
    }

    /Row count validation passed\. Count: [0-9]+/ {
        if (match($0, /Count: ([0-9]+)/, c)) {
            count[id] = c[1]
            status[id] = "OK"
        }
    }

    /Row count validation failed/ {
        status[id] = "FAILED"
    }

    END {
        for (id in table) {
            tbl = table[id]
            cnt = (id in count) ? count[id] : "-"
            st  = (id in status) ? status[id] : "NO_VALIDATION"
            printf "%-45s %15s  %s\n", tbl, cnt, st
        }
    }
' "$logfile" | sort -k1,1)"

printf "%-45s %15s  %s\n" "TABLE" "ROW_COUNT" "STATUS"
printf '%s\n' "$rows"
