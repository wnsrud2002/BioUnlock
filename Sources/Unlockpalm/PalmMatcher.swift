//
//  PalmMatcher.swift
//  Unlockpalm
//
//  CompCode(Kong & Zhang, 2004): 6방향(0°,30°,…,150°) Gabor 실수부 뱅크를 ROI에
//  돌리고, 픽셀마다 '응답이 최소인 방향'의 인덱스를 코드로 삼는다. 손금은 주변보다
//  어두우므로 선 방향과 나란한 필터에서 응답이 최소가 된다.
//
//  argmin만 쓰기 때문에 밝기·대비 변화에 원래 불변이다 — 조명 강인성을 전처리가
//  아니라 표현 자체가 갖는다. 얼굴의 딥러닝 임베딩과 달리 학습 가중치가 없다
//  (unlockpalm-plan.txt §1.4 — 손바닥엔 라이선스 문제없는 사전학습 모델이 없다).
//
//  커널 파라미터(반경·시그마·파장)는 출발점 추정치다. 실제 ROI 이미지로
//  라인이 또렷하게 갈라지는지 보고 재조정할 것.
//
//  주의: 코드 하나 계산에 128×128×6방향×커널 컨볼루션이 들어간다(수백만 곱셈).
//  비디오 프레임마다 돌리지 말고, 등록·수동 비교처럼 필요할 때만 부를 것.
//

import Foundation

/// 손바닥 하나의 방향 코드. bits[i]는 0...5(30° 단위), mask[i]는 응답이 충분히
/// 강해 신뢰할 수 있는 픽셀인지.
public struct PalmCode: Equatable, Codable {
    let bits: [UInt8]
    let mask: [Bool]
    let size: Int

    /// 진단용 — mask가 true인 픽셀 비율. 이게 너무 낮으면
    /// PalmConfig.minGaborResponseMagnitude가 실제 이미지에 비해 너무 빡빡한 것이다.
    public var validRatio: Float {
        guard !mask.isEmpty else { return 0 }
        return Float(mask.filter { $0 }.count) / Float(mask.count)
    }
}

public enum PalmMatcher {

    // MARK: - Gabor 뱅크

    private static let kernelRadius = 4              // 9×9
    private static let sigma: Double = 2.0
    private static let wavelength: Double = 6.0
    /// 1보다 작을수록 선 방향으로 길쭉해진다(능선을 따라 적분, 가로질러 진동).
    private static let aspectRatio: Double = 0.5
    private static let orientationCount = 6

    /// [방향][커널 내 오프셋]. 앱 생애 동안 한 번만 만든다.
    private static let kernels: [[Float]] = (0..<orientationCount).map(makeKernel)

    private static func makeKernel(orientationIndex: Int) -> [Float] {
        let theta = Double(orientationIndex) * .pi / Double(orientationCount)
        var kernel = [Float]()
        kernel.reserveCapacity((2 * kernelRadius + 1) * (2 * kernelRadius + 1))
        for y in -kernelRadius...kernelRadius {
            for x in -kernelRadius...kernelRadius {
                let xf = Double(x), yf = Double(y)
                let xr = xf * cos(theta) + yf * sin(theta)
                let yr = -xf * sin(theta) + yf * cos(theta)
                let envelope = exp(-(xr * xr + aspectRatio * aspectRatio * yr * yr) / (2 * sigma * sigma))
                let carrier = cos(2 * .pi * xr / wavelength)
                kernel.append(Float(envelope * carrier))
            }
        }
        // DC 성분을 빼서 균일한 배경(테두리 등)에서 응답이 0 근처가 되게 한다.
        let mean = kernel.reduce(0, +) / Float(kernel.count)
        return kernel.map { $0 - mean }
    }

    // MARK: - 인코딩

    /// 정렬된 ROI의 루마(FacePreprocessor.luma와 같은 포맷, size*size)에서 코드를 뽑는다.
    public static func encode(luma: [Float], size: Int) -> PalmCode? {
        guard luma.count >= size * size, size > 2 * kernelRadius else { return nil }

        var bits = [UInt8](repeating: 0, count: size * size)
        var mask = [Bool](repeating: false, count: size * size)
        let r = kernelRadius

        luma.withUnsafeBufferPointer { lumaBuf in
            for y in 0..<size {
                for x in 0..<size {
                    var bestOrientation = 0
                    var bestResponse: Float = .greatestFiniteMagnitude
                    var bestMagnitude: Float = 0

                    for (orientation, kernel) in kernels.enumerated() {
                        var sum: Float = 0
                        var kidx = 0
                        for dy in -r...r {
                            let sy = min(max(y + dy, 0), size - 1)   // 가장자리는 복제(clamp)
                            let rowBase = sy * size
                            for dx in -r...r {
                                let sx = min(max(x + dx, 0), size - 1)
                                sum += lumaBuf[rowBase + sx] * kernel[kidx]
                                kidx += 1
                            }
                        }
                        if sum < bestResponse { bestResponse = sum; bestOrientation = orientation }
                        bestMagnitude = max(bestMagnitude, abs(sum))
                    }
                    let i = y * size + x
                    bits[i] = UInt8(bestOrientation)
                    mask[i] = bestMagnitude >= PalmConfig.minGaborResponseMagnitude
                }
            }
        }
        return PalmCode(bits: bits, mask: mask, size: size)
    }

    // MARK: - 매칭

    /// 정규화 해밍 유사도(1에 가까울수록 같은 손). 정렬 오차 흡수를 위해 ±3px 이동 탐색.
    ///
    /// nil은 "다른 손"이 아니라 "비교할 픽셀이 부족해서 판단 불가"다 — 0점과
    /// 절대 혼동하면 안 된다. mask 게이트(minGaborResponseMagnitude)가 실제
    /// 이미지에 비해 너무 빡빡하면 항상 nil이 나온다(PalmCode.validRatio로 확인).
    public static func score(_ a: PalmCode, _ b: PalmCode) -> Float? {
        guard a.size == b.size else { return nil }
        var best: Float?
        for dy in -3...3 {
            for dx in -3...3 {
                if let d = normalizedHammingDistance(a, b, dx: dx, dy: dy) {
                    best = min(best ?? d, d)
                }
            }
        }
        return best.map { 1 - $0 }
    }

    private static func normalizedHammingDistance(_ a: PalmCode, _ b: PalmCode, dx: Int, dy: Int) -> Float? {
        let size = a.size
        var total: Float = 0
        var validCount = 0
        for y in 0..<size {
            let by = y + dy
            guard by >= 0, by < size else { continue }
            let rowA = y * size
            let rowB = by * size
            for x in 0..<size {
                let bx = x + dx
                guard bx >= 0, bx < size else { continue }
                let ai = rowA + x, bi = rowB + bx
                guard a.mask[ai], b.mask[bi] else { continue }
                total += angularDiff(a.bits[ai], b.bits[bi])
                validCount += 1
            }
        }
        // 유효 픽셀이 너무 적으면(정렬이 완전히 어긋났거나 손이 잘림) 이 이동량은 신뢰하지 않는다.
        // 손금 선은 원래 ROI 면적의 일부만 차지하므로 전체 대비 비율이 아니라
        // 절대 개수로 본다 — 비율 기준(예: 25%)은 애초에 못 채우는 문턱이었다.
        guard validCount >= PalmConfig.minValidComparisonPixels else { return nil }
        return total / Float(validCount)
    }

    /// 방향 인덱스는 원형이다(0과 5는 30° 차이지 150° 차이가 아니다).
    /// 단순 뺄셈만 쓰면 이 wrap-around를 놓쳐 조용히 성능이 깎인다.
    /// internal(=모듈 내부)로 둬 테스트에서 직접 확인한다.
    static func angularDiff(_ x: UInt8, _ y: UInt8) -> Float {
        let d = abs(Int(x) - Int(y))
        return Float(min(d, orientationCount - d)) / Float(orientationCount / 2)
    }
}
