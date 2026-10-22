#!/usr/bin/env python3
"""Exercise production Keychain storage in non-UI simulator processes.

Uses a unique, disposable bundle ID and synthetic keys. It does not install,
launch, inspect, or modify the user's WiseLife app or its stored credentials.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="booted", help="Booted iOS simulator UDID")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    arch = subprocess.check_output(["uname", "-m"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="wiselife-keychain-check-") as folder:
        base = Path(folder)
        app = base / "KeychainCheck.app"
        app.mkdir()
        bundle = "cloud.karama.wisenote.keychaincheck." + uuid.uuid4().hex
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle, "CFBundleExecutable": "KeychainCheck",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        }))
        sources = [root / "Sources/iPhone" / name for name in [
            "AIConfiguration.swift", "TranscriptionConfiguration.swift",
            "AppSettings.swift", "KeychainSecretStore.swift",
        ]]
        executable = app / "KeychainCheck"
        def compile_probe(linker_arguments=()):
            subprocess.run([
                "xcrun", "--sdk", "iphonesimulator", "swiftc", "-sdk", sdk,
                "-target", f"{arch}-apple-ios26.0-simulator", *map(str, sources),
                str(root / "Tests/KeychainSimulatorSmoke.swift"), *linker_arguments,
                "-o", str(executable),
            ], env={**os.environ, "SDKROOT": sdk}, check=True)

        compile_probe()

        def run(command):
            subprocess.run(["xcrun", "simctl", "spawn", args.device, str(executable), command], check=True)

        run("unsigned")
        # Match Xcode's simulator signing: iOS entitlements live in the Mach-O
        # __TEXT,__entitlements section, not the host macOS code signature.
        signed_app = base / "SignedKeychainCheck.app"
        signed_app.mkdir()
        (signed_app / "Info.plist").write_bytes((app / "Info.plist").read_bytes())
        executable = signed_app / "KeychainCheck"
        # Ad-hoc signing is sufficient for simulator processes. Never use this on a device build.
        entitlements = base / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({
            "application-identifier": "KEYCHAINTEST." + bundle,
            "keychain-access-groups": ["KEYCHAINTEST." + bundle],
        }))
        compile_probe(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                       "-Xlinker", "__entitlements", "-Xlinker", str(entitlements)])
        subprocess.run(["codesign", "--force", "--sign", "-", str(signed_app)], check=True)
        try:
            for command in ["write", "update", "verify"]:
                run(command)
        finally:
            run("cleanup")
    print("Keychain simulator regression passed: entitlement errors, save, update, restart, secret isolation")


if __name__ == "__main__":
    main()
