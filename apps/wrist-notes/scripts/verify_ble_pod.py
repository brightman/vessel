#!/usr/bin/env python3
"""Verify the shipped native BLE pod without accessing the source SDK repository."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess


def main():
    root = Path(__file__).resolve().parents[3] / "pods/br_flutter_plugin_ble"
    manifest = json.loads((root / "manifest.json").read_text())
    assert manifest["bluetooth_revision"] == "d70596a298cb4844641ff05cdbbe384b7f804d46"
    assert manifest["opus_archive_sha256"] == "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"
    for relative, expected in manifest["files"].items():
        path = (root / relative).resolve()
        assert path.is_relative_to(root.resolve()), f"Unexpected manifest path: {relative}"
        assert path.is_file(), f"Missing package file: {relative}"
        assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, f"Checksum mismatch: {relative}"
    for module in ["BRBluetoothLib", "BRRecorderCore", "BRRecorderOpus"]:
        framework = root / "Frameworks" / (module + ".xcframework")
        info = plistlib.loads((framework / "Info.plist").read_bytes())
        assert len(info["AvailableLibraries"]) == 2
        for library in info["AvailableLibraries"]:
            simulator = library.get("SupportedPlatformVariant") == "simulator"
            architectures = {"arm64", "x86_64"} if simulator else {"arm64"}
            assert library["SupportedPlatform"] == "ios"
            assert set(library["SupportedArchitectures"]) == architectures
            bundle = framework / library["LibraryIdentifier"] / library["LibraryPath"]
            binary = bundle / module
            actual = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True).split()
            assert set(actual) == architectures, f"Unexpected architectures in {binary}"
            if module != "BRRecorderOpus":
                for architecture in architectures:
                    triple = architecture + "-apple-ios" + ("-simulator" if simulator else "")
                    assert (bundle / "Modules" / (module + ".swiftmodule") / (triple + ".swiftinterface")).is_file(), f"Missing portable Swift interface: {module}/{triple}"
    print(f"Native BLE Pod verified: {len(manifest['files'])} checksums, 3 XCFrameworks, device arm64 + simulator arm64/x86_64, portable Swift interfaces.")


if __name__ == "__main__":
    main()
