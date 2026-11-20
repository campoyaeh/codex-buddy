#!/bin/zsh
set -euo pipefail

CERT_NAME="${1:-Codex Buddy Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -Fq "\"$CERT_NAME\""; then
    print "已存在本地代码签名证书：$CERT_NAME"
    exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/cert.cfg" <<EOF
[req]
distinguished_name = req_dn
x509_extensions = v3_codesign
prompt = no

[req_dn]
CN = $CERT_NAME

[v3_codesign]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$tmpdir/key.pem" \
    -out "$tmpdir/cert.pem" \
    -days 3650 \
    -config "$tmpdir/cert.cfg" 2>/dev/null

# Export PKCS#12 using legacy-compatible cipher so macOS security import always accepts it
/usr/bin/openssl pkcs12 -export \
    -out "$tmpdir/cert.p12" \
    -inkey "$tmpdir/key.pem" \
    -in "$tmpdir/cert.pem" \
    -passout pass:codexbuddy-local 2>/dev/null

security import "$tmpdir/cert.p12" \
    -k "$KEYCHAIN" \
    -P "codexbuddy-local" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

# Mark certificate trusted for Code Signing in the user's login keychain (may prompt Touch ID / login password once)
security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmpdir/cert.pem"

print "本地代码签名证书已创建并设为信任：$CERT_NAME"
print "后续运行 ./scripts/build.sh 和 ./scripts/install.sh 将自动使用该证书签名，无需再重复重新授权辅助功能。"
