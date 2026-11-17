# Password handling for the dev signing keychain (#46, audit F-05). Source this.
#
# The dev identity "Cado Self-Signed" lives in its own keychain. Its password is
# random per machine and kept as a generic password in the LOGIN keychain (service
# SK_SERVICE), created by /usr/bin/security so only `security` reads it silently.
# Before #46 the password was the fixed string "cado-local"; sk_prepare migrates
# such a keychain in place (same certificate, so TCC grants survive).
#
# Residual exposure (honest): any process running as you can read the stored
# password with /usr/bin/security, and use /usr/bin/codesign with the identity
# while the keychain is unlocked. The keychain re-locks after SK_LOCK_TIMEOUT
# seconds idle and package_app.sh locks it on exit. Passwords reach `security`
# via argv (-p/-w), briefly visible to `ps` as the same user; `security` has no
# stdin form for them. From-source dev builds only.
#
# Needs: KEYCHAIN (path of the signing keychain). Overridable for tests:
#   SK_SERVICE, SK_ACCOUNT, SK_LEGACY_PASS, SK_OPENSSL.

SK_SERVICE="${SK_SERVICE:-cado-signing-keychain}"
SK_ACCOUNT="${SK_ACCOUNT:-${USER:-cado}}"
SK_LEGACY_PASS="${SK_LEGACY_PASS:-cado-local}"
SK_OPENSSL="${SK_OPENSSL:-/usr/bin/openssl}"
SK_LOCK_TIMEOUT="${SK_LOCK_TIMEOUT:-300}"

# Prints the stored password. Status: 0 found, 44 not stored (the ONLY "absent"
# answer: errSecItemNotFound), 2 anything else (login keychain locked/denied...).
sk_stored_pass() {
  local out rc=0
  out="$(security find-generic-password -s "$SK_SERVICE" -a "$SK_ACCOUNT" -w 2>/dev/null)" || rc=$?
  case "$rc" in
    0) printf '%s' "$out"; return 0 ;;
    44) return 44 ;;
    *) echo "error: cannot read the signing keychain password from your login keychain (security exit $rc): unlock it and retry" >&2; return 2 ;;
  esac
}

sk_store_pass() {
  security add-generic-password -U -s "$SK_SERVICE" -a "$SK_ACCOUNT" \
    -l "Cado dev signing keychain" -w "$1" -T /usr/bin/security >/dev/null
}

sk_random_pass() { "$SK_OPENSSL" rand -hex 24; }

# Auto-lock after SK_LOCK_TIMEOUT seconds idle (and on sleep).
sk_harden() { security set-keychain-settings -lut "$SK_LOCK_TIMEOUT" "$KEYCHAIN" 2>/dev/null || true; }

# Prints the password to use for the signing keychain, migrating a legacy
# fixed-password keychain first. Status: 0 ok; 1 the keychain exists but neither
# the stored nor the legacy password opens it; 2 the login keychain can't be
# read or written (nothing was created or changed).
# Creating a fresh keychain is the caller's job: when the file is absent this
# prints a NEW random password (stored FIRST, so it is never lost) for the caller.
sk_prepare() {
  local pass rc=0
  pass="$(sk_stored_pass)" || rc=$?
  if [[ "$rc" == 0 ]]; then printf '%s' "$pass"; return 0; fi
  [[ "$rc" == 44 ]] || return 2
  if [[ ! -f "$KEYCHAIN" ]]; then
    pass="$(sk_random_pass)"
    if ! sk_store_pass "$pass"; then
      echo "error: cannot store the new signing keychain password in your login keychain; not creating the keychain" >&2
      return 2
    fi
    printf '%s' "$pass"
    return 0
  fi
  # An existing keychain with nothing stored: the pre-#46 one.
  if security unlock-keychain -p "$SK_LEGACY_PASS" "$KEYCHAIN" 2>/dev/null; then
    pass="$(sk_random_pass)"
    security set-keychain-password -o "$SK_LEGACY_PASS" -p "$pass" "$KEYCHAIN" 2>/dev/null \
      || return 1
    if ! sk_store_pass "$pass"; then
      # Couldn't keep the new password: put the old one back rather than lose it.
      security set-keychain-password -o "$pass" -p "$SK_LEGACY_PASS" "$KEYCHAIN" 2>/dev/null || true
      return 2
    fi
    sk_harden
    printf '%s' "$pass"
    return 0
  fi
  return 1
}
