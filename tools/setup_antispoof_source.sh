#!/bin/bash
# convert_antispoof.py 가 참조하는 Silent-Face-Anti-Spoofing 저장소를 받아온다.
# .gitignore 에서 제외돼 있으므로(자체 .git 이 있어 중첩 저장소가 된다) 필요할 때 이 스크립트로 받는다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/tools/sf"

if [ -d "$DEST" ]; then
    echo "이미 있음: $DEST"
    exit 0
fi

git clone --depth 1 https://github.com/minivision-ai/Silent-Face-Anti-Spoofing.git "$DEST"
echo "받음: $DEST"
