#!/bin/sh
# Create and verify a signed archive + App Store IPA. This script never uploads.
set -eu
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  echo "Usage: sh scripts/package_release.sh OUTPUT_DIRECTORY [DERIVED_DATA_DIRECTORY] [SOURCE_PACKAGES_DIRECTORY]" >&2
  exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$1"
release_dir=$(CDPATH= cd -- "$1" && pwd)
derived_data=${2:-"$release_dir/DerivedData"}
source_packages=${3:-"$derived_data/SourcePackages"}
archive_path="$release_dir/WiseLife.xcarchive"
if [ -e "$archive_path" ] || [ -e "$release_dir/export" ]; then
  echo "Choose a new output directory; existing release artifacts will not be overwritten." >&2
  exit 2
fi
mkdir -p "$derived_data" "$source_packages"
derived_data=$(CDPATH= cd -- "$derived_data" && pwd)
source_packages=$(CDPATH= cd -- "$source_packages" && pwd)
cd "$script_dir/.."

# Exporting an unsigned archive can silently drop app-specific entitlements.
xcodebuild -workspace WristNotes.xcworkspace -scheme WristNotes \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$archive_path" -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$source_packages" -disableAutomaticPackageResolution \
  -allowProvisioningUpdates -jobs 3 IPHONEOS_DEPLOYMENT_TARGET=26.0 \
  CODE_SIGNING_ALLOWED=YES archive
if ! python3 scripts/verify_healthkit_signing.py \
  --app "$archive_path/Products/Applications/WiseLife.app" \
  > "$release_dir/archive-healthkit.json"; then
  cat "$release_dir/archive-healthkit.json"
  exit 1
fi
cat "$release_dir/archive-healthkit.json"

cat > "$release_dir/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>stripSwiftSymbols</key><true/>
  <key>uploadSymbols</key><true/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive_path" \
  -exportPath "$release_dir/export" -exportOptionsPlist "$release_dir/ExportOptions.plist" \
  -allowProvisioningUpdates
if ! python3 scripts/verify_healthkit_signing.py \
  --ipa "$release_dir/export/WiseLife.ipa" --require-distribution \
  > "$release_dir/ipa-healthkit.json"; then
  cat "$release_dir/ipa-healthkit.json"
  exit 1
fi
cat "$release_dir/ipa-healthkit.json"
