#!/bin/sh
set -eu
# Written into the app bundle before code signing, never into the source tree.
metadata_path="${SCRIPT_OUTPUT_FILE_0:?Missing declared build output}"
build_time=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
/bin/mkdir -p "$(/usr/bin/dirname "$metadata_path")"
cat > "$metadata_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>BuiltAt</key><string>$build_time</string></dict></plist>
PLIST
/usr/bin/plutil -lint "$metadata_path" > /dev/null
