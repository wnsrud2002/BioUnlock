#!/bin/bash
# 개발용 자체서명 코드서명 인증서를 만들어 로그인 키체인에 넣는다.
#
# ad-hoc 서명(codesign -s -)은 코드가 바뀔 때마다 cdhash 가 바뀌고, macOS 는 이를
# 다른 앱으로 본다. 그래서 재빌드마다 카메라 권한을 다시 묻고 키체인 ACL 이 초기화된다.
# 자체서명 인증서로 서명하면 designated requirement 가 인증서 해시에 묶여 빌드 간에 안정된다.
set -euo pipefail

NAME="Unlockface Dev"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "이미 존재: $NAME"
    exit 0
fi

cat > "$TMP/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Unlockface Dev
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null

# PKCS12 는 OpenSSL 3 의 기본 알고리즘을 macOS 임포터가 검증하지 못한다.
# 개인키와 인증서를 PEM 으로 따로 넣으면 키체인이 공개키로 짝을 맞춘다.
# -T /usr/bin/codesign 으로 codesign 이 프롬프트 없이 개인키를 쓰게 한다.
security import "$TMP/key.pem"  -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -A
security import "$TMP/cert.pem" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -A

echo "생성 완료: $NAME"
