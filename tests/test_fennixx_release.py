import importlib.util
import unittest
from pathlib import Path
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "scripts/fennixx-package-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.info = dict(CFBundleIdentifier="com.fennixx.cmux", CFBundleName="Fennixx CMUX", SUFeedURL=release.FEED, SUPublicEDKey=release.PUBLIC_KEY, CFBundleVersion="104", CFBundleShortVersionString="0.65.0", LSMinimumSystemVersion="26.0")

    def test_identity_key_feed_and_version_must_match(self):
        release.validate_info(self.info, "v0.65.0")
        for field in ("CFBundleIdentifier", "CFBundleName", "SUFeedURL", "SUPublicEDKey", "CFBundleVersion", "CFBundleShortVersionString", "LSMinimumSystemVersion"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.validate_info(dict(self.info, **{field: ""}), "v0.65.0")
        with self.assertRaises(ValueError):
            release.validate_info(self.info, "v0.65.1")
        with self.assertRaises(ValueError):
            release.validate_info(dict(self.info, LSMinimumSystemVersion="14.0"), "v0.65.0")

    def test_appcast_is_scoped_to_fork_version_and_architecture(self):
        root = ET.fromstring(release.make_appcast(self.info, "v0.65.0", "cmux-macos.dmg", 123, "A" * 86 + "=="))
        item = root.find("channel/item")
        self.assertEqual(item.findtext("{" + release.SPARKLE + "}version"), "104")
        self.assertEqual(item.findtext("{" + release.SPARKLE + "}hardwareRequirements"), "arm64")
        self.assertEqual(item.find("enclosure").get("url"), release.REPO + "/releases/download/v0.65.0/cmux-macos.dmg")
        self.assertEqual(item.find("enclosure").get("length"), "123")

    def test_unsigned_or_empty_archive_is_rejected(self):
        for size, signature in [(0, "A" * 86 + "=="), (123, "")]:
            with self.assertRaises(ValueError):
                release.make_appcast(self.info, "v0.65.0", "cmux-macos.dmg", size, signature)


if __name__ == "__main__":
    unittest.main()
