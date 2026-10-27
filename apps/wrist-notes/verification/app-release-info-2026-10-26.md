# Settings version and release time

- Both Settings entry points display version/build and release time below About.
- Version/build come from the app bundle's CFBundleShortVersionString/CFBundleVersion.
- The iPhone target's always-run “Write build metadata” phase writes BuildMetadata.plist
  into the built bundle before signing. BuiltAt is an ISO-8601 UTC build timestamp.
- Build and Archive each generate their timestamp; exporting an existing archive
  preserves that archive's timestamp. This is package build time, not App Store approval time.
- UI displays date/time with an explicit UTC suffix; missing metadata displays 未提供.
- The project generator preserves the phase, declared input/output, and source membership.
- test_release_info.sh passed: packaged version/build, valid recent timestamp and stable reads.
- ProjectSourceMembershipSmoke.rb and git diff --check passed.
- Full iOS Simulator workspace Debug build passed. Verified BuildMetadata.plist
  inside the actual WiseNote.app product contains BuiltAt, and Info.plist version is 1.0.1.
- Archive signing/export was not exercised in this task.
