#!/bin/zsh

set -euo pipefail

minutes="${1:-15}"
if [[ ! "$minutes" =~ '^[0-9]+$' ]] || (( minutes < 1 )); then
    print -u2 "usage: $0 [minutes] [output-directory]"
    exit 64
fi

timestamp="$(date '+%Y%m%d-%H%M%S')"
output_directory="${2:-Tsubame-logs-${timestamp}}"
text_log="${output_directory}/Tsubame.log"
archive="${output_directory}/Tsubame.logarchive"

mkdir -p "$output_directory"

/usr/bin/log show \
    --last "${minutes}m" \
    --style compact \
    --predicate 'subsystem == "com.krnya.Tsubame"' \
    > "$text_log"

/usr/bin/log collect \
    --last "${minutes}m" \
    --output "$archive"

{
    print "Generated: $(date -Iseconds)"
    print "Window: ${minutes} minutes"
    print "Subsystem: com.krnya.Tsubame"
    /usr/bin/sw_vers
} > "${output_directory}/metadata.txt"

print "Tsubame diagnostics written to: ${output_directory}"
print "Text log: ${text_log}"
print "Archive: ${archive}"
