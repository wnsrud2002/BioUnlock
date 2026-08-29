//
//  DebugView.swift
//  BioUnlock
//
//  개발용 계측 창. 파이프라인 각 단계의 값을 실시간으로 본다.
//  등록·설정은 설정 창에 있고, 여기는 진단 전용이다.
//

import SwiftUI
import AppKit
import UnlockKit
import Unlockpalm

struct DebugView: View {
    @ObservedObject var app: AppCoordinator
    @State private var savedNote: String?
    /// 등록은 설정 → 손바닥 탭에서 한다(PalmProfileStore.shared 하나뿐이라
    /// 여기선 그 저장소를 그대로 대조해 보기만 한다).
    @State private var lastMatchScore: Float?
    @State private var lastCompareValidRatio: Float?
    /// 비교를 시도했는지(점수가 nil이어도 "아직 안 눌러봄"과 "눌렀는데 실패"를 구분하려고).
    @State private var didAttemptCompare = false

    private var camera: CameraController { app.camera }

    var body: some View {
        HStack(spacing: 0) {
            CameraPreviewView(camera: camera)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            metrics.frame(width: 300)
        }
        .frame(minWidth: 940, minHeight: 560)
        .background(WindowVisibilityObserver { visible in app.setReason(.debugWindow, visible) })
        .onAppear { app.setReason(.debugWindow, true) }
        .onDisappear { app.setReason(.debugWindow, false) }
    }

    private var metrics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("세션") {
                    row("장치", camera.deviceName)
                    row("상태", camera.status)
                    row("FPS", String(format: "%.1f", camera.fps))
                }

                section("자세 (랜드마크 계산)") {
                    if let f = camera.face {
                        angleRow("yaw", f.yaw)
                        angleRow("pitch", f.pitch)
                        angleRow("roll", f.roll)
                    } else { empty("얼굴 없음") }
                }

                section("보정용 원본값") {
                    if let f = camera.face {
                        row("yawProxy", String(format: "%+.4f", f.pose.yawProxy))
                        row("pitchRatio", String(format: "%.4f", f.pose.pitchRatio))
                        row("interocular", String(format: "%.4f", f.pose.interocular))
                        row("eyeRoll(대조군)", String(format: "%+.4f", f.pose.eyeLineRoll))
                    } else { empty("얼굴 없음") }
                }

                section("정렬 (112×112)") { alignedPanel }
                section("실물 판정") { livenessPanel }
                section("인증") { verifyPanel }
                section("포즈 버킷") { bucketList() }
                section("손바닥 (진단 · 등록은 설정 탭에서)") { palmPanel }
            }
            .padding(14)
        }
    }

    // MARK: - 정렬

    @ViewBuilder
    private var alignedPanel: some View {
        if let a = camera.aligned {
            HStack(spacing: 8) {
                thumb(a.raw, caption: "정렬만", markers: true)
                thumb(a.processed, caption: "+CLAHE", markers: false)
            }
            row("sharpness", String(format: "%.2f", a.sharpness))
            row("residual", String(format: "%.2f px", a.residual))
            HStack(spacing: 6) {
                chip("인증", a.passesAuthGate)
                chip("등록", a.passesEnrollmentGate)
                chip("정렬", a.passesAlignment)
            }
            Button("정렬 저장") { saveAligned(a) }.font(.system(size: 10))
            if let savedNote {
                Text(savedNote).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
        } else { empty("정렬 결과 없음") }
    }

    /// 정준 5점 마커 위에 눈·코·입이 올라오면 정렬이 맞는 것이다.
    private func thumb(_ image: CGImage, caption: String, markers: Bool) -> some View {
        let side: CGFloat = 120
        let scale = side / CGFloat(FaceIDConfig.alignedFaceSize)
        return VStack(spacing: 3) {
            ZStack(alignment: .topLeading) {
                Image(image, scale: 1, label: Text(caption))
                    .resizable().interpolation(.none)
                    .frame(width: side, height: side)
                if markers {
                    Canvas { ctx, _ in
                        // CGImage 는 좌상단 원점이라 CoreImage 정준 좌표의 y 를 되돌린다.
                        for p in FaceAligner.canonical112 {
                            let v = CGPoint(x: p.x * scale, y: (112 - p.y) * scale)
                            ctx.stroke(Path(ellipseIn: CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)),
                                       with: .color(.cyan), lineWidth: 1.5)
                        }
                    }
                    .frame(width: side, height: side)
                }
            }
            .background(Color.black)
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 손금 (초근접)
    //
    // 등록은 설정 → 손바닥 탭에서 한다. 여기는 진단 전용 — 실제로 인코딩되는
    // 그림, 게이트 통과 여부, 방향 진폭 임계값 튜닝, 그리고 등록된 것과 현재
    // 프레임의 대조 점수를 본다. 잠금해제와 같은 저장소를 쓴다.

    @ViewBuilder
    private var palmPanel: some View {
        if let p = camera.palm {
            palmThumb(p.roiImage, caption: "인코딩되는 그림")
            row("살색 비율", String(format: "%.1f%%", p.skinFraction * 100))
            row("손금 텍스처", String(format: "%.1f%%", p.salience * 100))
            row("회전 보정", String(format: "%+.1f도", p.rotationDegrees))
            HStack(spacing: 6) {
                chip("살색", p.passesSkinGate)
                chip("텍스처", p.passesTextureGate)
            }

            // 방향 진폭 임계값은 실측 전이라 처음엔 안 맞을 가능성이 높다.
            // 재빌드 없이 여기서 조정해가며 비교를 반복해볼 수 있게 했다.
            // (바꾼 뒤에는 반드시 재등록해야 한다 — 등록 코드와 기준이 달라진다.)
            HStack(spacing: 6) {
                Text("방향 진폭 \(String(format: "%.0f", PalmConfig.minOrientationSalience))")
                    .font(.system(size: 10))
                Button("-10") {
                    PalmConfig.minOrientationSalience = max(0, PalmConfig.minOrientationSalience - 10)
                }.font(.system(size: 10))
                Button("+10") { PalmConfig.minOrientationSalience += 10 }.font(.system(size: 10))
            }

            Button("지금 비교") { comparePalm(p) }
                .font(.system(size: 10))
                .disabled(!app.hasPalmRegistered)
            if !app.hasPalmRegistered {
                Text("등록된 손금이 없습니다 — 설정 → 손바닥 탭에서 먼저 등록하세요")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            if let ratio = lastCompareValidRatio {
                row("비교 코드 유효 픽셀", String(format: "%.1f%%", ratio * 100))
            }

            if let score = lastMatchScore {
                row("매칭 점수", String(format: "%.4f", score))
                HStack(spacing: 6) {
                    chip(score >= PalmConfig.matchThreshold ? "같은 손(추정)" : "다른 손(추정)",
                         score >= PalmConfig.matchThreshold)
                    Text(String(format: "임계 %.2f(미실측 추정치)", PalmConfig.matchThreshold))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            } else if didAttemptCompare {
                // 0점이 아니라 이 문구가 떠야 정상이다 — 0점은 "다른 손"으로
                // 오해하기 딱 좋다.
                Text("비교 불가 — 겹치는 유효 픽셀 부족. 방향 진폭을 낮춰보세요")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        } else {
            empty("손금 없음 — 손바닥을 카메라에 바짝 대보세요 (5~10cm)")
        }
    }

    private func palmThumb(_ image: CGImage, caption: String) -> some View {
        let side: CGFloat = 120
        return VStack(spacing: 3) {
            Image(image, scale: 1, label: Text(caption))
                .resizable().interpolation(.none)
                .frame(width: side, height: side)
                .background(Color.black)
            Text(caption).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    /// 프레임 처리에서 이미 인코딩한 코드를 그대로 쓴다 — 여기서 다시 인코딩하면
    /// 같은 컨볼루션을 두 번 돌게 된다.
    private func comparePalm(_ p: PalmFrameResult) {
        didAttemptCompare = true
        lastCompareValidRatio = p.code.validRatio
        lastMatchScore = PalmProfileStore.shared.verify(p.code)
        DiagnosticLog.write(String(
            format: "palm 비교 score=%@ validRatio=%.3f threshold=%.2f salience=%.0f",
            lastMatchScore.map { String(format: "%.4f", $0) } ?? "nil(비교불가)",
            p.code.validRatio, PalmConfig.matchThreshold, PalmConfig.minOrientationSalience))
    }

    // MARK: - 인증

    @ViewBuilder
    private var livenessPanel: some View {
        if !FaceIDConfig.antiSpoofEnabled {
            Text("꺼짐 — 사진으로 뚫립니다")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.red)
        } else if let sp = camera.aligned?.spoof {
            row("실물 점수", String(format: "%.4f", sp.realScore))
            row("평활화", String(format: "%.4f", sp.smoothScore))
            row("모델별", sp.perModel.map { String(format: "%.3f", $0) }.joined(separator: " / "))
            HStack(spacing: 6) {
                chip(sp.isReal ? "실물" : "위조", sp.isReal)
                Text(String(format: "임계 %.2f", FaceIDConfig.livenessThreshold))
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(sp.isReal ? Color.green : Color.red)
                        .frame(width: g.size.width * CGFloat(max(0, min(1, sp.smoothScore))))
                    Rectangle().fill(Color.red).frame(width: 1)
                        .offset(x: g.size.width * CGFloat(FaceIDConfig.livenessThreshold))
                }
            }
            .frame(height: 8)
        } else {
            empty(AntiSpoofDetector.shared.isReady ? "판정 없음" : "모델 미로드")
        }
    }

    @ViewBuilder
    private var verifyPanel: some View {
        row("모델", FaceEmbedder.shared.isReady ? "SFace 128d" : "미로드")
        if let live = camera.aligned?.embedding, !app.profileNames.isEmpty {
            let r = FaceProfileStore.shared.verify(live)
            row("대상", r.profileName ?? "-")
            row("점수", String(format: "%.4f", r.score))
            row("  최고샘플", String(format: "%.4f", r.bestSample))
            row("  중심", String(format: "%.4f", r.centroidScore))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(r.score >= FaceIDConfig.unlockIdentityThreshold ? Color.green : Color.orange)
                        .frame(width: g.size.width * CGFloat(max(0, min(1, r.score))))
                    Rectangle().fill(Color.red).frame(width: 1)
                        .offset(x: g.size.width * CGFloat(FaceIDConfig.unlockIdentityThreshold))
                }
            }
            .frame(height: 8)
        } else if app.profileNames.isEmpty {
            empty("등록된 프로필 없음")
        } else {
            empty("게이트 탈락")
        }
    }

    @ViewBuilder
    private func bucketList() -> some View {
        let matched = Set(camera.face?.matchedBuckets ?? [])
        ForEach(FacePoseBucket.allCases, id: \.self) { b in
            HStack(spacing: 6) {
                Image(systemName: matched.contains(b) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(matched.contains(b) ? Color.green : Color.secondary)
                Text(b.rawValue).font(.system(size: 11, design: .monospaced))
                Spacer()
            }
        }
    }

    // MARK: - 조각

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
    }

    private func angleRow(_ k: String, _ rad: Double) -> some View {
        row(k, String(format: "%+.3f rad (%+.1f°)", rad, rad * 180 / .pi))
    }

    private func empty(_ t: String) -> some View {
        Text(t).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
    }

    private func chip(_ label: String, _ ok: Bool) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(ok ? Color.green.opacity(0.25) : Color.red.opacity(0.2))
            .foregroundStyle(ok ? Color.green : Color.red)
            .clipShape(Capsule())
    }

    private func saveAligned(_ a: AlignedFaceResult) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BioUnlock_Aligned")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        for (image, name) in [(a.raw, "raw"), (a.processed, "clahe")] {
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { continue }
            try? data.write(to: dir.appendingPathComponent("\(stamp)_\(name).png"))
        }
        savedNote = "저장: ~/Downloads/BioUnlock_Aligned/\(stamp)_*.png"
    }
}
