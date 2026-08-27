//
//  CameraPreviewView.swift
//  BioUnlock
//
//  프리뷰 + 검출 오버레이. 등록 창과 디버그 창이 함께 쓴다.
//

import SwiftUI

struct CameraPreviewView: View {
    @ObservedObject var camera: CameraController
    var showLandmarks: Bool = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let image = camera.previewImage {
                    let rect = Self.fittedRect(
                        imageSize: CGSize(width: image.width, height: image.height),
                        in: geo.size)
                    Image(image, scale: 1, label: Text("camera"))
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    overlay(in: rect)
                } else {
                    Text(camera.status)
                        .foregroundStyle(.white.opacity(0.7))
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }

    @ViewBuilder
    private func overlay(in rect: CGRect) -> some View {
        if let face = camera.face {
            let box = Self.viewRect(visionBox: face.boundingBox, in: rect)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .stroke(Color.green, lineWidth: 2)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                if showLandmarks {
                    Canvas { ctx, _ in
                        for p in face.landmarks {
                            let v = Self.viewPoint(visionPoint: p, in: rect)
                            ctx.fill(Path(ellipseIn: CGRect(x: v.x - 1, y: v.y - 1, width: 2, height: 2)),
                                     with: .color(.yellow.opacity(0.45)))
                        }
                        for p in face.keyPoints.asArray {
                            let v = Self.viewPoint(visionPoint: p, in: rect)
                            ctx.fill(Path(ellipseIn: CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7)),
                                     with: .color(.red))
                        }
                    }
                }
            }
        }
        if showLandmarks, let palm = camera.palm {
            // 색으로 부호 판정 결과를 바로 보여준다 — 청록=손바닥, 주황=손등(또는 부호가 틀림).
            Canvas { ctx, _ in
                for p in palm.allJoints {
                    let v = Self.viewPoint(visionPoint: p, in: rect)
                    ctx.fill(Path(ellipseIn: CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6)),
                             with: .color(palm.isPalmFacing ? .cyan : .orange))
                }
            }
        }
    }

    // Vision 정규화 좌표는 원점이 좌하단이라 SwiftUI 로 옮길 때 y 를 뒤집는다.

    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func viewPoint(visionPoint p: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + (1 - p.y) * rect.height)
    }

    static func viewRect(visionBox box: CGRect, in rect: CGRect) -> CGRect {
        let tl = viewPoint(visionPoint: CGPoint(x: box.minX, y: box.maxY), in: rect)
        return CGRect(x: tl.x, y: tl.y, width: box.width * rect.width, height: box.height * rect.height)
    }
}
