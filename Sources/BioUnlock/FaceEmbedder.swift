//
//  FaceEmbedder.swift
//  BioUnlock
//
//  정렬된 112x112 RGBA 버퍼 → 128차원 얼굴 임베딩.
//
//  모델: OpenCV Zoo SFace (face_recognition_sface_2021dec), Apache-2.0, ONNX→CoreML FP16.
//
//  이전엔 InsightFace w600k_mbf(ArcFace)를 썼으나 그 사전학습 가중치는
//  "비상업적 연구용 전용" 라이선스라 일반 배포용 앱에 넣을 수 없어 교체했다.
//  SFace는 모델 자체 LICENSE 파일이 Apache-2.0 이라 재배포·수정이 명시적으로 허용된다.
//
//  입력 규약은 ONNX 그래프를 직접 열어 실측 확인했다(문서마다 얘기가 달라서
//  신뢰하지 않았다 — tools/convert_sface.py 참고):
//    NCHW / RGB / 원본 [0,255] 픽셀값 그대로
//  정규화((x-127.5)/128)는 그래프 안에 Sub/Mul 노드로 이미 내장돼 있어서,
//  ArcFace 때와 달리 여기서 스케일을 다시 적용하면 안 된다(이중 정규화가 된다).
//  정렬은 그대로 재사용한다 — SFace 논문이 InsightFace 표준 5점 정렬을 따른다고
//  명시하므로 FaceAligner 를 바꿀 필요가 없었다.
//

import Foundation
import CoreML
import Accelerate
import UnlockKit

final class FaceEmbedder {
    static let shared = FaceEmbedder()

    private let lock = NSLock()
    private var model: MLModel?
    private var input: MLMultiArray?
    private var loadFailed = false

    private init() {}

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return model != nil
    }

    /// 유휴 시 언로드했다가 필요할 때 다시 올린다(Phase 5의 RAM 회수 대비).
    func unload() {
        lock.lock(); defer { lock.unlock() }
        model = nil
        input = nil
    }

    private func loadIfNeeded() -> MLModel? {
        if let model { return model }
        guard !loadFailed else { return nil }

        guard let url = Bundle.main.url(forResource: "SFace", withExtension: "mlmodelc") else {
            DiagnosticLog.write("embed 로드 실패: 번들에 SFace.mlmodelc 없음")
            loadFailed = true
            return nil
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        do {
            let loaded = try MLModel(contentsOf: url, configuration: config)
            model = loaded
            DiagnosticLog.write("embed 모델 로드 완료")
            return loaded
        } catch {
            DiagnosticLog.write("embed 로드 실패: \(error.localizedDescription)")
            loadFailed = true
            return nil
        }
    }

    /// - Parameters:
    ///   - rgba: 정렬된 얼굴, size×size, RGBA8 (행 0 = 위쪽)
    ///   - flipped: 좌우 반전본으로 추론할지 (등록 TTA용)
    /// - Returns: L2 정규화된 128차원 벡터
    func embed(rgba: [UInt8], size: Int, flipped: Bool = false) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }

        guard rgba.count >= size * size * 4, let model = loadIfNeeded() else { return nil }

        let plane = size * size
        if input == nil || input?.count != 3 * plane {
            input = try? MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
                                      dataType: .float32)
        }
        guard let array = input else { return nil }

        // NCHW 로 채우되, 정규화는 하지 않는다 — 모델 그래프 안에 이미
        // (x-127.5)*0.0078125 로 내장돼 있다(그래프 첫 두 노드가 Sub/Mul).
        // 여기서 또 스케일을 적용하면 이중 정규화로 조용히 값이 틀어진다.
        array.withUnsafeMutableBytes { raw, _ in
            guard let dst = raw.bindMemory(to: Float.self).baseAddress else { return }
            rgba.withUnsafeBufferPointer { src in
                for y in 0..<size {
                    let row = y * size
                    for x in 0..<size {
                        let sx = flipped ? (size - 1 - x) : x
                        let o = (row + sx) * 4
                        let d = row + x
                        dst[d]             = Float(src[o])      // R
                        dst[plane + d]     = Float(src[o + 1])  // G
                        dst[2 * plane + d] = Float(src[o + 2])  // B
                    }
                }
            }
        }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["input": array]),
              let out = try? model.prediction(from: provider),
              let value = out.featureValue(for: "embedding")?.multiArrayValue else {
            return nil
        }

        var vector = [Float](repeating: 0, count: value.count)
        value.withUnsafeBufferPointer(ofType: Float.self) { buf in
            guard let base = buf.baseAddress else { return }
            vector.withUnsafeMutableBufferPointer { out in
                guard let o = out.baseAddress else { return }
                cblas_scopy(Int32(value.count), base, 1, o, 1)
            }
        }
        return VectorMath.l2Normalized(vector)
    }
}
