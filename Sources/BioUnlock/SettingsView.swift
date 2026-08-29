//
//  SettingsView.swift
//  BioUnlock
//

import SwiftUI
import UnlockKit
import Unlockpalm

struct SettingsView: View {
    @ObservedObject var app: AppCoordinator
    @State private var selectedTab: Tab = .general
    @State private var windowVisible = true

    private enum Tab { case general, face, palm, security }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralTab(app: app).tag(Tab.general).tabItem { Label("일반", systemImage: "gear") }
            FaceTab(app: app).tag(Tab.face).tabItem { Label("얼굴", systemImage: "faceid") }
            PalmTab(app: app).tag(Tab.palm).tabItem { Label("손바닥", systemImage: "hand.raised") }
            SecurityTab(app: app).tag(Tab.security).tabItem { Label("보안", systemImage: "lock") }
        }
        .frame(width: 520, height: 460)
        .background(WindowVisibilityObserver { visible in
            windowVisible = visible
            updateCameraReason()
        })
        .onAppear { updateCameraReason() }
        .onDisappear {
            app.setReason(.faceTab, false)
            app.setReason(.palmTab, false)
        }
        .onChange(of: selectedTab) { _ in updateCameraReason() }
    }

    /// 카메라는 '얼굴'/'손바닥' 탭이 실제로 보이고 있을 때만 켠다.
    /// 탭이 아니라 창 존재만으로 켰다면, 사용자가 '일반' 탭을 보고 있어도
    /// 창을 열어둔 것만으로 카메라가 계속 돌게 된다.
    private func updateCameraReason() {
        app.setReason(.faceTab, windowVisible && selectedTab == .face)
        app.setReason(.palmTab, windowVisible && selectedTab == .palm)
    }
}

// MARK: - 일반

private struct GeneralTab: View {
    @ObservedObject var app: AppCoordinator

    var body: some View {
        Form {
            Section {
                Toggle("얼굴로 잠금 해제", isOn: app.faceUnlockEnabled)
                    .disabled(!app.isReadyForFaceUnlock)
                Toggle("손바닥으로 잠금 해제", isOn: app.palmUnlockEnabled)
                    .disabled(!app.isReadyForPalmUnlock)
                if !app.hasPalmRegistered {
                    Text("'손바닥' 탭에서 먼저 등록해야 켤 수 있습니다.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else if app.palmUnlockEnabled.wrappedValue {
                    Text("손바닥은 라이브니스(사진 방어)가 없습니다 — 등록된 손바닥 사진 한 장으로도 뚫릴 수 있습니다.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
                Toggle("로그인 시 자동 실행", isOn: $app.launchAtLogin)
            }

            Section {
                Toggle("카메라를 항상 켜 두기", isOn: $app.cameraAlwaysOn)
                Text(app.cameraAlwaysOn
                     ? "인식이 약 0.5초 빨라지지만 카메라 표시등이 상시 켜집니다."
                     : "잠금·등록·프리뷰 중에만 카메라를 켭니다. 세션 시작에 시간이 조금 걸립니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } header: { Text("카메라") }

            Section {
                LabeledContent("장치", value: app.camera.deviceName)
                LabeledContent("상태", value: app.camera.status)
                LabeledContent("FPS", value: String(format: "%.1f", app.camera.fps))
            } header: { Text("현재") }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 얼굴 등록

private struct FaceTab: View {
    @ObservedObject var app: AppCoordinator
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 10) {
            CameraPreviewView(camera: app.camera)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            switch app.enrollment.step {
            case .collecting(let bucket):
                VStack(spacing: 6) {
                    Text(app.enrollment.hint).font(.system(size: 15, weight: .semibold))
                    Text(bucket.rawValue).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ProgressView(value: app.enrollment.progress)
                    if !app.enrollment.rejectReason.isEmpty {
                        Text(app.enrollment.rejectReason)
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                    Button("취소") { app.enrollment.cancel() }
                }

            case .extendedPrompt:
                VStack(spacing: 6) {
                    Text(app.enrollment.hint).font(.system(size: 12))
                    HStack {
                        Button("확장 포즈도 등록") { app.enrollment.acceptExtended() }
                            .buttonStyle(.borderedProminent)
                        Button("여기까지") { app.enrollment.declineExtended() }
                    }
                }

            case .finalizing:
                ProgressView(app.enrollment.hint)

            case .idle, .done, .failed:
                HStack {
                    TextField("이름", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("등록 시작") { app.enrollment.start(name: newName); newName = "" }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        .buttonStyle(.borderedProminent)
                }
                if case .done(let s) = app.enrollment.step {
                    Text("완료: \(s)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                }
                if case .failed(let s) = app.enrollment.step {
                    Text("실패: \(s)").font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red)
                }
            }

            Divider()

            if app.profileNames.isEmpty {
                Text("등록된 얼굴이 없습니다").foregroundStyle(.secondary).font(.system(size: 11))
            } else {
                ForEach(app.profileNames, id: \.self) { name in
                    HStack {
                        Image(systemName: "person.crop.circle")
                        Text(name)
                        if let p = FaceProfileStore.shared.profile(named: name) {
                            Text("샘플 \(p.samples.count) · \(p.bucketsCovered.count)개 포즈")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("삭제") {
                            FaceProfileStore.shared.delete(name: name)
                            app.refreshProfiles()
                        }
                    }
                }

                Divider()
                MatchTestView(title: "지금 이 얼굴이 등록된 얼굴과 맞는지",
                              score: app.testFaceScore,
                              passes: app.testFacePasses,
                              threshold: Double(FaceIDConfig.unlockIdentityThreshold),
                              subject: app.testFaceName,
                              idleHint: "카메라를 보세요 — 게이트를 통과한 프레임이 오면 점수가 나옵니다")
            }
            Spacer()
        }
        .padding()
        .onAppear { app.isFaceTestVisible = true }
        .onDisappear { app.isFaceTestVisible = false; app.resetTestScores() }
    }
}

// MARK: - 인식 테스트 (얼굴·손금 공통)

/// 등록이 제대로 됐는지 화면을 잠그지 않고 바로 확인한다.
///
/// 점수는 잠금 해제가 쓰는 것과 완전히 같은 대조 함수에서 나온다 — 테스트용으로
/// 따로 계산하면 그 계산의 오차를 재게 된다(얼굴 임계값을 LFW 로 잡을 때
/// BatchEmbedder 를 인증과 같은 경로로 돌린 것과 같은 이유).
private struct MatchTestView: View {
    let title: String
    let score: Float?
    let passes: Bool
    let threshold: Double
    /// 얼굴은 누구와 맞았는지 보여준다. 손금은 프로필이 하나뿐이라 nil.
    var subject: String?
    let idleHint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold))

            if let score {
                HStack(spacing: 8) {
                    Text(passes ? "일치" : "불일치")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(passes ? Color.green.opacity(0.25) : Color.red.opacity(0.2))
                        .foregroundStyle(passes ? Color.green : Color.red)
                        .clipShape(Capsule())
                    Text(String(format: "%.4f", score))
                        .font(.system(size: 13, design: .monospaced))
                    if let subject { Text(subject).font(.system(size: 11)).foregroundStyle(.secondary) }
                    Spacer()
                    Text(String(format: "임계 %.2f", threshold))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                // 막대에 임계선을 같이 그려 지금 얼마나 여유가 있는지 보이게 한다.
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule().fill(passes ? Color.green : Color.orange)
                            .frame(width: g.size.width * CGFloat(max(0, min(1, score))))
                        Rectangle().fill(Color.red).frame(width: 1)
                            .offset(x: g.size.width * CGFloat(threshold))
                    }
                }
                .frame(height: 8)
            } else {
                Text(idleHint).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 손바닥 등록

private struct PalmTab: View {
    @ObservedObject var app: AppCoordinator

    private var camera: CameraController { app.camera }
    private var session: PalmEnrollmentSession { app.palmEnrollment }

    var body: some View {
        VStack(spacing: 10) {
            CameraPreviewView(camera: camera)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            switch session.step {
            case .collecting:
                collectingView
            case .idle, .done, .failed:
                readyView
            }

            Divider()
            registeredView

            if app.hasPalmRegistered, !session.isActive {
                Divider()
                MatchTestView(title: "지금 이 손금이 등록된 손금과 맞는지",
                              score: app.testPalmScore,
                              passes: app.testPalmPasses,
                              threshold: Double(PalmConfig.matchThreshold),
                              idleHint: "손바닥을 카메라에 바짝 대세요 — 게이트를 통과하면 점수가 나옵니다")
            }

            Text("⚠️ 라이브니스(사진 방어)가 없습니다 — 등록된 손금 사진 한 장으로도 잠금이 풀릴 수 있습니다. 임계값도 아직 타인 데이터로 검증되지 않았습니다.")
                .font(.system(size: 10)).foregroundStyle(.orange)

            Spacer()
        }
        .padding()
        .onAppear { app.isPalmTestVisible = true }
        .onDisappear {
            app.isPalmTestVisible = false
            app.resetTestScores()
            if session.isActive { session.cancel() }
        }
    }

    // MARK: - 등록 진행 중

    private var collectingView: some View {
        VStack(spacing: 6) {
            Text("손바닥을 카메라에 최대한 가까이")
                .font(.system(size: 14, weight: .semibold))
            Text("손금이 화면을 꽉 채우도록 (5~10cm)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ProgressView(value: session.progress)
            Text("\(session.collected) / \(PalmConfig.enrollmentCandidateCount) 장")
                .font(.system(size: 11, design: .monospaced))
            if !session.blockedReason.isEmpty {
                Text(session.blockedReason)
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            Button("취소") { session.cancel() }
        }
    }

    // MARK: - 등록 대기

    @ViewBuilder
    private var readyView: some View {
        if let p = camera.palm {
            HStack(spacing: 10) {
                if let img = p.roiImage { palmThumb(img) }
                VStack(alignment: .leading, spacing: 5) {
                    distanceChip(p.location.verdict)
                    statusChip(String(format: "손금 텍스처 %.0f%%", p.salience * 100),
                               p.passesTextureGate)
                }
            }
            if let guidance = p.guidance {
                Text(guidance).font(.system(size: 11)).foregroundStyle(.orange)
            }
        } else {
            Text("손바닥을 카메라 앞 10~12cm 에 두세요")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }

        Button(app.hasPalmRegistered ? "다시 등록" : "등록 시작") { session.start() }
            .buttonStyle(.borderedProminent)

        if case .done(let n) = session.step {
            Text("등록 완료 — 샘플 \(n)장").font(.system(size: 11)).foregroundStyle(.green)
        }
        if case .failed(let reason) = session.step {
            Text(reason).font(.system(size: 11)).foregroundStyle(.red)
        }
    }

    /// 거리 안내는 통과/실패가 아니라 '어느 쪽으로 움직여야 하는지'를 보여준다.
    private func distanceChip(_ verdict: PalmLocation.Verdict) -> some View {
        let (label, ok): (String, Bool) = {
            switch verdict {
            case .ok:       return ("거리 적당", true)
            case .tooClose: return ("너무 가까움", false)
            case .tooFar:   return ("너무 멂", false)
            case .noHand:   return ("손 없음", false)
            }
        }()
        return statusChip(label, ok)
    }

    /// 실제로 인코딩되는 그림을 보여준다 — 손금이 안 보이면 등록해도 소용없다.
    private func palmThumb(_ image: CGImage) -> some View {
        VStack(spacing: 3) {
            Image(image, scale: 1, label: Text("손금 ROI"))
                .resizable().interpolation(.none)
                .frame(width: 130, height: 130)
                .background(Color.black)
            Text("인코딩되는 그림").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 등록 상태

    @ViewBuilder
    private var registeredView: some View {
        if app.hasPalmRegistered {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("손금 등록됨 (샘플 \(app.palmSampleCount)장)")
                Spacer()
                Button("삭제") {
                    PalmProfileStore.shared.clear()
                    session.cancel()
                    DiagnosticLog.write("palm 등록 삭제됨(설정 탭)")
                }
            }
        } else {
            Text("등록된 손금이 없습니다").foregroundStyle(.secondary).font(.system(size: 11))
        }
    }

    private func statusChip(_ label: String, _ ok: Bool) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(ok ? Color.green.opacity(0.25) : Color.red.opacity(0.2))
            .foregroundStyle(ok ? Color.green : Color.red)
            .clipShape(Capsule())
    }
}

// MARK: - 보안

private struct SecurityTab: View {
    @ObservedObject var app: AppCoordinator
    @State private var password = ""
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("접근성 권한", systemImage: app.hasAccessibility ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(app.hasAccessibility ? .green : .red)
                    Spacer()
                    if !app.hasAccessibility {
                        Button("요청") { app.requestAccessibility() }
                    }
                }
                Text("잠금화면에 비밀번호를 입력하려면 필요합니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } header: { Text("권한") }

            Section {
                if app.passwordIsSet {
                    HStack {
                        Label("저장됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("삭제") {
                            LoginPasswordStore.clear()
                            app.refreshPassword()
                            app.faceUnlockEnabled.wrappedValue = false
                            app.palmUnlockEnabled.wrappedValue = false
                            note = ""
                        }
                    }
                } else {
                    SecureField("Mac 로그인 비밀번호", text: $password)
                    Button("검증 후 저장") {
                        if LoginPasswordStore.save(password) {
                            app.refreshPassword(); note = "검증 후 저장됨"
                        } else {
                            note = "검증 실패 — 비밀번호가 틀립니다"
                        }
                        password = ""
                    }
                    .disabled(password.isEmpty)
                }
                if !note.isEmpty {
                    Text(note).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(app.passwordIsSet ? .green : .red)
                }
            } header: { Text("로그인 비밀번호") } footer: {
                Text("macOS 는 서드파티가 잠금화면 인증에 들어오는 것을 막습니다. 그래서 이 앱은 얼굴이 맞으면 저장해 둔 비밀번호를 대신 입력합니다. 비밀번호는 암호화해 키체인에 두지만, 앱이 복원할 수 있는 형태입니다.")
                    .font(.system(size: 10))
            }

            Section {
                sliderRow(
                    title: "인식 엄격도",
                    value: $app.unlockIdentityThreshold,
                    range: 0.30...0.70,
                    format: "%.2f")
                Stepper("연속 통과 요구: \(app.requiredConsecutiveFrames) 프레임",
                       value: $app.requiredConsecutiveFrames, in: 2...5)
                Text("실측(LFW 5675명 대조): 타인 최고 점수 0.37, 본인 실사용 0.93~0.94.\n0.40~0.60 구간에서 오인식·오거부 모두 0% 확인됨. 값을 올릴수록 엄격해지지만 본인도 더 자주 튕길 수 있습니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button("기본값(0.48)으로 복원") { app.resetSecurityDefaults() }
                    .font(.system(size: 10))
            } header: { Text("인식") }

            Section {
                Toggle("사진·화면 위조 탐지", isOn: $app.antiSpoofEnabled)
                sliderRow(
                    title: "실물 판정 엄격도",
                    value: $app.livenessThreshold,
                    range: 0.20...0.80,
                    format: "%.2f")
                    .disabled(!app.antiSpoofEnabled)
                Text("실측(두 모델 최소값): 실물 하위 0.72 / 폰 화면 위조 최고 0.001.\n0.20~0.70 구간에서 안전 확인됨. 값을 낮출수록 위조 탐지가 느슨해집니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } header: { Text("위조 방지") } footer: {
                Text("폰 화면 재생 공격만 시험했습니다. 인쇄물, 고해상도 디스플레이, 동영상 재생, 3D 마스크는 검증되지 않았습니다. 꺼두면 사진 한 장으로 잠금이 열립니다.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }

            Section {
                Button("비밀번호·잠금 설정 초기화…", role: .destructive) { showResetConfirm = true }
                    .confirmationDialog("저장된 비밀번호와 잠금 해제 활성화 상태를 지웁니다. 등록된 얼굴은 지워지지 않습니다.",
                                        isPresented: $showResetConfirm, titleVisibility: .visible) {
                        Button("초기화", role: .destructive) {
                            app.resetPasswordAndUnlock()
                            password = ""; note = ""
                        }
                        Button("취소", role: .cancel) {}
                    }
            } header: { Text("초기화") } footer: {
                Text("등록된 얼굴은 지워지지 않습니다 — 얼굴 탭에서 프로필별로 따로 삭제하세요.")
                    .font(.system(size: 10))
            }
        }
        .formStyle(.grouped)
    }

    @State private var showResetConfirm = false

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
