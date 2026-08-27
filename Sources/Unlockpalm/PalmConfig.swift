//
//  PalmConfig.swift
//  Unlockpalm
//
//  튜닝 파라미터. FaceIDConfig와 같은 원칙 — 전부 여기에만 둔다.
//  전부 출발점 추정치다. unlockpalm-plan.txt "미확정 항목" 참고, 실측으로 교체할 것.
//

import Foundation
import CoreGraphics

public enum PalmConfig {

    /// 손바닥/손등 판별 외적 부호. 전면 카메라 미러링 여부에 따라 뒤집힌다.
    /// 설정 → 손바닥 탭(또는 디버그 창)의 "부호 뒤집기" 버튼으로 확정한다.
    ///
    /// UserDefaults에 저장한다 — 원래 그냥 static var였는데, 앱을 재시작할 때마다
    /// 기본값(-1)으로 돌아가 버려서 "방금 맞춰놨는데 또 안 됨"의 원인이 됐다.
    public static var palmFacingSign: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: Keys.palmFacingSign)
            return stored == 0 ? -1 : CGFloat(stored)
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: Keys.palmFacingSign) }
    }

    private enum Keys {
        static let palmFacingSign = "palmFacingSign"
    }

    /// 정렬(5점)에 쓰는 관절의 최소 신뢰도. 손가락 끝은 자주 가려지지만 MCP·손목은 거의 안 가려진다.
    public static var minJointConfidence: Float = 0.7

    /// 디버그 오버레이에 표시할 전체 21점의 최소 신뢰도(정렬용 5점보다 느슨하게).
    public static var minOverlayConfidence: Float = 0.3

    /// ROI 원본 픽셀 수 하한. 이보다 작으면 손이 너무 멀어 텍스처 정보가 없다.
    public static var minSourcePixels: CGFloat = 160

    /// 정렬 잔차(픽셀) 상한. 5점이 유사변환으로 설명되지 않을수록 커진다 —
    /// 크면 ROI가 엉뚱한 데를 잘라서 CompCode가 통째로 쓰레기가 된다.
    ///
    /// 원래 diagnostics()로 계산만 하고 실제 매칭 경로에서는 전혀 안 쓰고 있었다.
    /// 정렬이 틀어진 프레임의 코드가 그대로 채점에 들어가 점수가 0.57까지 떨어지던
    /// 원인 중 하나(2026-08-28 실측). 얼굴의 alignmentResidualMax(6.0)와 같은 역할.
    public static var maxAlignmentResidual: CGFloat = 6.0

    /// 등록 시 모을 샘플 수. 참조가 한 장뿐이면 등록 당시 각도에서 조금만 벗어나도
    /// 점수가 무너진다(얼굴이 포즈 버킷별로 여러 장 모으는 것과 같은 이유).
    public static var enrollmentSampleCount: Int = 5

    /// 등록 샘플 사이 최소 간격(초). 없으면 30fps에서 거의 같은 프레임 N장을 모으게 되어
    /// 다중 샘플의 의미가 사라진다(얼굴 minSampleInterval과 같은 논리).
    public static var enrollmentSampleInterval: TimeInterval = 0.4

    /// 방향 진폭(방향별 Gabor 응답의 최대-최소) 하한. 이보다 평평하면 그 픽셀은
    /// "방향이 의미 없는 곳"으로 보고 매칭에서 뺀다.
    ///
    /// 원래는 응답의 절대 크기로 걸렀는데, 그건 대비에 따라 통과 여부가 바뀌어
    /// 평평한 피부까지 통과시켰다(방향이 난수인 픽셀이 코드에 섞임). 진폭 기준은
    /// 밝기·대비 변화에 훨씬 둔감하다. CLAHE를 앞단에 넣으면서 응답 분포가
    /// 통째로 올라가므로 값도 같이 올렸다 — DebugView의 +/- 버튼으로 실측 조정한다.
    public static var minOrientationSalience: Float = 60

    /// 두 코드를 비교할 때 겹쳐야 하는 유효 픽셀의 최소 개수(하한선).
    public static var minValidComparisonPixels: Int = 500

    /// 겹침 요구치를 '두 코드 중 유효 픽셀이 적은 쪽'의 몇 배로 볼지.
    /// 고정 개수만 쓰면 유효 픽셀이 많은 코드에서도 희박한 겹침이 통과해,
    /// 49개 이동 중 요행으로 최고점을 먹는 이동이 생긴다.
    public static var minValidOverlapRatio: Float = 0.35

    /// 손바닥 ROI(128px)용 CLAHE 격자·클립 한계. 128은 8로 나누어떨어진다.
    /// 얼굴(2.0)보다 세게 잡는다 — 손금 주름 대비를 최대한 끌어올려야 하고,
    /// 색 보존 제약이 없어 부작용이 적다.
    public static var claheTiles: Int = 8
    public static var claheClipLimit: Float = 4.0

    /// 손바닥 인증 임계값. 얼굴의 unlockIdentityThreshold와 같은 역할.
    ///
    /// 실측 1차(2026-08-27, 본인 양손, gaborThreshold=10):
    ///   같은 손 5회 → 0.7378, 0.7487, 0.7551, 0.7665, 0.8008 (최저 0.7378)
    ///   다른 손 5회 → 0.6645, 0.6702, 0.6815, 0.6860, 0.7166 (최고 0.7166)
    ///   분리 여유 0.021 → 중간값 0.73으로 잡았다.
    ///
    /// 경고: 표본이 "본인의 양손, 5회씩"뿐이다 — 진짜 타인(다른 사람) 데이터가
    /// 하나도 없다. 다른 사람 손이 이 범위 안에 들어올 가능성을 전혀 배제 못
    /// 한다. 로드맵 08번(타인 데이터셋 채점)을 거치기 전까지는 "완전히 안 맞던
    /// 걸 최소한 동작은 하게" 수준이지 보안 임계값이 아니다.
    public static var matchThreshold: Float = 0.73

    /// 연속으로 통과해야 하는 프레임 수. 얼굴의 requiredConsecutiveFrames와 같은 역할이지만
    /// 얼굴처럼 3으로 두면 안 된다 — 얼굴은 임계값 여유가 커서(타인 최고 0.37 vs 본인
    /// 최저 0.71) 연속 3번이 쉽지만, 손바닥은 여유가 0.02뿐이라 실측(2026-08-28) 결과
    /// 같은 손을 들고 있어도 점수가 0.67~0.84로 계속 출렁였다(10번 중 4번만 통과, p≈0.4).
    /// 연속 3번 요구 시 성공 확률 0.4³≈6%라 사실상 안 풀렸다. 2로 낮추면 0.4²≈16%.
    public static var requiredConsecutiveFrames: Int = 2

    /// CompCode 인코딩(9×9 커널×6방향 컨볼루션)은 무거워서 프레임마다 돌리지 않는다.
    /// 게이트를 통과한 프레임 중 이 배수째만 실제로 계산한다.
    /// 5는 점수가 잘 안 넘는(위 requiredConsecutiveFrames 참고) 상황과 겹치면
    /// 체감 대기시간이 길어져서 3으로 낮췄다 — 초당 시도 횟수를 늘려 확률을 채운다.
    public static var matchEveryNFrames: Int = 3
}
