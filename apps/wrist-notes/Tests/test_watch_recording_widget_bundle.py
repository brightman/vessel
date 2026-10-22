"""Check the built Watch complication's install boundary, not source text."""
import pathlib
import plistlib
import sys


def read_info(bundle):
    with (bundle / "Info.plist").open("rb") as file:
        return plistlib.load(file)


app = pathlib.Path(sys.argv[1])
watch = app / "Watch" / "WristNotesWatch.app"
widget = watch / "PlugIns" / "WiseLifeWatchRecordingWidget.appex"
assert widget.is_dir(), "Recording widget must be inside the embedded Watch app"
assert not (app / "PlugIns" / widget.name).exists(), "Watch widget cannot be an iPhone extension"
parent_info, widget_info = read_info(watch), read_info(widget)
assert widget_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
assert widget_info["CFBundleIdentifier"].startswith(parent_info["CFBundleIdentifier"] + ".")
assert widget_info["CFBundleSupportedPlatforms"] == parent_info["CFBundleSupportedPlatforms"]
assert set(widget_info["CFBundleSupportedPlatforms"]) <= {"WatchOS", "WatchSimulator"}
assert widget_info["UIDeviceFamily"] == [4]
assert widget_info["MinimumOSVersion"] == "10.0"
for key in ("CFBundleVersion", "CFBundleShortVersionString"):
    assert widget_info[key] == parent_info[key], f"Parent/extension mismatch: {key}"
assert any("wiselife-watch" in item["CFBundleURLSchemes"] for item in parent_info["CFBundleURLTypes"])
assert (widget / widget_info["CFBundleExecutable"]).is_file()
for language in ("en", "ja", "zh-Hans"):
    assert (widget / f"{language}.lproj" / "Localizable.strings").is_file()
print("Built Watch recording widget: platform, bundle scope, versions, URL and resources passed")
