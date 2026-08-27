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
    /// DebugView의 "부호 뒤집기" 버튼으로 실행 중 바로 확정할 수 있다.
    public static var palmFacingSign: CGFloat = -1

    /// 정렬(5점)에 쓰는 관절의 최소 신뢰도. 손가락 끝은 자주 가려지지만 MCP·손목은 거의 안 가려진다.
    public static var minJointConfidence: Float = 0.7

    /// 디버그 오버레이에 표시할 전체 21점의 최소 신뢰도(정렬용 5점보다 느슨하게).
    public static var minOverlayConfidence: Float = 0.3

    /// ROI 원본 픽셀 수 하한. 이보다 작으면 손이 너무 멀어 텍스처 정보가 없다.
    public static var minSourcePixels: CGFloat = 160

    /// CompCode Gabor 응답 크기 하한 — 이보다 약하면 그 픽셀은 매칭에서 뺀다
    /// (평평한 배경, 그림자 경계 등). 커널 스케일에 종속적인 값이라 실측 전 추정치다.
    /// 처음에 50으로 뒀더니 실제 웹캠 ROI에서 거의 모든 픽셀이 걸러져 늘 비교
    /// 불가가 나왔다 — 훨씬 낮춰서 시작하고, DebugView의 +/- 버튼으로 실측 조정한다.
    public static var minGaborResponseMagnitude: Float = 10

    /// 두 코드를 비교할 때 겹쳐야 하는 최소 유효 픽셀 '개수'(전체 대비 비율 아님).
    /// 손금 선은 ROI 면적의 일부만 차지하므로 비율로 잡으면 항상 문턱을 못 넘는다.
    public static var minValidComparisonPixels: Int = 150

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

    /// 연속으로 통과해야 하는 프레임 수. 얼굴의 requiredConsecutiveFrames와 같은 역할.
    public static var requiredConsecutiveFrames: Int = 3

    /// CompCode 인코딩(9×9 커널×6방향 컨볼루션)은 무거워서 프레임마다 돌리지 않는다.
    /// 게이트를 통과한 프레임 중 이 배수째만 실제로 계산한다.
    public static var matchEveryNFrames: Int = 5
}
