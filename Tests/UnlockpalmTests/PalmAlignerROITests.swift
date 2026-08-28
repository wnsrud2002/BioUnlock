import XCTest
import CoreImage
import CoreGraphics
@testable import Unlockpalm

/// align() 이 돌려주는 이미지의 좌표 계약을 잠근다.
///
/// 이게 왜 필요한가: 예전에는 roiInCanonical(원점 32,32)로 크롭해 놓고
/// 호출부(CameraController)는 (0,0)부터 렌더링했다. 32px 어긋난 영역을 읽어
/// 가장자리에 빈 띠가 생기고 ROI 가 손바닥 중심에서 밀려 있었다. 얼굴 쪽은
/// 크롭도 렌더도 원점 0이라 문제가 없어서 대조하다 발견했다.
final class PalmAlignerROITests: XCTestCase {

    private func solidImage(side: CGFloat) -> CIImage {
        CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    private var squarePoints: PalmPoints {
        // 이미지 정중앙 근처에 적당히 벌어진 5점. 실제 값은 중요하지 않다 —
        // 확인하려는 건 출력 이미지의 좌표계이지 정렬 정확도가 아니다.
        PalmPoints(indexMCP: CGPoint(x: 0.60, y: 0.62),
                   middleMCP: CGPoint(x: 0.52, y: 0.66),
                   ringMCP: CGPoint(x: 0.44, y: 0.63),
                   littleMCP: CGPoint(x: 0.36, y: 0.57),
                   wrist: CGPoint(x: 0.50, y: 0.20))
    }

    /// 출력 이미지의 extent 는 항상 (0, 0, outputSize, outputSize) 여야 한다.
    /// 호출부가 그 가정으로 비트맵을 렌더링하기 때문이다.
    func testAlignedExtentStartsAtOriginAndMatchesOutputSize() {
        let image = solidImage(side: 1000)
        guard let aligned = PalmAligner.align(image: image, points: squarePoints,
                                              flipLeftHand: false,
                                              canonical: PalmAligner.defaultCanonical192) else {
            return XCTFail("정상 입력에서는 정렬 결과가 나와야 한다")
        }
        let side = CGFloat(PalmAligner.roiOutputSize)
        XCTAssertEqual(aligned.extent.origin.x, 0, accuracy: 0.01)
        XCTAssertEqual(aligned.extent.origin.y, 0, accuracy: 0.01)
        XCTAssertEqual(aligned.extent.width, side, accuracy: 0.01)
        XCTAssertEqual(aligned.extent.height, side, accuracy: 0.01)
    }

    /// ROI 안이 실제 이미지 내용으로 꽉 차 있어야 한다(빈 띠가 없어야 한다).
    /// 흰 이미지를 넣었으니 렌더 결과도 전부 흰색이어야 한다 — 좌표가 어긋나면
    /// 크롭 범위 밖이 투명(검정)으로 찍혀 평균이 확 떨어진다.
    func testRenderedROIHasNoEmptyBand() {
        let image = solidImage(side: 1000)
        guard let aligned = PalmAligner.align(image: image, points: squarePoints,
                                              flipLeftHand: false,
                                              canonical: PalmAligner.defaultCanonical192) else {
            return XCTFail("정렬 결과가 나와야 한다")
        }
        let size = PalmAligner.roiOutputSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        pixels.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            ctx.render(aligned, toBitmap: base, rowBytes: size * 4,
                       bounds: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        // 알파가 0인 픽셀 = 크롭 범위 밖을 읽은 것.
        let transparent = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] < 250 }.count
        XCTAssertEqual(transparent, 0, "ROI 안에 빈 픽셀이 \(transparent)개 있다 — 좌표계가 어긋났다")
    }
}
