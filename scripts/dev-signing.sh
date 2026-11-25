#!/usr/bin/env bash
# Creates (once) a local code-signing certificate just for Ronic JustTerminal.
#
# Why: macOS ties permissions (Documents, Desktop, Downloads, Automation…) to the app's signature. With ad-hoc
# signing, every rebuild becomes a "different app" and macOS asks for everything again.
# Always signing with the SAME certificate keeps the permissions across rebuilds.
#
# The certificate and key live in a dedicated keychain at ~/.ronic-justterminal-signing (outside the repo).
# It never touches the login keychain and never marks anything as trusted system-wide.
#
# The keychain is added to the user's search list (required by codesign).
# Output (stdout): the identity's SHA-1 hash, for `codesign --sign <hash>`.
set -euo pipefail

DIR="$HOME/.ronic-justterminal-signing"
KC="$DIR/ronic-signing.keychain-db"
PASS="ronic-justterminal-local"
NAME="Ronic JustTerminal Local Signing"

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ ! -f "$KC" ]]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS" >/dev/null 2>&1

  security create-keychain -p "$PASS" "$KC" >/dev/null
  security set-keychain-settings "$KC"            # no auto-lock
  security unlock-keychain -p "$PASS" "$KC"
  security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null
fi

security unlock-keychain -p "$PASS" "$KC"

# Make sure the keychain is in the user's search list (without removing existing ones).
current=$(security list-keychains -d user | sed 's/^ *"//; s/"$//')
if ! grep -qxF "$KC" <<<"$current"; then
  # shellcheck disable=SC2086
  security list-keychains -d user -s $current "$KC"
fi

security find-identity -p codesigning "$KC" | awk -v n="\"$NAME\"" '$0 ~ n {print $2; exit}'
