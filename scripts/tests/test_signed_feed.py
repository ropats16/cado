"""Signed-feed tests (#46). Uses a throwaway Ed25519 key file with Sparkle's
sign_update (-f), so nothing reads or prompts the login keychain.

Skipped when Sparkle's tools aren't resolved (`swift package resolve`).
Run: python3 -m unittest discover -s scripts/tests
"""
import base64
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
SIGN_UPDATE = os.path.join(ROOT, ".build/artifacts/sparkle/Sparkle/bin/sign_update")
VERIFIER = os.path.join(ROOT, "scripts/verify_update_signature.swift")
APPCAST = os.path.join(ROOT, "scripts/make_appcast.py")

KEYGEN = """import CryptoKit
import Foundation
let k = Curve25519.Signing.PrivateKey()
print(k.rawRepresentation.base64EncodedString())
print(k.publicKey.rawRepresentation.base64EncodedString())
"""


@unittest.skipUnless(os.access(SIGN_UPDATE, os.X_OK), "Sparkle tools not resolved")
class SignedFeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        gen = os.path.join(cls.dir.name, "gen.swift")
        with open(gen, "w") as f:
            f.write(KEYGEN)
        out = subprocess.run(["swift", gen], capture_output=True, text=True, check=True).stdout.split()
        cls.priv, cls.pub = out[0], out[1]
        cls.keyfile = os.path.join(cls.dir.name, "key")
        with open(cls.keyfile, "w") as f:
            f.write(cls.priv)

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def make_feed(self, name="appcast.xml"):
        path = os.path.join(self.dir.name, name)
        open(path, "w").close()
        subprocess.run([sys.executable, "-I", APPCAST, "--out", path, "--base", path,
                        "--version", "0.2.0", "--build", "10", "--min-os", "14.0",
                        "--url", "https://example.invalid/Cado-0.2.0.dmg", "--length", "1",
                        "--signature", "c2ln", "--notes-url", "https://example.invalid/v"],
                       check=True, capture_output=True)
        return path

    def sign(self, path):
        subprocess.run([SIGN_UPDATE, "-f", self.keyfile, path], check=True, capture_output=True)

    def verify(self, path, pub=None):
        return subprocess.run(["swift", VERIFIER, "--feed", pub or self.pub, path],
                              capture_output=True, text=True)

    def test_a_signed_feed_verifies_with_the_public_key(self):
        feed = self.make_feed()
        self.sign(feed)
        result = self.verify(feed)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_an_unsigned_feed_is_refused(self):
        result = self.verify(self.make_feed())
        self.assertEqual(result.returncode, 1)
        self.assertIn("no embedded signature", result.stderr)

    def test_a_feed_edited_after_signing_is_refused(self):
        feed = self.make_feed()
        self.sign(feed)
        with open(feed) as f:
            text = f.read()
        with open(feed, "w") as f:
            f.write(text.replace("Cado 0.2.0", "Cado 9.9.9"))
        self.assertEqual(self.verify(feed).returncode, 1)

    def test_a_different_key_is_refused(self):
        feed = self.make_feed()
        self.sign(feed)
        other = base64.b64encode(bytes(32)).decode()
        self.assertNotEqual(self.verify(feed, pub=other).returncode, 0)

    def test_a_signed_feed_can_be_the_base_of_the_next_release(self):
        feed = self.make_feed()
        self.sign(feed)
        nxt = os.path.join(self.dir.name, "next.xml")
        subprocess.run([sys.executable, "-I", APPCAST, "--out", nxt, "--base", feed,
                        "--version", "0.2.1", "--build", "11", "--min-os", "14.0",
                        "--url", "https://example.invalid/Cado-0.2.1.dmg", "--length", "1",
                        "--signature", "c2ln", "--notes-url", "https://example.invalid/v"],
                       check=True, capture_output=True)
        with open(nxt) as f:
            text = f.read()
        self.assertNotIn("sparkle-signatures", text, "the old signature must not survive into the new feed")
        self.assertEqual(self.verify(nxt).returncode, 1)  # unsigned until re-signed
        self.sign(nxt)
        self.assertEqual(self.verify(nxt).returncode, 0)


if __name__ == "__main__":
    unittest.main()
