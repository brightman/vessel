#!/usr/bin/env python3
"""Verify HealthKit in the actual iPhone signature and embedded profile before delivery."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile


REQUIRED = (
    "com.apple.developer.healthkit",
    "com.apple.developer.healthkit.background-delivery",
)


def run(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise ValueError(f"{args[0]} {args[1]} failed (exit {result.returncode})")
    return result.stdout


def verify(app, distribution):
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "cloud.karama.wisenote":
        raise ValueError("Expected the WiseLife iPhone app, not a Watch app or extension")
    if info.get("DTPlatformName") != "iphoneos":
        raise ValueError("Expected an iPhone device build, not a Simulator build")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    signed = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(app)))
    profile = plistlib.loads(run("security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")))
    allowed = profile["Entitlements"]
    missing = [key for key in REQUIRED if signed.get(key) is not True]
    if missing:
        raise ValueError("App signature missing required entitlement(s): " + ", ".join(missing))
    if any(allowed.get(key) is not True for key in REQUIRED):
        raise ValueError("Provisioning profile does not allow both required HealthKit entitlements")
    if distribution and (signed.get("get-task-allow") is not False or allowed.get("get-task-allow") is not False):
        raise ValueError("Expected a distribution signature with get-task-allow=false")
    if not info.get("NSHealthShareUsageDescription"):
        raise ValueError("Missing HealthKit read usage description")
    return {"ok": True, "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "signed_healthkit": True, "signed_background_delivery": True,
            "profile_healthkit": True, "profile_background_delivery": True,
            "distribution": signed.get("get-task-allow") is False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--app", type=Path)
    source.add_argument("--ipa", type=Path)
    parser.add_argument("--require-distribution", action="store_true")
    args = parser.parse_args()
    try:
        if args.app:
            result = verify(args.app, args.require_distribution)
        else:
            # Avoid Finder metadata from extracting under Documents; never alter the IPA.
            with tempfile.TemporaryDirectory(prefix="wiselife-signing-", dir="/private/tmp") as temp:
                with zipfile.ZipFile(args.ipa) as archive:
                    for member in archive.infolist():
                        target = (Path(temp) / member.filename).resolve()
                        if not target.is_relative_to(Path(temp)):
                            raise ValueError("IPA contains a path outside its extraction directory")
                    archive.extractall(temp)
                apps = list((Path(temp) / "Payload").glob("*.app"))
                if len(apps) != 1:
                    raise ValueError("Expected exactly one iPhone app in IPA Payload")
                result = verify(apps[0], args.require_distribution)
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
