//
//  AntiSpoofDetector.swift
//  BioUnlock
//
//  사진·화면 재생 공격 탐지 (MiniFASNet 앙상블).
//
//  두 모델이 서로 다른 배율로 얼굴 주변을 본다:
//    MiniFASNetV2   scale 2.7 — 얼굴 + 가까운 주변
//    MiniFASNetV1SE scale 4.0 — 더 넓은 맥락(폰 테두리, 손, 종이 가장자리)
//  실물 판정의 근거는 얼굴 자체가 아니라 '주변에 무엇이 보이는가'다.
//  그래서 정렬된 112x112 얼굴이 아니라 원본 프레임에서 다시 잘라야 한다.
//
//  입력 규약 (원 저장소 코드를 그대로 따라야 한다):
//    BGR / [0,255] 원본값 / NCHW / 80x80
//
//  주의 — 두 군데가 문서와 다르다:
//    * cv2.imread 결과를 채널 변환 없이 먹이므로 RGB 가 아니라 BGR.
//    * src/data_io/functional.py 의 to_tensor 는 `img.float().div(255)` 가
//      주석 처리돼 있고 `img.float()` 를 반환한다. 클래스 docstring 에는
//      "[0,255] → [0.0,1.0]" 이라 쓰여 있지만 실제로는 나누지 않는다.
//      [0,1] 로 넣으면 어떤 입력이든 항상 같은 클래스가 나온다(실측 확인).
//

import Foundation
import CoreML
import CoreImage
import Accelerate
import AppKit
import UnlockKit

struct AntiSpoofResult: Equatable {
    /// 이 프레임의 실물 점수 = 두 모델의 '최소값'.
    ///
    /// 평균을 쓰면 한 모델이 다른 모델을 덮어쓴다. 실측에서 두 모델이
    /// [0.017, 0.959] 처럼 정반대로 갈린 프레임이 평균 0.488 로 통과했다.
    /// 보안 게이트에서는 둘 다 확신할 때만 통과시켜야 한다.
    let realScore: Float
    /// 최근 창의 '최소값'. 판정은 이걸로 한다.
    ///
    /// 이동평균은 최근 5프레임 중 2장만 실물이면 나머지가 0.00 이어도
    /// (0.99×2)/5 = 0.396 으로 통과시킨다. 실제로 사진 공격이 이 경로로
    /// 뚫렸다(raw 0.0117 인데 평균 0.4702 로 통과). 최소값은 한 프레임만
    /// 위조여도 창 전체를 막는다.
    let smoothScore: Float
    let isReal: Bool
    /// 모델별 실물 확률. 어느 배율이 판단을 좌우했는지 본다.
    let perModel: [Float]
}

final class AntiSpoofDetector {
    static let shared = AntiSpoofDetector()

    private struct Member {
        let model: MLModel
        let cropScale: CGFloat
        let name: String
    }

    private let lock = NSLock()
    private var members: [Member] = []
    private var loadFailed = false
    private var input: MLMultiArray?
    private var pixels = [UInt8](repeating: 0, count: 80 * 80 * 4)
    private var dumpCount = 0
    private var frameDumpCount = 0

    private let size = 80
    private let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])

    private init() {}

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return !members.isEmpty }

    func unload() {
        lock.lock(); defer { lock.unlock() }
        members.removeAll()
        input = nil
    }

    private func loadIfNeeded() -> [Member] {
        if !members.isEmpty { return members }
        guard !loadFailed else { return [] }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        // 이름과 배율은 변환 스크립트가 정한 것과 짝이 맞아야 한다.
        let spec: [(String, CGFloat)] = [("AntiSpoof_MiniFASNetV2", 2.7),
                                         ("AntiSpoof_MiniFASNetV1SE", 4.0)]
        var loaded: [Member] = []
        for (name, scale) in spec {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc"),
                  let model = try? MLModel(contentsOf: url, configuration: config) else {
                DiagnosticLog.write("antispoof 로드 실패: \(name)")
                continue
            }
            loaded.append(Member(model: model, cropScale: scale, name: name))
        }
        guard !loaded.isEmpty else { loadFailed = true; return [] }
        members = loaded
        DiagnosticLog.write("antispoof 모델 \(loaded.count)개 로드")
        return members
    }

    /// - Parameters:
    ///   - image: 원본 프레임
    ///   - faceBox: Vision 정규화 bbox (원점 좌하단)
    func evaluate(image: CIImage, faceBox: CGRect, smoothed: Float?) -> AntiSpoofResult? {
        lock.lock()
        defer { lock.unlock() }

        let members = loadIfNeeded()
        guard !members.isEmpty else { return nil }

        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let boxPx = CGRect(x: extent.origin.x + faceBox.origin.x * extent.width,
                           y: extent.origin.y + faceBox.origin.y * extent.height,
                           width: faceBox.width * extent.width,
                           height: faceBox.height * extent.height)

        if FaceIDConfig.dumpAntiSpoofCrops, frameDumpCount < 3 {
            frameDumpCount += 1
            dumpFrame(image: image, faceBox: faceBox, tag: "frame\(frameDumpCount)")
        }

        var perModel: [Float] = []
        for member in members {
            guard let crop = Self.expandedBox(box: boxPx, in: extent, scale: member.cropScale),
                  let real = predictReal(model: member.model, image: image, crop: crop) else { return nil }
            perModel.append(real)
        }

        // 두 모델 중 낮은 쪽을 취한다 — 둘 다 확신해야 실물로 본다.
        let raw = perModel.min() ?? 0
        let smooth = smoothed ?? raw
        return AntiSpoofResult(realScore: raw,
                               smoothScore: smooth,
                               isReal: smooth >= FaceIDConfig.livenessThreshold,
                               perModel: perModel)
    }

    /// 진단용: 모델별 3클래스 확률을 그대로 돌려준다.
    func classProbabilities(image: CIImage, faceBox: CGRect) -> [[Float]]? {
        lock.lock(); defer { lock.unlock() }
        let members = loadIfNeeded()
        guard !members.isEmpty else { return nil }
        let extent = image.extent
        let boxPx = CGRect(x: extent.origin.x + faceBox.origin.x * extent.width,
                           y: extent.origin.y + faceBox.origin.y * extent.height,
                           width: faceBox.width * extent.width,
                           height: faceBox.height * extent.height)
        var out: [[Float]] = []
        for m in members {
            guard let crop = Self.expandedBox(box: boxPx, in: extent, scale: m.cropScale),
                  let probs = predictAll(model: m.model, image: image, crop: crop) else { return nil }
            out.append(probs)
        }
        return out
    }

    /// 원 저장소 CropImage._get_new_box 와 같은 규칙:
    /// 종횡비를 유지한 채 중심 기준으로 확대하고, 프레임을 벗어나면 밀어 넣는다.
    /// 확대 배율은 프레임 크기를 넘지 않도록 먼저 줄인다.
    static func expandedBox(box: CGRect, in extent: CGRect, scale: CGFloat) -> CGRect? {
        guard box.width > 0, box.height > 0 else { return nil }
        let effective = min(scale, min((extent.height - 1) / box.height,
                                       (extent.width - 1) / box.width))
        let newWidth = box.width * effective
        let newHeight = box.height * effective
        var minX = box.midX - newWidth / 2
        var minY = box.midY - newHeight / 2

        if minX < extent.minX { minX = extent.minX }
        if minY < extent.minY { minY = extent.minY }
        if minX + newWidth > extent.maxX { minX = extent.maxX - newWidth }
        if minY + newHeight > extent.maxY { minY = extent.maxY - newHeight }

        return CGRect(x: minX, y: minY, width: newWidth, height: newHeight)
    }

    private func predictReal(model: MLModel, image: CIImage, crop: CGRect) -> Float? {
        guard let probs = predictAll(model: model, image: image, crop: crop) else { return nil }
        return probs.count > FaceIDConfig.livenessRealClassIndex
            ? probs[FaceIDConfig.livenessRealClassIndex] : nil
    }

    private func predictAll(model: MLModel, image: CIImage, crop: CGRect) -> [Float]? {
        // 잘라내고 80x80 으로 늘린다(종횡비를 맞추지 않는 것도 원 구현과 같다).
        let sx = CGFloat(size) / crop.width
        let sy = CGFloat(size) / crop.height
        let moved = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        let bounds = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        pixels.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            ciContext.render(moved, toBitmap: base, rowBytes: size * 4,
                             bounds: bounds, format: .RGBA8,
                             colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        if FaceIDConfig.dumpAntiSpoofCrops, dumpCount < 6 {
            dumpCount += 1
            Self.dump(rgba: pixels, size: size, tag: "spoof\(dumpCount)")
        }

        let plane = size * size
        if input == nil {
            input = try? MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
                                      dataType: .float32)
        }
        guard let array = input else { return nil }

        // 255 로 나누지 않는다 — 원 구현이 나누지 않는다.
        array.withUnsafeMutableBytes { raw, _ in
            guard let dst = raw.bindMemory(to: Float.self).baseAddress else { return }
            pixels.withUnsafeBufferPointer { src in
                for i in 0..<plane {
                    let o = i * 4
                    // BGR 순서 — RGBA 버퍼에서 뒤집어 담는다.
                    dst[i]             = Float(src[o + 2])
                    dst[plane + i]     = Float(src[o + 1])
                    dst[2 * plane + i] = Float(src[o])
                }
            }
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["input": array]),
              let out = try? model.prediction(from: provider),
              let logits = out.featureValue(for: "logits")?.multiArrayValue,
              logits.count >= 3 else { return nil }

        var values = [Float](repeating: 0, count: logits.count)
        logits.withUnsafeBufferPointer(ofType: Float.self) { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<logits.count { values[i] = base[i] }
        }
        return Self.softmax(values)
    }

    /// 원본 프레임과 정규화 bbox 를 함께 떨군다. 크롭 배율을 오프라인에서 훑어보려면
    /// 잘린 결과가 아니라 자르기 '전' 상태가 필요하다.
    private func dumpFrame(image: CIImage, faceBox: CGRect, tag: String) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BioUnlock_Spoof")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let cg = ciContext.createCGImage(image, from: image.extent),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: dir.appendingPathComponent("\(tag).png"))
        let meta = "{\"x\":\(faceBox.origin.x),\"y\":\(faceBox.origin.y),\"w\":\(faceBox.width),\"h\":\(faceBox.height),\"iw\":\(image.extent.width),\"ih\":\(image.extent.height)}"
        try? meta.write(to: dir.appendingPathComponent("\(tag).json"), atomically: true, encoding: .utf8)
        DiagnosticLog.write("antispoof frame dump \(tag)")
    }

    /// 모델에 실제로 들어가는 80x80 이미지를 그대로 떨군다.
    /// 크롭 문제인지 텐서 채우기 문제인지 가르는 데 쓴다.
    static func dump(rgba: [UInt8], size: Int, tag: String) {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BioUnlock_Spoof")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: dir.appendingPathComponent("\(tag).png"))
        DiagnosticLog.write("antispoof crop dump \(tag)")
    }

    static func softmax(_ logits: [Float]) -> [Float] {
        guard !logits.isEmpty else { return [] }
        let maxValue = logits.max() ?? 0
        var expValues = logits.map { expf($0 - maxValue) }
        let sum = expValues.reduce(0, +)
        guard sum > 0 else { return expValues }
        for i in expValues.indices { expValues[i] /= sum }
        return expValues
    }
}
