#!/bin/zsh
# One-time: create a self-signed code-signing identity in its own keychain (not your login keychain),
# so every NotchPad build has the same signature and macOS keeps its permissions across rebuilds.
set -euo pipefail

NAME="NotchPad Local Signing"
KC="$HOME/Library/Keychains/notchpad-signing.keychain-db"
# The keychain gets a random password generated on this Mac, kept in a private file (never in the repo)
# so build.sh can unlock it without prompting.
PASSFILE="$HOME/Library/Application Support/NotchPad/signing-keychain-password"

if [[ -f "$KC" ]] && security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  echo "Signing identity already set up in $KC"
  exit 0
fi
if [[ -f "$KC" && ! -f "$PASSFILE" ]]; then
  echo "error: $KC exists but its password file is missing; delete the keychain and rerun." >&2
  exit 1
fi
mkdir -p "$(dirname "$PASSFILE")"
if [[ ! -f "$PASSFILE" ]]; then
  (umask 077; openssl rand -hex 24 | tr -d '\n' > "$PASSFILE")
fi
KCPASS=$(cat "$PASSFILE")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# macOS's importer only understands the older PKCS#12 encryption; OpenSSL 3 needs -legacy for that.
LEGACY=()
openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY=(-legacy)
openssl pkcs12 -export "${LEGACY[@]}" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/id.p12" -passout pass:tmp 2>/dev/null

[[ -f "$KC" ]] || security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"          # no auto-lock timeout
security unlock-keychain -p "$KCPASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P tmp -T /usr/bin/codesign >/dev/null
# Let codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null

echo "Created \"$NAME\" in $KC"
