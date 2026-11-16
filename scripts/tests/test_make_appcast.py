"""Offline tests for scripts/make_appcast.py (#24).

Run: python3 -m unittest discover -s scripts/tests
"""
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "make_appcast.py")
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class MakeAppcastTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.out = os.path.join(self.dir.name, "appcast.xml")
        self.base = os.path.join(self.dir.name, "base.xml")
        open(self.base, "w").close()   # empty = new feed

    def tearDown(self):
        self.dir.cleanup()

    def run_script(self, version, build, *extra):
        args = [sys.executable, "-I", SCRIPT, "--out", self.out, "--base", self.base,
                "--version", version, "--build", str(build), "--min-os", "14.0",
                "--url", f"https://example.invalid/Cado-{version}.dmg", "--length", "123",
                "--signature", "c2ln", "--notes-url", f"https://example.invalid/v{version}", *extra]
        return subprocess.run(args, capture_output=True, text=True)

    def release(self, version, build):
        """Publishes: the written feed becomes the next base."""
        result = self.run_script(version, build)
        self.assertEqual(result.returncode, 0, result.stderr)
        os.replace(self.out, self.base)

    def items(self, path):
        channel = ET.parse(path).getroot().find("channel")
        return [(i.findtext(SPARKLE + "shortVersionString"), i.findtext(SPARKLE + "version"))
                for i in channel.findall("item")]

    def test_new_release_goes_on_top_of_the_history(self):
        self.release("0.1.0", 100)
        result = self.run_script("0.2.0", 110)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.items(self.out), [("0.2.0", "110"), ("0.1.0", "100")])

    def test_a_build_already_released_under_another_version_is_refused(self):
        self.release("0.2.0", 157)
        result = self.run_script("0.2.1", 157)   # same HEAD, new version
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build 157", result.stderr)
        self.assertIn("0.2.0", result.stderr)
        self.assertFalse(os.path.exists(self.out), "nothing written")

    def test_a_build_not_newer_than_the_feed_is_refused(self):
        self.release("0.2.0", 157)
        result = self.run_script("0.3.0", 150)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("157", result.stderr)
        self.assertFalse(os.path.exists(self.out))

    def test_rerunning_the_same_release_replaces_its_item(self):
        self.release("0.1.0", 100)
        self.release("0.2.0", 157)
        result = self.run_script("0.2.0", 157)   # e.g. the upload failed; run again
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.items(self.out), [("0.2.0", "157"), ("0.1.0", "100")])

    def test_rebuilding_a_version_with_a_newer_build_replaces_it(self):
        self.release("0.2.0", 157)
        result = self.run_script("0.2.0", 160)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.items(self.out), [("0.2.0", "160")])

    def test_check_only_validates_and_writes_nothing(self):
        self.release("0.2.0", 157)
        self.assertNotEqual(self.run_script("0.2.1", 157, "--check").returncode, 0)
        ok = self.run_script("0.2.1", 158, "--check")
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertFalse(os.path.exists(self.out))


if __name__ == "__main__":
    unittest.main()
