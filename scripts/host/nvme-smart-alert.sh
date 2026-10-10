#!/usr/bin/env bash
# NVMe health alert for the k3s host (FDPL-119). It runs on the host from a
# systemd timer, not in Kubernetes: Pods under the restricted Pod Security
# profile cannot read the drive's SMART data.
#
# Posts to the Discord webhook when a drive reports a problem, and once a day
# (ALERT_HEARTBEAT_HOUR, Taipei) an OK line, so a stopped timer is noticed by
# its silence.
#
# Install on the host (as root):
#   apt-get install -y smartmontools curl
#   install -m 0755 scripts/host/nvme-smart-alert.sh /usr/local/sbin/bus-nvme-alert
#   install -m 0644 scripts/host/bus-nvme-alert.service scripts/host/bus-nvme-alert.timer /etc/systemd/system/
#   install -m 0600 /dev/null /etc/bus-alerts.env   # then add one line: ALERT_WEBHOOK_URL=<webhook>
#   systemctl daemon-reload && systemctl enable --now bus-nvme-alert.timer
#   systemctl start bus-nvme-alert.service          # first run; the log shows what it saw
set -u

smartctl="${SMARTCTL:-smartctl}"
curl_bin="${CURL:-curl}"
hour="${ALERT_HOUR:-$(TZ=Asia/Taipei date +%H)}"
heartbeat_hour="${ALERT_HEARTBEAT_HOUR:-09}"
max_used="${MAX_PERCENT_USED:-80}"
max_temp="${MAX_TEMP_C:-70}"
host="$(hostname)"

problems=()
oks=()
found=0
while read -r dev; do
    [ -n "$dev" ] || continue
    found=1
    out="$("$smartctl" -H -A "$dev" 2>&1)"
    name="$(basename "$dev")"
    health="$(awk -F: '/overall-health/ { gsub(/^ +| +$/, "", $2); print $2; exit }' <<<"$out")"
    crit="$(awk -F: '/^Critical Warning/ { gsub(/^ +| +$/, "", $2); print $2; exit }' <<<"$out")"
    used="$(awk -F: '/^Percentage Used/ { gsub(/[^0-9]/, "", $2); print $2; exit }' <<<"$out")"
    spare="$(awk -F: '/^Available Spare:/ { gsub(/[^0-9]/, "", $2); print $2; exit }' <<<"$out")"
    spare_min="$(awk -F: '/^Available Spare Threshold/ { gsub(/[^0-9]/, "", $2); print $2; exit }' <<<"$out")"
    media="$(awk -F: '/^Media and Data Integrity Errors/ { gsub(/[^0-9]/, "", $2); print $2; exit }' <<<"$out")"
    temp="$(awk -F: '/^Temperature:/ { gsub(/[^0-9]/, "", $2); print $2; exit }' <<<"$out")"

    if [ -z "$health" ]; then
        problems+=("$name: could not read SMART data: $(head -c 200 <<<"$out" | tr '\n' ' ')")
        continue
    fi
    [ "$health" = "PASSED" ] || problems+=("$name: overall health is $health")
    [ -z "$crit" ] || [ "$crit" = "0x00" ] || problems+=("$name: critical warning $crit")
    [ -z "$used" ] || ((used < max_used)) || problems+=("$name: ${used}% of the rated endurance used")
    [ -z "$media" ] || ((media == 0)) || problems+=("$name: $media media/data integrity errors")
    [ -z "$spare" ] || [ -z "$spare_min" ] || ((spare > spare_min)) || problems+=("$name: available spare ${spare}% at or below threshold ${spare_min}%")
    [ -z "$temp" ] || ((temp < max_temp)) || problems+=("$name: temperature ${temp} C")
    oks+=("$name used ${used:-?}%, spare ${spare:-?}%, media errors ${media:-?}, ${temp:-?} C")
done < <("$smartctl" --scan 2>/dev/null | awk '/nvme/ { print $1 }')

[ "$found" -eq 1 ] || problems+=("no NVMe device found by smartctl --scan")

text=""
if ((${#problems[@]} > 0)); then
    text="ALERT $host NVMe:"
    for p in "${problems[@]}"; do text+=$'\n'"- $p"; done
elif [ "$hour" = "$heartbeat_hour" ]; then
    text="OK $host NVMe: ${oks[*]}"
fi
[ -z "$text" ] && exit 0

if [ -z "${ALERT_WEBHOOK_URL:-}" ]; then
    echo "bus-nvme-alert: ALERT_WEBHOOK_URL is not set; would have sent: $text" >&2
    exit 1
fi
escaped="$(printf '%s' "$text" | tr '\t' ' ' | cut -c1-1800 | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
printf '{"content":"%s"}\n' "$escaped" | "$curl_bin" -fsS --max-time 20 -X POST -H 'Content-Type: application/json' --data @- "$ALERT_WEBHOOK_URL" >/dev/null
