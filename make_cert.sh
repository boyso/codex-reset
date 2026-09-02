#!/bin/bash
# 创建本地代码签名证书（一次性）。
# 用固定证书签名后，辅助功能授权长期有效（ad-hoc 签名每次打包都会变导致授权失效）。
# 用法：./make_cert.sh
set -euo pipefail

CERT="CodexResetDev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# 已存在则跳过（按有效签名身份判断，避免误匹配）
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$CERT\""; then
    echo "证书 $CERT 已存在"
    exit 0
fi

echo "==> 生成密钥与自签名证书…"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$TMPD/key.pem" -out "$TMPD/csr.pem" \
    -subj "/CN=$CERT" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" 2>/dev/null

openssl x509 -req \
    -in "$TMPD/csr.pem" -signkey "$TMPD/key.pem" -out "$TMPD/cert.pem" -days 3650 \
    -extfile <(printf "basicConstraints=critical,CA:true\nkeyUsage=digitalSignature\nextendedKeyUsage=codeSigning") 2>/dev/null

echo "==> 导入钥匙串（login keychain）…"
security import "$TMPD/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -A >/dev/null 2>&1
security import "$TMPD/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign -A >/dev/null 2>&1

echo "==> 完成：证书 $CERT 已创建"
echo "    之后运行 ./make_app.sh 会用它签名（签名固定，辅助功能授权长期有效）"
