//
//  EmbedderSelfTest.swift
//  Unlockface
//
//  Swift 전처리가 Python 기준 구현과 같은 임베딩을 내는지 확인하는 자가진단.
//
//  채널 순서(RGB/BGR), 레이아웃(NCHW/NHWC), 정규화가 어긋나도 임베딩은 조용히
//  '그럴듯한' 값을 낸다. 같은 이미지에 대한 기준 벡터와 대조하는 것 말고는
//  틀렸는지 알 방법이 없다.
//

import Foundation
import CoreGraphics
import AppKit
import UnlockKit

enum EmbedderSelfTest {

    /// PNG 를 앱 파이프라인과 동일한 RGBA8 버퍼로 읽는다.
    static func rgbaBuffer(from path: String, size: Int) -> [UInt8]? {
        guard let image = NSImage(contentsOfFile: path),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return ok ? pixels : nil
    }

    static func run(paths: [String]) {
        let size = FaceIDConfig.alignedFaceSize
        for path in paths {
            guard let pixels = rgbaBuffer(from: path, size: size) else {
                DiagnosticLog.write("selftest \((path as NSString).lastPathComponent): 로드 실패")
                continue
            }
            guard let v = FaceEmbedder.shared.embed(rgba: pixels, size: size) else {
                DiagnosticLog.write("selftest \((path as NSString).lastPathComponent): 임베딩 실패")
                continue
            }
            let head = v.prefix(8).map { String(format: "%.6f", $0) }.joined(separator: ",")
            DiagnosticLog.write("selftest \((path as NSString).lastPathComponent) dim=\(v.count) head=[\(head)]")

            // 기준 구현과 대조할 수 있도록 전체 벡터를 떨군다.
            let out = (path as NSString).deletingPathExtension + ".swift.txt"
            try? v.map { String(format: "%.8f", $0) }.joined(separator: "\n")
                .write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
