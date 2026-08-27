//
//  BatchEmbedder.swift
//  Unlockface
//
//  폴더 안의 이미지를 앱의 '실제' 파이프라인(Vision 검출 → 5점 → 정렬 → 임베딩)에
//  그대로 태워 임베딩을 뽑는 일괄 모드.
//
//  타인 점수 분포(오인식률)를 재려고 만들었다. 별도 구현으로 재면 그 구현의
//  오차를 재는 꼴이 되므로, 반드시 인증에 쓰이는 코드와 같은 경로여야 한다.
//
//  사용: Unlockface.app/Contents/MacOS/Unlockface --batch <입력폴더> <출력.json>
//

import Foundation
import Vision
import CoreImage
import AppKit
import UnlockKit

enum BatchEmbedder {

    struct Entry: Codable {
        let file: String
        let embedding: [Float]
        let sharpness: Float
        let residual: Double
        let interocular: Double
    }

    struct Score: Codable {
        let file: String
        let score: Float
        let bestSample: Float
        let centroid: Float
        let sharpness: Float
        /// 등록 샘플 각각과의 유사도. 어느 샘플이 타인을 잘 받아주는지 보려고 남긴다.
        let perSample: [Float]
    }

    /// 일괄 임베딩 결과를 등록된 프로필과 대조한다.
    ///
    /// 마스터 키를 셸로 꺼내지 않으려고 앱 안에서 채점한다. 키는 앱 밖으로 나가지 않는다.
    static func score(embeddingsPath: String, outputPath: String) -> Int32 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: embeddingsPath)),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            FileHandle.standardError.write("임베딩 파일을 읽을 수 없음: \(embeddingsPath)\n".data(using: .utf8)!)
            return 1
        }
        // 프로필 로드는 키체인 복호화를 포함해 비동기로 돈다(앱 시작 데드락 방지 때문에
        // 그렇게 고쳤다). 헤드리스 CLI 로 막 시작한 프로세스는 그 로드가 끝나기 전에
        // profileNames 를 읽을 수 있어 짧게 기다려준다.
        var waited = 0.0
        while !FaceProfileStore.shared.isLoaded, waited < 15.0 {
            Thread.sleep(forTimeInterval: 0.2)
            waited += 0.2
        }
        guard let profileName = FaceProfileStore.shared.profileNames.first,
              let profile = FaceProfileStore.shared.profile(named: profileName) else {
            FileHandle.standardError.write("등록된 프로필이 없음\n".data(using: .utf8)!)
            return 1
        }
        FileHandle.standardError.write(
            "프로필 '\(profileName)' 샘플 \(profile.samples.count) vs 임베딩 \(entries.count)\n"
                .data(using: .utf8)!)

        let scores: [Score] = entries.map { e in
            let per = profile.samples.map { VectorMath.cosineSimilarity(e.embedding, $0.embedding) }
            let best = per.max() ?? 0
            let cen = profile.centroid.isEmpty ? 0
                : VectorMath.cosineSimilarity(e.embedding, profile.centroid)
            return Score(file: e.file,
                         score: best * FaceIDConfig.identityMaxWeight
                              + cen * FaceIDConfig.identityCentroidWeight,
                         bestSample: best,
                         centroid: cen,
                         sharpness: e.sharpness,
                         perSample: per)
        }
        // 어느 등록 샘플이 어느 버킷인지도 같이 내보낸다.
        let meta = ["buckets": profile.samples.map(\.bucket)]
        let out: [String: Any] = ["meta": meta,
                                  "scores": scores.map { [
                                      "file": $0.file, "score": $0.score,
                                      "best": $0.bestSample, "centroid": $0.centroid,
                                      "sharpness": $0.sharpness, "perSample": $0.perSample
                                  ] }]
        guard let json = try? JSONSerialization.data(withJSONObject: out) else { return 1 }
        try? json.write(to: URL(fileURLWithPath: outputPath))
        return 0
    }

    /// 폴더의 이미지들을 안티스푸핑 파이프라인에 통과시켜 3클래스 확률을 전부 찍는다.
    /// 클래스 인덱스의 의미를 정답이 있는 샘플로 확정하는 데 쓴다.
    static func spoofCheck(inputDir: String) -> Int32 {
        let fm = FileManager.default
        let exts: Set<String> = ["jpg", "jpeg", "png"]
        let files = ((try? fm.contentsOfDirectory(atPath: inputDir)) ?? [])
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3

        for name in files {
            let path = (inputDir as NSString).appendingPathComponent(name)
            guard let ns = NSImage(contentsOfFile: path),
                  let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            guard let obs = (request.results ?? [])
                .max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
                print("\(name): 얼굴 검출 실패"); continue
            }
            let ci = CIImage(cgImage: cg)
            guard let probs = AntiSpoofDetector.shared.classProbabilities(image: ci, faceBox: obs.boundingBox) else {
                print("\(name): 판정 실패"); continue
            }
            let text = probs.map { model in
                "[" + model.map { String(format: "%.4f", $0) }.joined(separator: " ") + "]"
            }.joined(separator: "  ")
            // 두 모델 확률을 더한 argmax 가 원 구현의 판정 방식이다.
            var summed = [Float](repeating: 0, count: probs.first?.count ?? 0)
            for model in probs { for i in model.indices { summed[i] += model[i] } }
            let winner = summed.enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
            print("\(name)  \(text)  → argmax=\(winner)")
        }
        return 0
    }

    static func run(inputDir: String, outputPath: String) -> Int32 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: inputDir) else {
            FileHandle.standardError.write("입력 폴더를 열 수 없음: \(inputDir)\n".data(using: .utf8)!)
            return 1
        }

        let exts: Set<String> = ["jpg", "jpeg", "png"]
        var files: [String] = []
        for case let path as String in walker
        where exts.contains((path as NSString).pathExtension.lowercased()) {
            files.append((inputDir as NSString).appendingPathComponent(path))
        }
        files.sort()
        FileHandle.standardError.write("이미지 \(files.count)개\n".data(using: .utf8)!)

        let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3

        let size = FaceIDConfig.alignedFaceSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var entries: [Entry] = []
        var noFace = 0, noLandmarks = 0, gateFailed = 0

        for (index, path) in files.enumerated() {
            if index % 500 == 0 {
                FileHandle.standardError.write("  \(index)/\(files.count)\n".data(using: .utf8)!)
            }
            guard let nsImage = NSImage(contentsOfFile: path),
                  let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }

            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            guard let obs = (request.results ?? [])
                .max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { noFace += 1; continue }
            guard let key = FaceLandmarks5(observation: obs) else { noLandmarks += 1; continue }

            let ci = CIImage(cgImage: cg)
            guard let alignedImage = FaceAligner.align(image: ci, landmarks: key, size: size) else { continue }

            let bounds = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
            pixels.withUnsafeMutableBytes { buf in
                guard let base = buf.baseAddress else { return }
                ciContext.render(alignedImage, toBitmap: base, rowBytes: size * 4,
                                 bounds: bounds, format: .RGBA8,
                                 colorSpace: CGColorSpaceCreateDeviceRGB())
            }

            let luma = FacePreprocessor.luma(from: pixels, count: size * size)
            let sharpness = FacePreprocessor.laplacianVariance(luma: luma, size: size)
            let residual = FaceAligner.residual(landmarks: key, imageExtent: ci.extent, size: size)

            // 정렬 게이트는 유지한다 — 정렬이 틀리면 임베딩 자체가 무의미하다.
            // 선명도는 기록만 하고 거르지 않는다. FAR 표본을 최대한 확보하고
            // 임계값별 영향은 분석 단계에서 따진다.
            guard residual <= FaceIDConfig.alignmentResidualMax else { gateFailed += 1; continue }

            guard let v = FaceEmbedder.shared.embed(rgba: pixels, size: size) else { continue }
            entries.append(Entry(file: (path as NSString).lastPathComponent,
                                 embedding: v,
                                 sharpness: sharpness,
                                 residual: Double(residual),
                                 interocular: Double(key.interocular)))
        }

        FileHandle.standardError.write(
            "완료: 임베딩 \(entries.count) / 얼굴없음 \(noFace) / 랜드마크실패 \(noLandmarks) / 게이트탈락 \(gateFailed)\n"
                .data(using: .utf8)!)

        do {
            try JSONEncoder().encode(entries).write(to: URL(fileURLWithPath: outputPath))
        } catch {
            FileHandle.standardError.write("출력 실패: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
        return 0
    }
}
