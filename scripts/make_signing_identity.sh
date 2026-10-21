#!/bin/sh
# One-time: a self-signed "Cooldown Local Signing" identity in its own keychain, so every build
# carries the same signature and macOS keeps the permissions it granted to Cooldown.
set -e
D="$HOME/Library/Application Support/Cooldown/signing"; mkdir -p "$D"; cd "$D"
KC="$HOME/Library/Keychains/cooldown-signing.keychain-db"
if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "Cooldown Local Signing"; then echo "Already there."; exit 0; fi
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Cooldown Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
# A random password for this keychain, remembered in the login keychain (never in the repository).
PASS=$(security find-generic-password -s "Cooldown signing keychain" -w 2>/dev/null || true)
if [ -z "$PASS" ]; then
  PASS=$(openssl rand -hex 24)
  security add-generic-password -s "Cooldown signing keychain" -a "$USER" -w "$PASS"
fi
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Cooldown Local Signing" -out id.p12 -passout "pass:$PASS" 2>/dev/null
[ -f "$KC" ] || security create-keychain -p "$PASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import id.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
rm -f key.pem id.p12
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"' | grep -v cooldown-signing)
echo "Created."
