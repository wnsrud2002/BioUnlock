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
            }
            Spacer()
        }
        .padding()
    }
}

// MARK: - 손바닥 등록

private struct PalmTab: View {
    @ObservedObject var app: AppCoordinator
    @State private var registeredThumb: CGImage?
    @State private var note: String?

    private var camera: CameraController { app.camera }

    var body: some View {
        VStack(spacing: 10) {
            CameraPreviewView(camera: camera)
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if let p = camera.palm {
                HStack(spacing: 8) {
                    statusChip("손바닥 방향", p.isPalmFacing)
                    statusChip("거리 적당", p.passesSourcePixelGate)
                }
                // 방향 판별 부호는 카메라·손마다 다를 수 있어 출발점 추정치다.
                // 손바닥을 보이고 있는데도 위 칩이 빨간색이면 이 버튼으로 뒤집는다.
                if !p.isPalmFacing {
                    HStack(spacing: 6) {
                        Text("분명 손바닥을 보이고 있다면:").font(.system(size: 10)).foregroundStyle(.secondary)
                        Button("부호 뒤집기") { PalmConfig.palmFacingSign *= -1 }.font(.system(size: 10))
                    }
                }
                if !p.passesSourcePixelGate {
                    Text(String(format: "손을 더 가까이(현재 %.0fpx, 필요 %.0fpx 이상)",
                                p.sourcePixels, PalmConfig.minSourcePixels))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button("이 손 등록") { register(p) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(p.isPalmFacing && p.passesSourcePixelGate))
            } else {
                Text("카메라에 손바닥을 펴서 비춰주세요 (25~40cm 정도)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.green)
            }

            Divider()

            if app.hasPalmRegistered {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("손바닥 등록됨")
                    if let thumb = registeredThumb {
                        Image(thumb, scale: 1, label: Text("등록됨"))
                            .resizable().frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    Button("삭제") { clear() }
                }
            } else {
                Text("등록된 손바닥이 없습니다").foregroundStyle(.secondary).font(.system(size: 11))
            }

            Text("⚠️ 라이브니스(사진 방어)가 없습니다 — 등록된 손바닥 사진 한 장으로도 잠금이 풀릴 수 있습니다. 임계값(0.73)도 본인 양손 10회 테스트로만 잡은 값이라 다른 사람 손을 완전히 막는다는 보장이 없습니다.")
                .font(.system(size: 10)).foregroundStyle(.orange)

            Spacer()
        }
        .padding()
    }

    private func statusChip(_ label: String, _ ok: Bool) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(ok ? Color.green.opacity(0.25) : Color.red.opacity(0.2))
            .foregroundStyle(ok ? Color.green : Color.red)
            .clipShape(Capsule())
    }

    private func register(_ p: AlignedPalmResult) {
        let luma = FacePreprocessor.luma(from: p.pixels, count: PalmAligner.roiOutputSize * PalmAligner.roiOutputSize)
        guard let code = PalmMatcher.encode(luma: luma, size: PalmAligner.roiOutputSize) else {
            note = "등록 실패 — 다시 시도해 주세요"
            return
        }
        PalmProfileStore.shared.register(code)
        registeredThumb = p.roi
        app.refreshPalmRegistration()
        note = "등록 완료"
        DiagnosticLog.write(String(format: "palm 등록(설정 탭) validRatio=%.3f", code.validRatio))
    }

    private func clear() {
        PalmProfileStore.shared.clear()
        registeredThumb = nil
        app.refreshPalmRegistration()
        note = nil
        DiagnosticLog.write("palm 등록 삭제됨(설정 탭)")
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
