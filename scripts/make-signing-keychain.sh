#!/bin/zsh
# One-time setup for releases: a keychain of Underbrim's own holding "Underbrim Code Signing", a
# self-signed code-signing identity, locking on sleep and after 5 idle minutes. Its password goes
# into the login keychain ("underbrim-signing-keychain"), trusting no app, so each release asks
# first. Secrets reach security only through its stdin; the private key exists only briefly.
#
# Back up the keychain file together with its password: macOS keeps installed
# copies' permissions only while the certificate stays the same.
#
# To remove: security delete-keychain ~/Library/Keychains/underbrim-signing.keychain-db
#            security delete-generic-password -s underbrim-signing-keychain
set -euo pipefail
KC=~/Library/Keychains/underbrim-signing.keychain-db
IDENTITY="Underbrim Code Signing"
[[ ! -e $KC ]] || { echo "$KC already exists" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# print is a shell builtin, so what it sends to security never shows in a process list.
secure() { print -r -- "$1" | security -i >/dev/null; }

PASSWORD=$(openssl rand -base64 32)
secure "create-keychain -p $PASSWORD $KC"
security set-keychain-settings -l -u -t 300 "$KC"
secure "add-generic-password -s underbrim-signing-keychain -a $USER -w $PASSWORD -T \"\""

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12PASS=$(openssl rand -base64 18)
print -r -- "$P12PASS" | openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$IDENTITY" \
  -out "$TMP/identity.p12" -passout stdin
rm "$TMP/key.pem"
# -x: the private key can be used but never exported.
secure "import $TMP/identity.p12 -k $KC -f pkcs12 -P $P12PASS -T /usr/bin/codesign -x"
# Let codesign use the key without asking while the keychain is unlocked.
secure "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PASSWORD $KC"

# Everything is there (attributes only; nothing secret is read).
security find-generic-password -s underbrim-signing-keychain >/dev/null
security find-identity -p codesigning "$KC" | grep "$IDENTITY"
security lock-keychain "$KC"
echo "Made $KC"
