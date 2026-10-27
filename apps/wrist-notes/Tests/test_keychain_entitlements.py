#!/usr/bin/env python3
"""Check that an iOS Simulator build declares its Keychain access group."""
import argparse
from pathlib import Path
import plistlib
import sys
from xml.parsers.expat import ExpatError


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, help="Built .app bundle")
    parser.add_argument(
        "--simulated-entitlements",
        required=True,
        help="Xcode-generated .app-Simulated.xcent file",
    )
    args = parser.parse_args()
    app = Path(args.app)
    try:
        bundle_id = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    except (OSError, KeyError, plistlib.InvalidFileException) as error:
        print(f"Invalid app bundle: {error}", file=sys.stderr)
        return 2

    try:
        entitlements = plistlib.loads(Path(args.simulated_entitlements).read_bytes())
    except (OSError, plistlib.InvalidFileException, ExpatError) as error:
        print(f"Could not parse simulated entitlements: {error}", file=sys.stderr)
        return 2

    groups = entitlements.get("keychain-access-groups", [])
    if entitlements.get("application-identifier") != bundle_id:
        print(f"Simulator application identifier is missing for {bundle_id}", file=sys.stderr)
        return 1
    if bundle_id not in groups:
        print(
            f"Simulator build has no Keychain access group for {bundle_id}",
            file=sys.stderr,
        )
        return 1

    print(f"Simulator Keychain access group verified for {bundle_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
