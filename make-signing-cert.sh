#!/bin/bash
# Creates the local code signing identity used by build.sh. Run once.
#
# Why: macOS keys TCC permission grants to an app's designated requirement. For
# an ad-hoc signed app that requirement contains the cdhash, which changes on
# every recompile — so each build looks like a new app and macOS re-asks for
# every permission. Signing with a certificate makes the requirement
# (bundle id + certificate root), which stays put across rebuilds.
#
# The certificate is self-signed and lives only in your login keychain. It is
# NOT added to the system trust store and is NOT marked as a trusted root —
# codesign does not need that, so this stays as narrow as it can be. Its only
# capability is Code Signing, and nothing outside this machine trusts it.
set -euo pipefail

NAME="ClaudeUsage Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "already exists: $NAME"
    echo "to recreate it, remove the old one first:"
    echo "  security delete-certificate -c \"$NAME\""
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT   # the private key must not outlive the import

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=$NAME/O=Local Development" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -certpbe/-keypbe/-macalg: OpenSSL 3 defaults to encryption the macOS keychain
# cannot read, and the import fails with a misleading "wrong password" error.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass:cu -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

# -T limits use of the key to codesign rather than every binary on the machine.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P cu -T /usr/bin/codesign

echo
echo "created: $NAME (valid 10 years, code signing only)"
echo "run ./build.sh now. The first time codesign uses this key,"
echo "the keychain asks once — choose \"Always Allow\" to stop it asking again."
