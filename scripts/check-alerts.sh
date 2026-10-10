#!/usr/bin/env bash
# Tests for the two alert checkers (FDPL-119): the backup check that runs in the
# db-alerts CronJob and the host NVMe check. Both run against fake pgbackrest,
# smartctl and curl, so no cluster, drive or webhook is needed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backup_check="$repo_root/k8s/infra/db-alerts/check.sh"
nvme_check="$repo_root/scripts/host/nvme-smart-alert.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

fail=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1" >&2; fail=1; }
contains() { # <name> <file> <text>
    if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (missing: $3)"; fi
}
silent() { # <name> <file>
    if [ ! -s "$2" ]; then ok "$1"; else bad "$1 (unexpected: $(cat "$2"))"; fi
}
valid_json() { # <name> <file>
    if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["content"])<=2000' "$2" 2>/dev/null; then ok "$1"; else bad "$1 (not a valid Discord payload)"; fi
}
epoch() { python3 -c 'import calendar,sys,time; print(calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S")))' "$1"; }

# ---- backup check ----
cat >"$work/bin/pgbackrest" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_INFO"
EOF
chmod +x "$work/bin/pgbackrest"

info() { # <status line> <backup lines...>
    local status="$1"
    shift
    printf 'stanza: bus\n    status: %s\n    cipher: aes-256-cbc\n\n    db (current)\n        wal archive min/max (18): 000000010000000000000001/000000010000000000000005\n' "$status"
    printf '%s\n' "$@"
}
bk() { printf '\n        %s backup: %s\n            timestamp start/stop: %s / %s\n' "$1" "$2" "$3" "$4"; }

run_backup() { # <name> <hour> <info file>  -> payload in $work/payload.json
    rm -f "$work/payload.json"
    FAKE_INFO="$3" PATH="$work/bin:$PATH" ALERT_OUT="$work/payload.json" \
        ALERT_NOW="$(epoch '2026-10-10 03:00:00')" ALERT_HOUR="$2" bash "$backup_check"
}

echo "backup check"
FULL_OK="$(bk full 20261004-020000F '2026-10-04 02:00:00+00' '2026-10-04 02:00:48+00')"
INCR_OK="$(bk incr 20261004-020000F_20261009-020000I '2026-10-09 02:00:00+00' '2026-10-09 02:00:10+00')"

info ok "$FULL_OK" "$INCR_OK" >"$work/healthy"
run_backup healthy 11 "$work/healthy"
silent "healthy and not the heartbeat hour: nothing is sent" "$work/payload.json"
run_backup heartbeat 09 "$work/healthy"
contains "heartbeat hour: OK line is sent" "$work/payload.json" "OK cluster PostgreSQL backups"
contains "heartbeat reports the last backup type" "$work/payload.json" "last backup (incr)"
valid_json "heartbeat payload is valid JSON" "$work/payload.json"

info ok "$FULL_OK" "$(bk incr 20261004-020000F_20261008-020000I '2026-10-08 02:00:00+00' '2026-10-08 02:00:10+00')" >"$work/stale"
run_backup stale 11 "$work/stale"
contains "last backup older than 26h: alert" "$work/payload.json" "ALERT cluster PostgreSQL backups"
contains "stale backup alert names the age" "$work/payload.json" "h ago"
valid_json "stale payload is valid JSON" "$work/payload.json"

info ok "$(bk full 20260928-020000F '2026-09-28 02:00:00+00' '2026-09-28 02:00:48+00')" "$INCR_OK" >"$work/oldfull"
run_backup oldfull 11 "$work/oldfull"
contains "last full older than 8 days: alert" "$work/payload.json" "last full backup finished 12 days ago"

# 07:00:10+08 on the 9th is 23:00:10Z on the 8th, 27h before "now": stale. Read
# without the offset it would look 20h old and pass, so this fails if the offset
# is ignored or added instead of subtracted.
info ok "$FULL_OK" "$(bk incr 20261004-020000F_20261009-070000I '2026-10-09 07:00:00+08' '2026-10-09 07:00:10+08')" >"$work/tz"
run_backup tz 11 "$work/tz"
contains "a +08 timestamp is converted to UTC (27h old, so it alerts)" "$work/payload.json" "finished 27h ago"

printf 'stanza: bus\n    status: error (other)\n            [ServiceError] host [1a1974b9] and configured fingerprint [562f3c84] "do not match"\n    cipher: aes-256-cbc\n' >"$work/broken"
run_backup broken 11 "$work/broken"
contains "unreachable repository / key mismatch: alert" "$work/payload.json" "pgBackRest status is 'error (other)'"
contains "alert carries the error text" "$work/payload.json" "do not match"
valid_json "payload with quotes and newlines is valid JSON" "$work/payload.json"

info ok >"$work/empty"
run_backup empty 11 "$work/empty"
contains "status ok but no backup at all: alert" "$work/payload.json" "no backup exists"

# ---- host NVMe check ----
echo "host NVMe check"
cat >"$work/bin/smartctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--scan" ]; then
    [ "${FAKE_NO_DEVICE:-0}" = 1 ] || echo "/dev/nvme0 -d nvme # /dev/nvme0, NVMe device"
    exit 0
fi
cat "$FAKE_SMART"
EOF
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >"$FAKE_SENT"
EOF
chmod +x "$work/bin/smartctl" "$work/bin/curl"

smart() { # <health> <crit> <temp> <spare> <threshold> <used> <media>
    printf 'SMART overall-health self-assessment test result: %s\n\nSMART/Health Information (NVMe Log 0x02)\nCritical Warning:                   %s\nTemperature:                        %s Celsius\nAvailable Spare:                    %s%%\nAvailable Spare Threshold:          %s%%\nPercentage Used:                    %s%%\nMedia and Data Integrity Errors:    %s\n' "$@"
}
run_nvme() { # <hour> <smart file> [extra env...]
    local hour="$1" file="$2"
    shift 2
    rm -f "$work/sent"
    env "$@" FAKE_SMART="$file" FAKE_SENT="$work/sent" SMARTCTL="$work/bin/smartctl" CURL="$work/bin/curl" \
        ALERT_HOUR="$hour" ALERT_WEBHOOK_URL="https://example.invalid/hook" bash "$nvme_check"
}

smart PASSED 0x00 41 100 10 3 0 >"$work/s_ok"
run_nvme 11 "$work/s_ok"
silent "healthy drive, not the heartbeat hour: nothing is sent" "$work/sent"
run_nvme 09 "$work/s_ok"
contains "heartbeat hour: OK line with the drive numbers" "$work/sent" "NVMe: nvme0 used 3%"
valid_json "NVMe heartbeat is valid JSON" "$work/sent"

smart PASSED 0x00 41 100 10 85 0 >"$work/s_worn"
run_nvme 11 "$work/s_worn"
contains "85% of endurance used: alert" "$work/sent" "85% of the rated endurance used"
smart FAILED 0x00 41 100 10 3 0 >"$work/s_fail"
run_nvme 11 "$work/s_fail"
contains "health FAILED: alert" "$work/sent" "overall health is FAILED"
smart PASSED 0x04 41 100 10 3 0 >"$work/s_crit"
run_nvme 11 "$work/s_crit"
contains "critical warning bit set: alert" "$work/sent" "critical warning 0x04"
smart PASSED 0x00 41 100 10 3 7 >"$work/s_media"
run_nvme 11 "$work/s_media"
contains "media errors: alert" "$work/sent" "7 media/data integrity errors"
smart PASSED 0x00 41 8 10 3 0 >"$work/s_spare"
run_nvme 11 "$work/s_spare"
contains "spare at or below threshold: alert" "$work/sent" "available spare 8%"
smart PASSED 0x00 75 100 10 3 0 >"$work/s_hot"
run_nvme 11 "$work/s_hot"
contains "temperature over the limit: alert" "$work/sent" "temperature 75 C"
valid_json "NVMe alert is valid JSON" "$work/sent"

run_nvme 11 "$work/s_ok" FAKE_NO_DEVICE=1
contains "no NVMe device found: alert" "$work/sent" "no NVMe device found"

rm -f "$work/sent"
if FAKE_SMART="$work/s_worn" FAKE_SENT="$work/sent" SMARTCTL="$work/bin/smartctl" CURL="$work/bin/curl" ALERT_HOUR=11 ALERT_WEBHOOK_URL="" bash "$nvme_check" 2>/dev/null; then
    bad "a problem with no webhook configured must fail loudly"
else
    ok "a problem with no webhook configured exits non-zero"
fi

if [ "$fail" -ne 0 ]; then
    echo "check-alerts: FAIL" >&2
    exit 1
fi
echo "check-alerts: PASS"
