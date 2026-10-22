#!/usr/bin/env python3
"""Check the iPhone app's required user-facing privacy purpose strings."""

from pathlib import Path
import plistlib
import unittest


ROOT = Path(__file__).resolve().parents[1]


class AppPrivacyMetadataTests(unittest.TestCase):
    def test_healthkit_update_purpose_string_is_present_and_explains_read_only_use(self):
        with (ROOT / "Sources/iPhone/Info.plist").open("rb") as source:
            info = plistlib.load(source)

        purpose = info.get("NSHealthUpdateUsageDescription", "").strip()
        self.assertTrue(purpose, "NSHealthUpdateUsageDescription must be included")
        self.assertIn("不会", purpose)
        self.assertIn("写入", purpose)
        self.assertIn("步数", purpose)
        self.assertIn("睡眠", purpose)

    def test_watch_companion_build_number_matches_ios_release_build(self):
        with (ROOT / "Sources/Watch/Info.plist").open("rb") as source:
            watch_info = plistlib.load(source)
        project = (ROOT / "WristNotes.xcodeproj/project.pbxproj").read_text()
        import re

        versions = re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", project)
        self.assertTrue(versions)
        self.assertEqual(set(versions), {watch_info["CFBundleVersion"]})
        self.assertEqual(watch_info["CFBundleShortVersionString"], "1.0")


if __name__ == "__main__":
    unittest.main()
