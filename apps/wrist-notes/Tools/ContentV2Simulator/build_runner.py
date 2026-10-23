#!/usr/bin/env python3
"""Compile the SAME Swift algorithm for an iOS Simulator command-line process."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1]).resolve()
output.mkdir(parents=True, exist_ok=True)
app = output / 'ContentV2Runner.app'
app.mkdir(exist_ok=True)
(app / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='com.vessel.wristnotes',
    CFBundleExecutable='ContentV2Runner', CFBundlePackageType='APPL', CFBundleVersion='1')))
entitlements = output / 'runner-entitlements.plist'
entitlements.write_bytes(plistlib.dumps({'application-identifier':'2CT372648C.com.vessel.wristnotes',
    'keychain-access-groups':['2CT372648C.com.vessel.wristnotes']}))
sdk = subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
sources = [root / 'Sources/iPhone/ContentSegmentationV2.swift', root / 'Sources/iPhone/DaybookDatabase.swift',
           root / 'Tools/ContentV2Simulator/Runner.swift']
subprocess.run(['xcrun','--sdk','iphonesimulator','swiftc','-parse-as-library','-sdk',sdk,
    '-target','arm64-apple-ios26.0-simulator', *map(str,sources), '-Xlinker','-sectcreate','-Xlinker','__TEXT',
    '-Xlinker','__entitlements','-Xlinker',str(entitlements),'-o',str(app / 'ContentV2Runner')],
    env={**os.environ,'SDKROOT':sdk},check=True)
subprocess.run(['xattr', '-cr', str(app)], check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print('simulator_runner_built')
