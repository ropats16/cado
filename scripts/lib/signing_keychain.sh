# Password handling for the dev signing keychain (#46, audit F-05). Source this.
#
# The dev identity "Cado Self-Signed" lives in its own keychain. Its password is
# random per machine and kept as a generic password in the LOGIN keychain (service
# SK_SERVICE), created by /usr/bin/security so only `security` reads it silently.
# Before #46 the password was the fixed string "cado-local"; sk_prepare migrates
# such a keychain in place (same certificate, so TCC grants survive).
#
# Needs: KEYCHAIN (path of the signing keychain). Overridable for tests:
#   SK_SERVICE, SK_ACCOUNT, SK_LEGACY_PASS, SK_OPENSSL.

SK_SERVICE="${SK_SERVICE:-cado-signing-keychain}"
SK_ACCOUNT="${SK_ACCOUNT:-${USER:-cado}}"
SK_LEGACY_PASS="${SK_LEGACY_PASS:-cado-local}"
SK_OPENSSL="${SK_OPENSSL:-/usr/bin/openssl}"

# The stored password, or nothing.
sk_stored_pass() {
  security find-generic-password -s "$SK_SERVICE" -a "$SK_ACCOUNT" -w 2>/dev/null || true
}

sk_store_pass() {
  security add-generic-password -U -s "$SK_SERVICE" -a "$SK_ACCOUNT" \
    -l "Cado dev signing keychain" -w "$1" -T /usr/bin/security >/dev/null
}

sk_random_pass() { "$SK_OPENSSL" rand -hex 24; }

# Prints the password to use for the signing keychain, migrating a legacy
# fixed-password keychain first. Prints nothing (and returns 1) if the keychain
# exists but neither the stored nor the legacy password opens it.
# Creating a fresh keychain is the caller's job: when the file is absent this
# prints a NEW random password (stored) for the caller to create it with.
sk_prepare() {
  local pass
  pass="$(sk_stored_pass)"
  if [[ -n "$pass" ]]; then printf '%s' "$pass"; return 0; fi
  if [[ ! -f "$KEYCHAIN" ]]; then
    pass="$(sk_random_pass)"
    sk_store_pass "$pass"
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
      return 1
    fi
    printf '%s' "$pass"
    return 0
  fi
  return 1
}
