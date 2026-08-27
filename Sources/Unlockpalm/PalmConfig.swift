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
}
