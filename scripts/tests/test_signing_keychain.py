"""Tests for scripts/lib/signing_keychain.sh (#46, F-05) against a fake `security`.

The fake keeps "keychains" as files holding their password and the login-keychain
item as a file, so nothing touches the real keychain. Run:
python3 -m unittest discover -s scripts/tests
"""
import os
import stat
import subprocess
import tempfile
import unittest

LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "signing_keychain.sh")

FAKE_SECURITY = r'''#!/bin/bash
# State: $FAKE_DIR/item (stored password), keychain files hold their password.
set -u
cmd="$1"; shift
echo "$cmd $*" >> "$FAKE_DIR/calls"
case "$cmd" in
  find-generic-password) [[ -f "$FAKE_DIR/item" ]] && cat "$FAKE_DIR/item" || exit 44 ;;
  add-generic-password)
    [[ -f "$FAKE_DIR/store-fails" ]] && exit 1
    while [[ $# -gt 0 ]]; do [[ "$1" == "-w" ]] && { printf '%s' "$2" > "$FAKE_DIR/item"; break; }; shift; done ;;
  unlock-keychain)
    [[ "$1" == "-p" ]] || exit 2
    [[ "$(cat "${3}")" == "$2" ]] || exit 51 ;;
  set-keychain-password)
    old=""; new=""; kc=""
    while [[ $# -gt 0 ]]; do
      case "$1" in -o) old="$2"; shift 2;; -p) new="$2"; shift 2;; *) kc="$1"; shift;; esac
    done
    [[ "$(cat "$kc")" == "$old" ]] || exit 51
    printf '%s' "$new" > "$kc" ;;
  *) exit 99 ;;
esac
'''


class SigningKeychainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.tmp.name
        self.bin = os.path.join(d, "bin")
        os.mkdir(self.bin)
        fake = os.path.join(self.bin, "security")
        with open(fake, "w") as f:
            f.write(FAKE_SECURITY)
        os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)
        self.keychain = os.path.join(d, "cado-signing.keychain-db")

    def tearDown(self):
        self.tmp.cleanup()

    def path(self, name):
        return os.path.join(self.tmp.name, name)

    def prepare(self):
        env = dict(os.environ, PATH=self.bin + ":" + os.environ["PATH"], FAKE_DIR=self.tmp.name,
                   KEYCHAIN=self.keychain, SK_OPENSSL="/usr/bin/openssl")
        r = subprocess.run(["bash", "-c", f'source "{LIB}"; sk_prepare'], env=env,
                           capture_output=True, text=True)
        return r

    def calls(self):
        p = self.path("calls")
        return open(p).read() if os.path.exists(p) else ""

    def test_a_fresh_machine_gets_a_random_stored_password(self):
        r = self.prepare()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(r.stdout), 48)
        self.assertNotEqual(r.stdout, "cado-local")
        self.assertEqual(open(self.path("item")).read(), r.stdout)

    def test_two_machines_get_different_passwords(self):
        first = self.prepare().stdout
        os.remove(self.path("item"))
        self.assertNotEqual(first, self.prepare().stdout)

    def test_the_stored_password_is_reused(self):
        open(self.path("item"), "w").write("stored-secret")
        open(self.keychain, "w").write("stored-secret")
        r = self.prepare()
        self.assertEqual((r.returncode, r.stdout), (0, "stored-secret"))
        self.assertNotIn("set-keychain-password", self.calls())

    def test_an_old_fixed_password_keychain_is_migrated_in_place(self):
        open(self.keychain, "w").write("cado-local")
        r = self.prepare()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(r.stdout), 48)
        self.assertEqual(open(self.keychain).read(), r.stdout, "keychain now opens with the new password")
        self.assertEqual(open(self.path("item")).read(), r.stdout)
        # Same keychain file, so the certificate (and TCC grants) are untouched.
        self.assertNotIn("delete", self.calls())

    def test_a_failed_store_puts_the_old_password_back(self):
        open(self.keychain, "w").write("cado-local")
        open(self.path("store-fails"), "w").close()
        r = self.prepare()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(open(self.keychain).read(), "cado-local")

    def test_a_keychain_with_an_unknown_password_is_reported_not_clobbered(self):
        open(self.keychain, "w").write("something-else")
        r = self.prepare()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(open(self.keychain).read(), "something-else")
        self.assertFalse(os.path.exists(self.path("item")))


class ScriptShapeTests(unittest.TestCase):
    """The scripts no longer carry the fixed password or -A."""

    def read(self, name):
        with open(os.path.join(os.path.dirname(LIB), "..", name)) as f:
            return f.read()

    def test_no_fixed_password_outside_the_migration_constant(self):
        for name in ("create_signing_cert.sh", "package_app.sh"):
            self.assertNotIn("cado-local", self.read(name), name)

    def test_the_key_is_not_imported_for_any_application(self):
        script = self.read("create_signing_cert.sh")
        import_lines = [l for l in script.splitlines() if l.startswith("security import")]
        self.assertEqual(len(import_lines), 1)
        self.assertNotIn(" -A", import_lines[0])
        self.assertIn("-T /usr/bin/codesign", import_lines[0])


if __name__ == "__main__":
    unittest.main()
