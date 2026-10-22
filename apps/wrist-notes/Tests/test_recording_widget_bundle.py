"""Check the actual built app/extension intent contract, not source spelling.

Usage: python3 Tests/test_recording_widget_bundle.py /path/to/WiseNote.app
"""
import json
from pathlib import Path
import plistlib
import sys


def check(app: Path) -> None:
    extension = app / "PlugIns/WiseLifeRecordingActivity.appex"
    app_info = plistlib.loads((app / "Info.plist").read_bytes())
    extension_info = plistlib.loads((extension / "Info.plist").read_bytes())
    assert app_info["NSSupportsLiveActivities"] is True
    assert extension_info["CFBundleIdentifier"].startswith(app_info["CFBundleIdentifier"] + ".")
    assert extension_info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        assert extension_info[key] == app_info[key], f"App/extension {key} differs"

    metadata = [json.loads((bundle / "Metadata.appintents/extract.actionsdata").read_text())
                for bundle in (app, extension)]
    name = "StartWiseLifeRecordingIntent"
    # Missing extension metadata means the widget cannot archive/resolve its action.
    assert name in metadata[1]["actions"], "Lock Screen extension has no start-recording action"
    required_protocols = {"com.apple.link.systemProtocol.AudioRecording",
                          "com.apple.link.systemProtocol.SessionStarting"}
    for item in metadata:
        action = item["actions"][name]
        assert action["identifier"] == name
        assert required_protocols <= set(action["systemProtocols"]), "Start must run as an app-process recording intent"
        assert not action["parameters"], "Lock Screen start must not require input resolution"
        assert "StopWiseLifeRecordingIntent" in item["actions"], "Existing Live Activity stop was lost"
    assert metadata[0]["actions"][name]["supportedModes"] == metadata[1]["actions"][name]["supportedModes"]
    assert len(metadata[0]["autoShortcuts"]) == 3, "Existing recording shortcuts changed"
    print("Built recording widget contract: passed")


if __name__ == "__main__":
    check(Path(sys.argv[1]))
