#!/usr/bin/env python3
"""
OpenCV Zoo SFace(face_recognition_sface_2021dec.onnx) → CoreML 변환.

라이선스: Apache 2.0 (opencv_zoo/models/face_recognition_sface/LICENSE).
InsightFace w600k_mbf(비상업적 연구용 전용)를 대체한다 — 배포 목적.

입력 규약은 ONNX 그래프를 직접 열어 실측 확인했다(문서마다 서로 다른 얘기를
해서 신뢰 안 함):
  그래프의 첫 두 노드가 Sub(127.5) → Mul(0.0078125=1/128) 이다.
  즉 정규화가 그래프 안에 이미 내장돼 있다 — 호출자는 [0,255] 원본 픽셀을
  그대로 RGB/NCHW 순서로만 넣으면 된다. (ArcFace 는 반대로 호출자가
  (x-127.5)/127.5 를 직접 해줘야 했다 — 모델마다 다르므로 절대 넘겨짚지 말 것.)

정렬: SFace 논문 자체가 "InsightFace 설정을 따른다"고 명시하므로, 기존
FaceAligner의 112x112 5점 정렬을 그대로 재사용한다(변경 없음).

출력: 128차원 임베딩 ('fc1').
"""
import sys, pathlib, numpy as np, torch, coremltools as ct
from onnx2torch import convert as onnx_to_torch

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "tools" / "sface.onnx"
DST = ROOT / "Models" / "SFace.mlpackage"
SIZE = 112

def main():
    if not SRC.exists():
        sys.exit(f"ONNX 없음: {SRC}")

    print(f"[1/4] ONNX → PyTorch  ({SRC.name})")
    torch_model = onnx_to_torch(str(SRC)).eval()

    example = torch.rand(1, 3, SIZE, SIZE) * 255.0  # raw [0,255] — 정규화는 그래프 안에서 한다
    with torch.no_grad():
        traced = torch.jit.trace(torch_model, example)

    print("[2/4] PyTorch → CoreML (FP16)")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=(1, 3, SIZE, SIZE), dtype=np.float32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel.short_description = "OpenCV Zoo SFace (Apache-2.0), 128-d face embedding"
    mlmodel.user_defined_metadata["input.layout"] = "NCHW"
    mlmodel.user_defined_metadata["input.channelOrder"] = "RGB"
    mlmodel.user_defined_metadata["input.range"] = "raw [0,255] — 정규화는 그래프 내장"
    mlmodel.user_defined_metadata["output.dim"] = "128"
    mlmodel.user_defined_metadata["output.normalized"] = "false"
    mlmodel.user_defined_metadata["license"] = "Apache-2.0 (opencv_zoo)"

    DST.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(DST))
    print(f"      저장: {DST}")

    print("[3/4] 검증: PyTorch(FP32) vs CoreML(FP16) 임베딩 일치도")
    rng = np.random.default_rng(0)
    sims = []
    for i in range(5):
        x = (rng.uniform(0, 1, (1, 3, SIZE, SIZE)) * 255.0).astype(np.float32)
        with torch.no_grad():
            ref = traced(torch.from_numpy(x)).numpy().ravel()
        got = np.array(mlmodel.predict({"input": x})["embedding"]).ravel()
        cos = float(ref @ got / (np.linalg.norm(ref) * np.linalg.norm(got)))
        sims.append(cos)
        print(f"      샘플 {i}: cosine={cos:.6f}  |ref|={np.linalg.norm(ref):.2f} |got|={np.linalg.norm(got):.2f}")
    worst = min(sims)
    print(f"      최저 일치도 {worst:.6f}")

    print("[4/4] 판정")
    if worst < 0.999:
        sys.exit(f"실패: FP16 변환 손실이 큼 (cosine {worst:.6f} < 0.999)")
    print(f"      통과 — 임베딩 차원 {len(got)}")

if __name__ == "__main__":
    main()
