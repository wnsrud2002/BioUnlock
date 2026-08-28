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
import Accelerate

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

    /// 정합 오차를 흡수하는 이동 탐색 반경(픽셀). ROI 가 256px 이므로 3px 은
    /// 예전 128px 시절의 1.5px 에 해당한다. 정준 좌표 재추정 이후 정렬 잔차가
    /// 1px 수준이라 이 정도로 충분하다 — 반경을 키우면 비용이 제곱으로 는다.
    private static let shiftSearch = 3

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

    /// 정렬된 ROI(RGBA8)에서 코드를 뽑는다. 전처리(루마 변환 + CLAHE)를 안에서
    /// 하는 이유는 등록과 인증이 서로 다른 전처리를 타는 사고를 원천 차단하기
    /// 위해서다 — 루마를 받는 진입점은 일부러 노출하지 않는다.
    public static func encode(rgba: [UInt8], size: Int) -> PalmCode? {
        guard rgba.count >= size * size * 4 else { return nil }
        var luma = PalmPreprocessor.luma(from: rgba, count: size * size)
        PalmPreprocessor.applyCLAHE(luma: &luma, size: size)
        return encode(luma: luma, size: size)
    }

    /// 9×9 커널 한 장을 평면 이미지 전체에 적용한다.
    ///
    /// 직접 4중 루프로 짰더니 256×256 인코딩에 4.7초가 걸렸다(방향 6개 × 81탭 ×
    /// 65536픽셀을 경계검사와 함께 도는 비용). vImage 는 같은 일을 벡터화해서 한다.
    /// kvImageEdgeExtend 는 가장자리 픽셀을 복제하므로 기존 clamp 동작과 같다.
    private static func convolve(_ src: [Float], size: Int, kernel: [Float]) -> [Float] {
        var input = src
        var output = [Float](repeating: 0, count: size * size)
        let side = UInt32(2 * kernelRadius + 1)
        let rowBytes = size * MemoryLayout<Float>.size

        input.withUnsafeMutableBufferPointer { ip in
            output.withUnsafeMutableBufferPointer { op in
                var srcBuf = vImage_Buffer(data: ip.baseAddress,
                                           height: vImagePixelCount(size),
                                           width: vImagePixelCount(size),
                                           rowBytes: rowBytes)
                var dstBuf = vImage_Buffer(data: op.baseAddress,
                                           height: vImagePixelCount(size),
                                           width: vImagePixelCount(size),
                                           rowBytes: rowBytes)
                _ = vImageConvolve_PlanarF(&srcBuf, &dstBuf, nil, 0, 0,
                                           kernel, side, side, 0,
                                           vImage_Flags(kvImageEdgeExtend))
            }
        }
        return output
    }

    /// 루마 평면에서 직접 인코딩한다. 전처리를 이미 마친 데이터거나 합성
    /// 테스트 패턴일 때만 쓴다(그래서 internal).
    static func encode(luma: [Float], size: Int) -> PalmCode? {
        guard luma.count >= size * size, size > 2 * kernelRadius else { return nil }
        let n = size * size

        var bits = [UInt8](repeating: 0, count: n)
        var minResponse = [Float](repeating: .greatestFiniteMagnitude, count: n)
        var maxResponse = [Float](repeating: -.greatestFiniteMagnitude, count: n)

        // 방향별로 한 번씩 컨볼루션하고, 픽셀마다 최소/최대를 갱신한다.
        for (orientation, kernel) in kernels.enumerated() {
            let response = Array(luma[0..<n])
            let resp = convolve(response, size: size, kernel: kernel)
            resp.withUnsafeBufferPointer { rp in
                minResponse.withUnsafeMutableBufferPointer { mn in
                    maxResponse.withUnsafeMutableBufferPointer { mx in
                        bits.withUnsafeMutableBufferPointer { bt in
                            for i in 0..<n {
                                let v = rp[i]
                                if v < mn[i] { mn[i] = v; bt[i] = UInt8(orientation) }
                                if v > mx[i] { mx[i] = v }
                            }
                        }
                    }
                }
            }
        }

        // 마스크 기준은 응답의 '크기'가 아니라 방향별 응답의 '진폭'이다.
        //
        // 크기로 거르면 밝기·대비에 따라 통과 여부가 바뀐다 — 평평한 피부도
        // 밝으면 통과해서 방향이 사실상 난수인 픽셀이 코드에 섞였다.
        // 진폭(최대-최소)은 "여기서 방향이 의미가 있는가"를 직접 재는 값이라,
        // 주름이 없는 곳은 대비와 무관하게 걸러진다.
        let threshold = PalmConfig.minOrientationSalience
        var mask = [Bool](repeating: false, count: n)
        for i in 0..<n { mask[i] = (maxResponse[i] - minResponse[i]) >= threshold }

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

        // 겹침 하한을 '두 코드 중 유효 픽셀이 적은 쪽'에 비례시킨다.
        // 절대 개수(150 = 전체의 0.9%)로 두었더니, 49개 이동 중 겹침이 거의 없는
        // 이동이 요행으로 최고점을 먹어 같은 손·다른 손 점수를 함께 부풀렸다.
        //
        // 이 계산은 이동량과 무관하므로 루프 밖에서 한 번만 한다 — 안에 두었더니
        // 49번 × 두 코드 전체 스캔이 반복돼 매칭 비용의 상당 부분을 먹고 있었다.
        let aValid = a.mask.reduce(into: 0) { if $1 { $0 += 1 } }
        let bValid = b.mask.reduce(into: 0) { if $1 { $0 += 1 } }
        let required = max(PalmConfig.minValidComparisonPixels,
                           Int(Float(min(aValid, bValid)) * PalmConfig.minValidOverlapRatio))

        var best: Float?
        a.bits.withUnsafeBufferPointer { ab in
            a.mask.withUnsafeBufferPointer { am in
                b.bits.withUnsafeBufferPointer { bb in
                    b.mask.withUnsafeBufferPointer { bm in
                        for dy in -shiftSearch...shiftSearch {
                            for dx in -shiftSearch...shiftSearch {
                                if let d = distance(ab, am, bb, bm, size: a.size,
                                                    dx: dx, dy: dy, required: required) {
                                    best = min(best ?? d, d)
                                }
                            }
                        }
                    }
                }
            }
        }
        return best.map { 1 - $0 }
    }

    private static func distance(_ aBits: UnsafeBufferPointer<UInt8>,
                                 _ aMask: UnsafeBufferPointer<Bool>,
                                 _ bBits: UnsafeBufferPointer<UInt8>,
                                 _ bMask: UnsafeBufferPointer<Bool>,
                                 size: Int, dx: Int, dy: Int, required: Int) -> Float? {
        var total: Float = 0
        var validCount = 0
        // 겹치는 구간만 돈다 — 매 픽셀에서 경계를 검사하지 않는다.
        let yStart = max(0, -dy), yEnd = min(size, size - dy)
        let xStart = max(0, -dx), xEnd = min(size, size - dx)
        guard yStart < yEnd, xStart < xEnd else { return nil }

        for y in yStart..<yEnd {
            let rowA = y * size
            let rowB = (y + dy) * size
            for x in xStart..<xEnd {
                let ai = rowA + x
                let bi = rowB + x + dx
                if aMask[ai] && bMask[bi] {
                    total += angularDiff(aBits[ai], bBits[bi])
                    validCount += 1
                }
            }
        }
        // 겹침이 부족한 이동은 채점에 쓰지 않는다(정렬이 어긋났거나 손이 잘린 경우).
        guard validCount >= required else { return nil }
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
