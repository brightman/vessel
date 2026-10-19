#!/bin/sh
set -eu

app="$1"
watch="$app/Watch/WristNotesWatch.app"
if [ ! -d "$watch" ]; then
  echo "Expected embedded Watch app at $watch" >&2
  exit 1
fi
if [ -d "$app/PlugIns/WristNotesWatch.app" ]; then
  echo "Watch app was packaged as a plugin" >&2
  exit 1
fi
echo "Embedded Watch app location passed"
