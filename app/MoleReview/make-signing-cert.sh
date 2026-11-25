#!/bin/bash
# Create the self-signed code-signing identity "Mole Review Local" in the login keychain,
# once. build-app.sh signs with it, so every build keeps the same code identity and macOS
# keeps the app's privacy grants (Full Disk Access, folder access) instead of asking again.
# Safe to re-run: it does nothing when the identity already exists, and finishes a run that
# stopped after the import (certificate present, not yet trusted for code signing).
# macOS asks for your password once, to trust the certificate for code signing.
set -euo pipefail

# shellcheck source=signing-identity.sh
source "$(dirname "$0")/signing-identity.sh"
IDENTITY="$MOLE_REVIEW_IDENTITY"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
[[ -f "$KEYCHAIN" ]] || KEYCHAIN="$HOME/Library/Keychains/login.keychain"

# codesign only uses an identity that is valid, i.e. whose certificate is trusted for code signing.
has_valid_identity() { [[ -n "$(mole_review_identity_hash)" ]]; }

if has_valid_identity; then
    echo "\"$IDENTITY\" already exists and is trusted for code signing; nothing to do."
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT # SAFE: removes only the mktemp directory created above
chmod 700 "$work"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" > /dev/null 2>&1; then
    echo "\"$IDENTITY\" is already in the keychain but not trusted for code signing; trusting it."
    security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$work/cert.pem"
else
    cat > "$work/openssl.cnf" << CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    echo "Creating a self-signed code-signing certificate \"$IDENTITY\" (valid 10 years)..."
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/openssl.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2> /dev/null
    echo "Importing the key and certificate into $KEYCHAIN (codesign may use the key)..."
    security import "$work/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign > /dev/null
    security import "$work/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign > /dev/null
fi

echo "Trusting it for code signing (macOS asks for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/cert.pem"

if has_valid_identity; then
    echo "Done: \"$IDENTITY\" is ready. Run ./build-app.sh; if the first build asks to let codesign use"
    echo "the key, choose Always Allow. Then add the new Mole Review.app under System Settings >"
    echo "Privacy & Security > Full Disk Access once; the grant now survives rebuilds."
else
    echo "The certificate was imported but codesign does not list it as valid yet." >&2
    echo "Check it in Keychain Access (login keychain, My Certificates) and set Code Signing to Always Trust." >&2
    exit 1
fi
