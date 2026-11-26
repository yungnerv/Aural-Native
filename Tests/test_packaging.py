import hashlib
import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
from package import package


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.app = root / "Aural.app"
        self.app.mkdir()
        self.output = root / "output"
        self.executable = self.app / "Aural"
        self.executable.write_bytes(b"test executable")
        self.executable.chmod(0o755)
        self.info = {
            "CFBundleIdentifier": "local.aural.player",
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "5",
            "CFBundleExecutable": "Aural",
        }
        self.save_info()

    def save_info(self):
        with (self.app / "Info.plist").open("wb") as stream:
            plistlib.dump(self.info, stream, fmt=plistlib.FMT_BINARY)

    def build(self):
        return package(self.app, self.output, "0.2.0", "5", "a" * 40)

    def test_valid_archive_and_checksum(self):
        ipa = self.build()
        with zipfile.ZipFile(ipa) as archive:
            self.assertIsNone(archive.testzip())
            item = archive.getinfo("Payload/Aural.app/Aural")
            self.assertTrue((item.external_attr >> 16) & 0o111)
            self.assertEqual(archive.read(item), b"test executable")
            self.assertEqual(plistlib.loads(archive.read("Payload/Aural.app/Info.plist")), self.info)
        self.assertEqual((self.output / "SHA256SUMS.txt").read_text().split()[0],
                         hashlib.sha256(ipa.read_bytes()).hexdigest())
        self.assertIn("Unsigned: yes", (self.output / "BUILD.txt").read_text())

    def test_bundle_mismatch_does_not_publish(self):
        self.info["CFBundleVersion"] = "4"
        self.save_info()
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_missing_executable_does_not_publish(self):
        self.executable.unlink()
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_nonexecutable_does_not_publish(self):
        self.executable.chmod(0o644)
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_symlink_is_preserved(self):
        os.symlink("Aural", self.app / "Alias")
        with zipfile.ZipFile(self.build()) as archive:
            item = archive.getinfo("Payload/Aural.app/Alias")
            self.assertTrue(stat.S_ISLNK(item.external_attr >> 16))
            self.assertEqual(archive.read(item), b"Aural")

    def test_outside_symlink_is_rejected(self):
        os.symlink("../outside", self.app / "Alias")
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_previous_good_output_survives_failed_validation(self):
        ipa = self.build()
        previous = ipa.read_bytes()
        self.info["CFBundleIdentifier"] = "wrong.id"
        self.save_info()
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual(ipa.read_bytes(), previous)


if __name__ == "__main__":
    unittest.main()
