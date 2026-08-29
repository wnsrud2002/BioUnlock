import XCTest
import CoreImage
import CoreGraphics
@testable import Unlockpalm

/// 좌표계 변환을 실제 렌더링 경로로 검증한다.
///
/// 여기서 두 좌표계가 만난다: CIImage 는 좌하단 원점, 렌더링된 비트맵은 첫 행이
/// 위쪽(CGImage 규약). 이걸 놓치면 ROI 가 위아래 뒤집힌 자리를 자르는데, 화면에는
/// 그럴듯한 손바닥 그림이 나와서 한참 못 알아챈다.
final class PalmCoordinateTests: XCTestCase {

    /// 축소 프레임 크기가 종횡비를 지켜야 한다.
    ///
    /// `locateSize * Int(width / height)` 로 썼다가 1280×720 에서 Int(1.777)=1 이
    /// 되어 160×160 이 나왔다. 284 픽셀 폭 이미지를 160 폭 버퍼에 렌더링하니
    /// 프레임 왼쪽 56% 만 보고 손 위치를 계산했다.
    func testLocateFrameKeepsAspectRatio() {
        let (w, h) = PalmCloseRange.locateFrameSize(for: CGRect(x: 0, y: 0, width: 1280, height: 720))
        XCTAssertEqual(h, PalmCloseRange.locateSize)
        XCTAssertEqual(w, 284, "종횡비 16:9 가 유지되지 않았다 (\(w)×\(h))")
    }

    /// 렌더 → locate → cropRect 를 실제로 태워, 잘라낸 사각형이 원래 손 자리를
    /// 가리키는지 본다. y 를 뒤집지 않으면 위아래가 반대로 나온다.
    func testCropRectLandsOnTheHandNotItsMirror() {
        let extent = CGRect(x: 0, y: 0, width: 320, height: 180)
        // CI 좌표(좌하단 원점) 기준 '아래쪽'에 살색 덩어리를 놓는다.
        let blobRect = CGRect(x: 110, y: 15, width: 100, height: 70)
        let background = CIImage(color: CIColor(red: 0.35, green: 0.35, blue: 0.35)).cropped(to: extent)
        let blob = CIImage(color: CIColor(red: 0.85, green: 0.60, blue: 0.50)).cropped(to: blobRect)
        let image = blob.composited(over: background)

        let (lw, lh) = PalmCloseRange.locateFrameSize(for: extent)
        let scale = CGFloat(lh) / extent.height
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        var pixels = [UInt8](repeating: 0, count: lw * lh * 4)
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        pixels.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            ctx.render(small, toBitmap: base, rowBytes: lw * 4,
                       bounds: CGRect(x: 0, y: 0, width: CGFloat(lw), height: CGFloat(lh)),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        let location = PalmCloseRange.locate(rgba: pixels, width: lw, height: lh)
        XCTAssertNotEqual(location.verdict, .noHand, "살색 덩어리를 못 찾았다")

        let crop = PalmCloseRange.cropRect(for: location, in: extent)
        // 잘라낸 사각형의 중심이 원래 덩어리 중심 근처여야 한다.
        XCTAssertEqual(crop.midX, blobRect.midX, accuracy: 12,
                       "가로 위치가 어긋났다 (crop \(crop.midX) vs blob \(blobRect.midX))")
        XCTAssertEqual(crop.midY, blobRect.midY, accuracy: 12,
                       "세로 위치가 어긋났다 — y 뒤집기를 확인할 것 (crop \(crop.midY) vs blob \(blobRect.midY))")
    }
}
