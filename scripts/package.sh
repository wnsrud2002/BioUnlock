#!/bin/bash
# 배포용 유니버설 바이너리(.app)를 만들고 ZIP 으로 묶는다.
# scripts/build.sh 는 개발 중 빠른 반복용(단일 아키텍처, debug) 이고,
# 이 스크립트는 실제로 GitHub Releases 에 올릴 산출물을 만든다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/BioUnlock.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
ZIP="$ROOT/build/BioUnlock-$VERSION.zip"

cd "$ROOT"

echo "[1/5] arm64 + x86_64 release 빌드"
swift build -c release --arch arm64 --arch x86_64

echo "[2/5] 유니버설 바이너리로 합치기"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
    ".build/apple/Products/Release/BioUnlock" \
    -output "$APP/Contents/MacOS/BioUnlock" 2>/dev/null \
|| lipo -create \
    ".build/arm64-apple-macosx/release/BioUnlock" \
    ".build/x86_64-apple-macosx/release/BioUnlock" \
    -output "$APP/Contents/MacOS/BioUnlock"
file "$APP/Contents/MacOS/BioUnlock"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "[3/5] CoreML 모델 컴파일"
for pkg in "$ROOT"/Models/*.mlpackage; do
    [ -e "$pkg" ] || continue
    xcrun coremlcompiler compile "$pkg" "$APP/Contents/Resources" >/dev/null
done

echo "[4/5] 코드서명"
IDENTITY="Unlockface Dev"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    IDENTITY="-"
    echo "경고: '$IDENTITY' 인증서 없음 — ad-hoc 서명 사용. ./scripts/setup-signing.sh 실행 권장" >&2
fi
codesign --force --sign "$IDENTITY" \
    --entitlements "$ROOT/Resources/BioUnlock.entitlements" \
    "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature"

echo "[5/5] ZIP 압축"
rm -f "$ZIP"
# ditto 가 macOS 앱 번들의 리소스 포크/메타데이터를 보존한다(cp/zip 은 깨뜨릴 수 있다).
ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "완료: $ZIP ($(du -h "$ZIP" | cut -f1))"
