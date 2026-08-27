#!/bin/bash
# 모델 변환 도구 일체를 준비한다. 이 프로젝트를 그대로 클론했을 때 모델을
# 처음부터 재현하고 싶은 사람을 위한 것이지, 앱을 빌드하는 데는 필요 없다
# (Models/*.mlpackage 는 이미 변환·검증까지 끝나 저장소에 포함돼 있다).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/tools"

if [ ! -d .venv ]; then
    python3 -m venv .venv
fi
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q coremltools onnx torch onnx2torch onnxruntime

if [ ! -f sface.onnx ]; then
    curl -sL -o sface.onnx \
        "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx"
fi

"$ROOT/tools/setup_antispoof_source.sh"

echo ""
echo "준비 완료. 다음으로 변환:"
echo "  tools/.venv/bin/python tools/convert_sface.py"
echo "  tools/.venv/bin/python tools/convert_antispoof.py"
