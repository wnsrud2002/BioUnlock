#!/usr/bin/env python3
"""
Silent-Face-Anti-Spoofing (MiniFASNet) → CoreML 변환.

두 모델을 앙상블한다:
  2.7_80x80_MiniFASNetV2   — bbox 를 2.7배 확대해 크롭 (얼굴 + 주변)
  4_0_0_80x80_MiniFASNetV1SE — 4.0배 (더 넓은 맥락: 화면 테두리·손·배경 경계)

입력 규약 (원본 저장소 그대로여야 한다):
  BGR / [0,1] / NCHW / 80x80    ← cv2.imread 는 BGR 이고 ToTensor 는 채널을 바꾸지 않는다
출력: 3클래스 로짓. softmax 후 두 모델을 더하고 argmax. 인덱스 1 이 실물.
"""
import sys, pathlib, numpy as np, torch, coremltools as ct

ROOT = pathlib.Path(__file__).resolve().parent.parent
SF = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "tools" / "sf"
sys.path.insert(0, str(SF))

from src.model_lib.MiniFASNet import MiniFASNetV2, MiniFASNetV1SE   # noqa: E402
from src.utility import parse_model_name, get_kernel                # noqa: E402

MAPPING = {"MiniFASNetV2": MiniFASNetV2, "MiniFASNetV1SE": MiniFASNetV1SE}
SIZE = 80

def load_torch(pth: pathlib.Path):
    h, w, model_type, scale = parse_model_name(pth.name)
    kernel = get_kernel(h, w)
    model = MAPPING[model_type](conv6_kernel=kernel)
    state = torch.load(pth, map_location="cpu")
    first = next(iter(state))
    if first.startswith("module."):
        state = {k[7:]: v for k, v in state.items()}
    model.load_state_dict(state)
    model.eval()
    return model, scale, model_type

def main():
    models_dir = SF / "resources" / "anti_spoof_models"
    out_dir = ROOT / "Models"
    out_dir.mkdir(exist_ok=True)
    meta = []

    for pth in sorted(models_dir.glob("*.pth")):
        model, scale, model_type = load_torch(pth)
        print(f"[{pth.name}]  type={model_type} scale={scale}")

        example = torch.rand(1, 3, SIZE, SIZE)
        with torch.no_grad():
            traced = torch.jit.trace(model, example)

        name = f"AntiSpoof_{model_type}"
        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="input", shape=(1, 3, SIZE, SIZE), dtype=np.float32)],
            outputs=[ct.TensorType(name="logits", dtype=np.float32)],
            minimum_deployment_target=ct.target.macOS13,
            compute_precision=ct.precision.FLOAT16,
            compute_units=ct.ComputeUnit.ALL,
        )
        mlmodel.short_description = f"MiniFASNet anti-spoof ({model_type}), crop scale {scale}"
        mlmodel.user_defined_metadata["input.layout"] = "NCHW"
        mlmodel.user_defined_metadata["input.channelOrder"] = "BGR"
        mlmodel.user_defined_metadata["input.scale"] = "1.0"  # 원 구현이 255로 나누지 않는다
        mlmodel.user_defined_metadata["input.bias"] = "0.0"
        mlmodel.user_defined_metadata["crop.scale"] = str(scale)
        mlmodel.user_defined_metadata["output.classes"] = "3 (index 1 = real)"

        dst = out_dir / f"{name}.mlpackage"
        mlmodel.save(str(dst))
        print(f"   저장: {dst.name}")

        # FP32 원본 대비 FP16 변환 손실 확인
        rng = np.random.default_rng(0)
        worst = 1.0
        for _ in range(5):
            x = rng.uniform(0, 1, (1, 3, SIZE, SIZE)).astype(np.float32)
            with torch.no_grad():
                ref = torch.softmax(traced(torch.from_numpy(x)), dim=1).numpy().ravel()
            got = np.array(mlmodel.predict({"input": x})["logits"]).ravel()
            got = np.exp(got - got.max()); got /= got.sum()
            worst = min(worst, 1 - float(np.abs(ref - got).max()))
        print(f"   softmax 최대 오차 {1 - worst:.6f}")
        if 1 - worst > 1e-3:
            sys.exit(f"실패: FP16 변환 손실이 큼 ({1 - worst:.6f})")
        meta.append((name, scale))

    print("\n앱에서 쓸 설정:")
    for name, scale in meta:
        print(f"  {name}  cropScale={scale}")

if __name__ == "__main__":
    main()
