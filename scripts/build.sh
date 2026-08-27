#!/bin/bash
# SPM 산출물을 .app 번들로 조립한다.
# 카메라 TCC 권한은 번들 식별자 + 코드서명이 있어야 부여되므로 바이너리 직접 실행은 안 된다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/BioUnlock.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BioUnlock"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BioUnlock"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# CoreML 모델은 미리 컴파일해서 넣는다. 런타임 컴파일은 첫 인증을 몇 초 지연시킨다.
for pkg in "$ROOT"/Models/*.mlpackage; do
    [ -e "$pkg" ] || continue
    xcrun coremlcompiler compile "$pkg" "$APP/Contents/Resources" >/dev/null
done

# 자체서명 개발 인증서가 있으면 그걸 쓴다. ad-hoc 은 빌드마다 cdhash 가 바뀌어
# macOS 가 다른 앱으로 보고, 카메라 권한과 키체인 ACL 이 매번 초기화된다.
# (그 때문에 마스터 키가 덮여 프로필을 잃은 적이 있다. scripts/setup-signing.sh 참고)
IDENTITY="Unlockface Dev"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    IDENTITY="-"
    echo "경고: '$IDENTITY' 인증서 없음 — ad-hoc 서명 사용. ./scripts/setup-signing.sh 실행 권장" >&2
fi

codesign --force --sign "$IDENTITY" \
    --entitlements "$ROOT/Resources/BioUnlock.entitlements" \
    "$APP" >/dev/null

echo "built: $APP"
