#!/usr/bin/env python3
"""맥북 내장 카메라의 실제 최소 초점 거리를 찾는 진단 도구.

왜 필요한가
-----------
손금(palmprint) 인증은 손바닥 주름이 실제로 픽셀에 찍혀야 성립한다.
0.5mm 주름을 2px 이상으로 담으려면 손바닥 폭이 450px 넘게 잡혀야 하고,
그러려면 손을 카메라 코앞(대략 8~15cm)까지 가져와야 한다.

그런데 맥북 내장 카메라는 대부분 고정초점이고 50cm~무한대에 최적화돼 있다.
근접 거리에서 초점이 안 맞으면 아무리 가까이 가도 주름은 뿌옇게 뭉개지고,
알고리즘으로는 절대 못 넘는다. 이 도구는 그 한계를 숫자로 확인한다.

판정 기준
---------
거리별 라플라시안 분산(선명도)을 재서, 값이 급락하기 시작하는 지점이
이 카메라의 실용 최소 초점 거리다. 그 결과에 따라:

  8~15cm 에서 선명도 유지  → 근접 손금 인증 가능 (Bin C 까지)
  20cm 아래로 급락         → 중간 거리만 가능 (Bin A 정도)
  전 구간 낮음             → 근접 방식 자체가 불가능

주의: 라플라시안 분산은 '이미지 내용'에도 좌우된다. 거리를 바꾸면서
같은 손바닥이 ROI를 비슷하게 채우도록 유지해야 비교가 의미 있다.
그래서 화면에 ROI 사각형과 실시간 선명도를 같이 띄운다.

설치
----
    tools/.venv/bin/pip install opencv-python
    tools/.venv/bin/pip install matplotlib   # 선택(없으면 ASCII 차트)

실행
----
    tools/.venv/bin/python tools/focus_sweep.py            # 카메라 선택 화면부터
    tools/.venv/bin/python tools/focus_sweep.py --device 1 # 인덱스를 아는 경우

처음 실행하면 macOS 가 카메라 권한을 묻는다(터미널 앱에 부여된다).

!! 아이폰(Continuity Camera) 주의 !!
아이폰이 근처에 있으면 macOS 가 그걸 카메라 목록에 끼워 넣고, 종종 인덱스 0
(기본값)을 차지한다. 아이폰은 오토포커스라 접사가 잘 되므로 그걸로 재면
"근접 촬영 가능"이라는 잘못된 결론이 나온다 — 실제 앱은 맥북 내장 카메라를
쓴다(CameraController 가 .builtInWideAngleCamera 의 .front 를 고른다).
그래서 반드시 '맥북 내장 카메라'를 골라야 한다. 선택 화면에서 눈으로 확인할 것.
"""

import argparse
import csv
import os
import subprocess
import sys
from datetime import datetime

try:
    import cv2
    import numpy as np
except ImportError:
    sys.exit(
        "opencv 가 없습니다:\n"
        "    tools/.venv/bin/pip install opencv-python\n"
        "그 다음 tools/.venv/bin/python 으로 실행하세요."
    )

# 앱 본체(CameraController)와 같은 해상도로 재야 결과를 그대로 가져다 쓸 수 있다.
FRAME_W, FRAME_H = 1280, 720

# 선명도를 재는 중앙 정사각 영역. 손바닥이 이 안을 채우도록 안내한다.
# 프레임 전체로 재면 배경·얼굴이 값을 지배해 거리별 비교가 무의미해진다.
ROI_SIDE = 480

# 요청 사양: 8~30cm 를 2cm 간격.
DISTANCES_CM = list(range(8, 31, 2))

# 센서 노출·화이트밸런스가 수렴하기 전 프레임은 버린다(앱의 warmup 과 같은 이유).
WARMUP_FRAMES = 10
# 한 거리에서 여러 장 찍어 '가장 선명한 것'을 택한다. 손떨림 때문에 그 거리가
# 부당하게 낮게 평가되는 걸 막기 위해서다 — 우리가 알고 싶은 건 달성 가능한 상한이다.
BURST_FRAMES = 12

OUT_DIR = os.path.expanduser("~/Downloads/BioUnlock_FocusSweep")


def sharpness(gray):
    """라플라시안 분산. 값이 클수록 선명하다."""
    return float(cv2.Laplacian(gray, cv2.CV_64F).var())


def center_roi(frame):
    h, w = frame.shape[:2]
    y0 = (h - ROI_SIDE) // 2
    x0 = (w - ROI_SIDE) // 2
    return frame[y0:y0 + ROI_SIDE, x0:x0 + ROI_SIDE]


def system_camera_names():
    """macOS 가 인식한 카메라 이름들. cv2 인덱스와 순서가 보장되진 않아 힌트로만 쓴다."""
    try:
        out = subprocess.run(["system_profiler", "SPCameraDataType"],
                             capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    names = []
    for line in out.splitlines():
        stripped = line.strip()
        # 장치 이름은 4칸 들여쓰기 + 콜론으로 끝난다. 하위 속성은 6칸이라 걸러진다.
        if stripped.endswith(":") and len(line) - len(line.lstrip()) == 4:
            names.append(stripped[:-1])
    return names


def open_camera(index):
    cap = cv2.VideoCapture(index, cv2.CAP_AVFOUNDATION)
    if not cap.isOpened():
        return None
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, FRAME_W)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, FRAME_H)
    for _ in range(WARMUP_FRAMES):
        cap.read()
    return cap


def choose_camera(max_index=4):
    """카메라를 하나씩 보여주고 사용자가 고르게 한다.

    cv2 는 장치 이름을 주지 않으므로 인덱스로만 접근해야 한다. 아이폰이 인덱스 0을
    차지하는 경우가 흔해 자동 선택은 위험하다 — 눈으로 보고 고르는 게 유일하게
    확실한 방법이다.
    """
    names = system_camera_names()
    if names:
        print("macOS 가 인식한 카메라:", ", ".join(names))
        print("(순서가 아래 인덱스와 일치한다는 보장은 없습니다 — 화면을 보고 고르세요)\n")

    available = []
    for i in range(max_index + 1):
        cap = cv2.VideoCapture(i, cv2.CAP_AVFOUNDATION)
        if cap.isOpened():
            ok, _ = cap.read()
            if ok:
                available.append(i)
        cap.release()

    if not available:
        sys.exit(
            "카메라를 열 수 없습니다.\n"
            "시스템 설정 > 개인정보 보호와 보안 > 카메라 에서 터미널(또는 사용 중인 앱)에\n"
            "권한이 있는지 확인하세요."
        )
    if len(available) == 1:
        print(f"카메라가 하나뿐입니다 (인덱스 {available[0]}) — 그대로 사용합니다.\n")
        return available[0]

    print(f"카메라 {len(available)}개 발견: {available}")
    print("각각 미리보기를 띄웁니다. 맥북 내장 카메라가 보이면 SPACE, 아니면 N 으로 넘기세요.")
    print("!! 아이폰 화면이 보이면 그건 Continuity Camera 입니다. 반드시 N 으로 넘기세요.\n")

    for idx in available:
        cap = open_camera(idx)
        if cap is None:
            continue
        try:
            while True:
                ok, frame = cap.read()
                if not ok:
                    break
                text = f"camera index {idx}   SPACE=use this   N=next   Q=quit"
                cv2.putText(frame, text, (20, 44),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 0), 4, cv2.LINE_AA)
                cv2.putText(frame, text, (20, 44),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2, cv2.LINE_AA)
                cv2.imshow("select camera", frame)
                key = cv2.waitKey(1) & 0xFF
                if key == ord(' '):
                    cv2.destroyWindow("select camera")
                    print(f"인덱스 {idx} 선택됨\n")
                    return idx
                if key in (ord('n'), ord('N')):
                    break
                if key in (ord('q'), ord('Q'), 27):
                    cv2.destroyWindow("select camera")
                    sys.exit("선택하지 않고 종료했습니다.")
        finally:
            cap.release()

    cv2.destroyWindow("select camera")
    sys.exit("카메라를 선택하지 않았습니다. --device 로 직접 지정할 수도 있습니다.")


def draw_hud(frame, distance_cm, live_sharp, done, total):
    """미리보기에 ROI 사각형과 실시간 선명도를 겹쳐 그린다."""
    h, w = frame.shape[:2]
    y0, x0 = (h - ROI_SIDE) // 2, (w - ROI_SIDE) // 2
    cv2.rectangle(frame, (x0, y0), (x0 + ROI_SIDE, y0 + ROI_SIDE), (0, 255, 0), 2)

    lines = [
        f"target: {distance_cm} cm   ({done}/{total} captured)",
        f"sharpness: {live_sharp:8.1f}",
        "SPACE=capture   S=skip   Q=quit",
    ]
    for i, text in enumerate(lines):
        cv2.putText(frame, text, (20, 40 + i * 34),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 0), 4, cv2.LINE_AA)
        cv2.putText(frame, text, (20, 40 + i * 34),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 0), 2, cv2.LINE_AA)
    return frame


def capture_at(cap, distance_cm, done, total):
    """한 거리에서 사용자가 SPACE 를 누를 때까지 미리보기를 돌린다.

    Returns: (sharpness, roi_image) 또는 None(건너뜀), 'quit'(중단)
    """
    while True:
        ok, frame = cap.read()
        if not ok:
            return None

        roi = center_roi(frame)
        gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
        live = sharpness(gray)

        cv2.imshow("focus sweep", draw_hud(frame.copy(), distance_cm, live, done, total))
        key = cv2.waitKey(1) & 0xFF

        if key == ord(' '):
            best_val, best_roi = -1.0, None
            for _ in range(BURST_FRAMES):
                ok, f = cap.read()
                if not ok:
                    continue
                r = center_roi(f)
                v = sharpness(cv2.cvtColor(r, cv2.COLOR_BGR2GRAY))
                if v > best_val:
                    best_val, best_roi = v, r
            if best_roi is None:
                return None
            return best_val, best_roi
        if key in (ord('s'), ord('S')):
            return None
        if key in (ord('q'), ord('Q'), 27):
            return 'quit'


def ascii_plot(rows):
    """matplotlib 없이도 결과를 바로 읽을 수 있게 터미널에 막대로 그린다."""
    if not rows:
        return
    peak = max(v for _, v in rows)
    width = 48
    print("\n거리별 선명도 (라플라시안 분산)")
    print("-" * 68)
    for cm, val in rows:
        bar = "#" * max(1, int(round(val / peak * width))) if peak > 0 else ""
        marker = "  <- 최고" if val == peak else ""
        print(f"{cm:3d} cm | {val:9.1f} | {bar}{marker}")
    print("-" * 68)


def save_plot(rows, path):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("(matplotlib 없음 — PNG 플롯은 건너뜁니다. 위 ASCII 차트로 판단하세요)")
        return None

    xs = [cm for cm, _ in rows]
    ys = [v for _, v in rows]
    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.plot(xs, ys, marker="o")
    ax.set_xlabel("distance (cm)")
    ax.set_ylabel("Laplacian variance (sharpness)")
    ax.set_title("MacBook camera focus sweep")
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(path, dpi=140)
    plt.close(fig)
    return path


def verdict(rows):
    """근접 손금 인증이 가능한 거리인지 판정한다.

    절대값의 의미는 카메라·조명마다 달라 비교가 어렵다. 그래서 '최고 선명도
    대비 몇 %인가'로 본다 — 초점이 맞는 구간은 평평하고, 벗어나면 급락한다.
    """
    if not rows:
        return "측정값이 없습니다."

    peak = max(v for _, v in rows)
    if peak <= 0:
        return "선명도가 전부 0입니다 — 카메라 출력이 정상인지 확인하세요."

    # 최고치의 60% 이상이면 '실용적으로 초점이 맞는' 구간으로 본다.
    usable = [cm for cm, v in rows if v >= peak * 0.6]
    if not usable:
        return "판정 불가 — 측정 구간이 너무 좁습니다."

    near = min(usable)
    lines = [f"최고 선명도 {peak:.0f} @ {[cm for cm, v in rows if v == peak][0]}cm",
             f"실용 초점 구간(최고의 60% 이상): {near}~{max(usable)}cm",
             f"실용 최소 초점 거리: 약 {near}cm", ""]

    if near <= 15:
        lines.append("판정: 근접 손금 인증 가능. Bin C(가장 가까운 구간)까지 시도할 수 있습니다.")
    elif near <= 22:
        lines.append("판정: 중간 거리까지만 가능. Bin A~B 위주로 설계를 축소해야 합니다.")
    else:
        lines.append("판정: 근접 촬영 불가. 이 카메라로는 손금이 해상되지 않습니다 —")
        lines.append("      외장 웹캠(접사 가능)이나 다른 인증 방식을 검토해야 합니다.")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="맥북 카메라 초점 스윕 진단")
    parser.add_argument("--device", type=int, default=None,
                        help="카메라 인덱스를 직접 지정(생략하면 선택 화면)")
    args = parser.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    session_dir = os.path.join(OUT_DIR, stamp)
    os.makedirs(session_dir, exist_ok=True)

    print(__doc__.split("설치")[0].strip())
    print()

    device = args.device if args.device is not None else choose_camera()

    print("손바닥을 초록 사각형 안을 채우도록 두고, 표시된 거리에서 SPACE 를 누르세요.")
    print("측정을 건너뛰려면 S, 중단하려면 Q.\n")

    cap = open_camera(device)
    if cap is None:
        sys.exit(f"인덱스 {device} 카메라를 열 수 없습니다.")
    rows = []
    try:
        for i, cm in enumerate(DISTANCES_CM):
            result = capture_at(cap, cm, len(rows), len(DISTANCES_CM))
            if result == 'quit':
                print("중단했습니다.")
                break
            if result is None:
                print(f"{cm:3d} cm  건너뜀")
                continue
            val, roi = result
            rows.append((cm, val))
            img_path = os.path.join(session_dir, f"{cm:02d}cm.png")
            cv2.imwrite(img_path, roi)
            print(f"{cm:3d} cm  선명도 {val:9.1f}   → {os.path.basename(img_path)}")
    finally:
        cap.release()
        cv2.destroyAllWindows()

    if not rows:
        print("\n측정된 값이 없습니다.")
        return

    csv_path = os.path.join(session_dir, "sharpness.csv")
    with open(csv_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["distance_cm", "laplacian_variance"])
        w.writerows(rows)

    ascii_plot(rows)
    png_path = save_plot(rows, os.path.join(session_dir, "sharpness.png"))

    print("\n" + verdict(rows))
    print(f"\n저장 위치: {session_dir}")
    print("  - 거리별 ROI 이미지(직접 눈으로 손금이 보이는지 확인하세요)")
    print(f"  - {os.path.basename(csv_path)}")
    if png_path:
        print(f"  - {os.path.basename(png_path)}")
    print("\n숫자보다 이미지가 결정적입니다. 가장 선명한 거리의 PNG 를 열어")
    print("손금 선이 실제로 보이는지 확인하세요 — 안 보이면 그 거리도 쓸 수 없습니다.")


if __name__ == "__main__":
    main()
