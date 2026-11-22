#!/bin/bash
# Shield 1.1 public installer: writes the service configuration for THIS Mac.
# Upgrade: keeps the installed user and time zone exactly (the service refuses
# a change). Fresh install: the user logged in at the screen and this Mac's
# time zone. Usage: make_service_plist.sh <template.plist> <output.plist>
set -euo pipefail
template=$1
output=$2
installed='/Library/Application Support/ShieldAuthority/service.plist'
if [ -f "$installed" ]; then
  uid=$(/usr/libexec/PlistBuddy -c 'Print :allowedUID' "$installed")
  zone=$(/usr/libexec/PlistBuddy -c 'Print :timeZoneIdentifier' "$installed")
else
  uid=$(stat -f %u /dev/console)
  zone=$(readlink /etc/localtime | sed -n 's#^.*/zoneinfo/##p')
fi
[[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 500 ] || { echo 'Install Shield while logged in as the person who will use it.' >&2; exit 1; }
[[ "$zone" =~ ^[A-Za-z0-9_+/-]+$ ]] || { echo "Unreadable time zone: $zone" >&2; exit 1; }
/usr/bin/python3 - "$template" "$output" "$uid" "$zone" <<'PY'
import plistlib, sys
template, output, uid, zone = sys.argv[1:]
with open(template, 'rb') as stream: values = plistlib.load(stream)
values.update(allowedUID=int(uid), timeZoneIdentifier=zone)
with open(output, 'wb') as stream: plistlib.dump(values, stream)
PY
chmod 600 "$output"
