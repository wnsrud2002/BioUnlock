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

    /// 손바닥 인증 임계값. 얼굴의 unlockIdentityThreshold와 같은 역할 —
    /// 타인 데이터셋 채점 전까지는 순전히 추정치다(로드맵 08번에서 확정).
    public static var matchThreshold: Float = 0.65
}
