//
//  AppCoordinator.swift
//  BioUnlock
//
//  카메라·등록·잠금해제를 앱 수준에서 소유한다.
//
//  이전에는 ContentView 가 이것들을 들고 있어서 창을 닫으면 프레임 콜백이 끊겼다.
//  메뉴바 상주 앱에서는 창이 없는 게 정상 상태이므로 소유권을 여기로 올린다.
//

import Foundation
import Combine
import ServiceManagement
import SwiftUI
import AppKit
import UnlockKit
import Unlockpalm

@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    let camera = CameraController()
    let enrollment = EnrollmentSession()
    let palmEnrollment = PalmEnrollmentSession()
    let unlock = UnlockService()

    @Published private(set) var profileNames: [String] = []
    @Published private(set) var passwordIsSet: Bool = false
    @Published private(set) var hasAccessibility: Bool = false
    /// PalmProfileStore(세션 메모리)는 그 자체로 Combine 발행자가 아니라서,
    /// 등록/삭제 직후 DebugView가 refreshPalmRegistration()을 불러 갱신한다.
    @Published private(set) var hasPalmRegistered: Bool = false
    @Published private(set) var palmSampleCount: Int = 0

    // MARK: - 실시간 인식 테스트
    //
    // 이게 없으면 "등록이 제대로 됐는지" 확인하려고 매번 화면을 잠가봐야 한다.
    // 설정 창에서 바로 점수를 보여줘서 피드백 루프를 짧게 만든다.
    // 잠금 해제와 완전히 같은 대조 함수를 쓴다 — 따로 구현하면 그 구현의
    // 오차를 재게 된다.

    /// 얼굴 실시간 대조 결과. nil 이면 게이트를 통과한 프레임이 아직 없다는 뜻.
    @Published private(set) var testFaceScore: Float?
    @Published private(set) var testFaceName: String?
    /// 손금 실시간 대조 결과. nil 이면 대조 불가(등록 없음 또는 겹침 부족).
    @Published private(set) var testPalmScore: Float?

    /// 테스트 UI 가 실제로 보일 때만 계산한다. 안 보는데 매 프레임 대조할 이유가 없다.
    var isFaceTestVisible = false
    var isPalmTestVisible = false

    var testFacePasses: Bool {
        guard let s = testFaceScore else { return false }
        return s >= FaceIDConfig.unlockIdentityThreshold
    }
    var testPalmPasses: Bool {
        guard let s = testPalmScore else { return false }
        return s >= PalmConfig.matchThreshold
    }

    func resetTestScores() {
        testFaceScore = nil
        testFaceName = nil
        testPalmScore = nil
    }

    /// 카메라를 항상 켜 둘지. 끄면 잠금·등록·프리뷰 중에만 켜진다.
    /// 항상 켜면 녹색 LED 가 상시 점등하지만 인식이 0.5초 정도 빨라진다.
    @Published var cameraAlwaysOn: Bool {
        didSet {
            defaults.set(cameraAlwaysOn, forKey: Keys.cameraAlwaysOn)
            setReason(.alwaysOn, cameraAlwaysOn)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    /// 사용자 활동 후 카메라를 켜 둘 시간(초).
    ///
    /// 잠겼다고 무조건 켜 두면 자리를 비운 내내 카메라가 돌아 배터리·발열을 먹는다.
    /// 짧을수록 배터리에 좋고, 길수록 느긋하게 인식할 여유가 생긴다.
    @Published var unlockAttemptWindow: Double {
        didSet {
            defaults.set(unlockAttemptWindow, forKey: Keys.unlockAttemptWindow)
            UserPresence.attemptWindow = unlockAttemptWindow
        }
    }

    /// 지금 카메라가 켜져 있는 이유들(설정 화면 표시용).
    var activeCameraReasons: [String] {
        reasons.map { r in
            switch r {
            case .alwaysOn:    return "항상 켜기"
            case .debugWindow: return "디버그 창"
            case .faceTab:     return "얼굴 탭"
            case .palmTab:     return "손바닥 탭"
            case .enrolling:   return "등록 중"
            case .locked:      return "잠금 해제 대기"
            }
        }.sorted()
    }

    // MARK: - 보안 설정 (사용자 조정 가능, UserDefaults 에 저장)
    //
    // 전에는 FaceIDConfig 의 static var 를 뷰에서 직접 바인딩했다 — 화면에는 나왔지만
    // 저장이 안 돼서 재시작하면 조용히 기본값으로 돌아갔다. 여기서 저장까지 책임진다.

    @Published var antiSpoofEnabled: Bool {
        didSet {
            defaults.set(antiSpoofEnabled, forKey: Keys.antiSpoofEnabled)
            FaceIDConfig.antiSpoofEnabled = antiSpoofEnabled
        }
    }
    /// 실측 검증된 안전 범위: 0.40~0.60 (FAR 0%). 기본 0.48.
    @Published var unlockIdentityThreshold: Double {
        didSet {
            defaults.set(unlockIdentityThreshold, forKey: Keys.unlockIdentityThreshold)
            FaceIDConfig.unlockIdentityThreshold = Float(unlockIdentityThreshold)
        }
    }
    /// 실측 검증된 안전 범위: 0.20~0.70 (FAR 0%, 폰 화면 재생 기준). 기본 0.50.
    @Published var livenessThreshold: Double {
        didSet {
            defaults.set(livenessThreshold, forKey: Keys.livenessThreshold)
            FaceIDConfig.livenessThreshold = Float(livenessThreshold)
        }
    }
    /// 연속으로 통과해야 하는 프레임 수. 많을수록 안전하지만 해제가 느려진다.
    @Published var requiredConsecutiveFrames: Int {
        didSet {
            defaults.set(requiredConsecutiveFrames, forKey: Keys.requiredConsecutiveFrames)
            FaceIDConfig.requiredConsecutiveFrames = requiredConsecutiveFrames
        }
    }

    /// 실측으로 검증된 기본값. "기본값으로 복원" 버튼이 여기로 되돌린다.
    enum SecurityDefaults {
        static let unlockIdentityThreshold = 0.48
        static let livenessThreshold = 0.50
        static let requiredConsecutiveFrames = 3
    }

    /// 카메라를 켜 둘 이유들. 하나라도 있으면 켠다.
    /// 창별로 분리한다. 예전엔 설정창·디버그창이 같은 .window 를 공유해서,
    /// 한 창이 닫혀도 다른 창이 열려 있으면 몰라도 되는데 반대로 상태가 꼬일 수 있었다.
    enum CameraReason: Hashable { case alwaysOn, debugWindow, faceTab, palmTab, enrolling, locked }
    private var reasons: Set<CameraReason> = []

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let cameraAlwaysOn = "cameraAlwaysOn"
        static let unlockAttemptWindow = "unlockAttemptWindow"
        static let faceUnlockEnabled = "faceUnlockEnabled"
        static let palmUnlockEnabled = "palmUnlockEnabled"
        static let antiSpoofEnabled = "antiSpoofEnabled"
        static let unlockIdentityThreshold = "unlockIdentityThreshold"
        static let livenessThreshold = "livenessThreshold"
        static let requiredConsecutiveFrames = "requiredConsecutiveFrames"
    }

    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    /// unlock의 값들은 하위 객체 소유라 뷰에서 직접 바인딩할 수 없다.
    /// 코디네이터를 통해 읽고 쓰게 하고, 변경 알림은 아래에서 위로 전달한다.
    var faceUnlockEnabled: Binding<Bool> {
        Binding(get: { self.unlock.faceUnlockEnabled },
                set: { self.unlock.faceUnlockEnabled = $0 })
    }
    var palmUnlockEnabled: Binding<Bool> {
        Binding(get: { self.unlock.palmUnlockEnabled },
                set: { self.unlock.palmUnlockEnabled = $0 })
    }

    private init() {
        cameraAlwaysOn = defaults.bool(forKey: Keys.cameraAlwaysOn)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        unlockAttemptWindow = (defaults.object(forKey: Keys.unlockAttemptWindow) as? Double)
            ?? UserPresence.attemptWindow

        // 저장된 값이 있으면 쓰고, 없으면(최초 실행) FaceIDConfig 의 실측 검증된
        // 기본값을 그대로 쓴다. didSet 이 init 도중에도 확실히 반영되도록 대입
        // 직후 FaceIDConfig 에도 명시적으로 다시 써 준다.
        antiSpoofEnabled = (defaults.object(forKey: Keys.antiSpoofEnabled) as? Bool) ?? FaceIDConfig.antiSpoofEnabled
        unlockIdentityThreshold = (defaults.object(forKey: Keys.unlockIdentityThreshold) as? Double)
            ?? Double(FaceIDConfig.unlockIdentityThreshold)
        livenessThreshold = (defaults.object(forKey: Keys.livenessThreshold) as? Double)
            ?? Double(FaceIDConfig.livenessThreshold)
        requiredConsecutiveFrames = (defaults.object(forKey: Keys.requiredConsecutiveFrames) as? Int)
            ?? FaceIDConfig.requiredConsecutiveFrames
        FaceIDConfig.antiSpoofEnabled = antiSpoofEnabled
        FaceIDConfig.unlockIdentityThreshold = Float(unlockIdentityThreshold)
        FaceIDConfig.livenessThreshold = Float(livenessThreshold)
        FaceIDConfig.requiredConsecutiveFrames = requiredConsecutiveFrames

        // 프로필 로드는 키체인 복호화를 포함해 비동기로 돈다. 끝나면 알려준다.
        FaceProfileStore.shared.onProfilesChanged = { [weak self] in
            self?.refreshProfiles()
        }
        PalmProfileStore.shared.onSamplesChanged = { [weak self] in
            self?.refreshPalmRegistration()
        }
        refreshProfiles()
        refreshPalmRegistration()
        passwordIsSet = LoginPasswordStore.isSet
        hasAccessibility = UnlockService.hasAccessibilityPermission(prompt: false)

        unlock.faceUnlockEnabled = defaults.bool(forKey: Keys.faceUnlockEnabled)
        unlock.palmUnlockEnabled = defaults.bool(forKey: Keys.palmUnlockEnabled)

        // 하위 객체의 변경을 코디네이터 구독자에게 그대로 전달한다.
        unlock.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        camera.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        enrollment.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        palmEnrollment.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 프레임은 한 곳에서 받아 필요한 곳으로 나눠준다.
        camera.onFrame = { [weak self] face, aligned in
            guard let self else { return }
            self.enrollment.feed(face: face, aligned: aligned)
            self.unlock.feed(aligned: aligned)
            self.updateFaceTestScore(aligned)
        }
        // 얼굴과 OR 조건 — 둘 중 하나만 통과해도 해제된다. 손바닥 쪽엔 라이브니스가
        // 없다는 걸 UnlockService.feedPalm 안전 규칙 주석에 남겨 뒀다.
        camera.onPalmMatch = { [weak self] score in
            guard let self else { return }
            self.unlock.feedPalm(score: score)
            // 잠금 해제와 완전히 같은 점수를 그대로 화면에 보여준다.
            if self.isPalmTestVisible {
                self.testPalmScore = score
                self.logPalmTestScore(score)
            }
        }
        camera.onPalmFrame = { [weak self] palm in
            guard let self else { return }
            self.palmEnrollment.feed(palm)
            // 게이트를 못 넘긴 프레임에서는 직전 점수를 지운다. 안 그러면 손을
            // 치웠는데도 "일치"가 그대로 떠 있어 오해하게 된다.
            if self.isPalmTestVisible, !palm.passesAllGates { self.testPalmScore = nil }
        }

        // 얼굴이 프레임에서 사라지면 테스트 점수도 지운다(같은 이유).
        camera.$face
            .sink { [weak self] face in
                guard let self, self.isFaceTestVisible, face == nil else { return }
                self.testFaceScore = nil
                self.testFaceName = nil
            }
            .store(in: &cancellables)

        // 잠금 상태에 따라 카메라를 켜고 끈다. 해제될 때마다 키체인도 데워둔다.
        ScreenLockMonitor.shared.$isLocked
            .removeDuplicates()
            .sink { [weak self] locked in
                guard let self else { return }
                self.updateLockedCameraReason()
                if !locked { Self.warmKeychain() }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(unlock.$faceUnlockEnabled, unlock.$palmUnlockEnabled)
            .removeDuplicates(by: { $0 == $1 })
            .sink { [weak self] face, palm in
                guard let self else { return }
                self.defaults.set(face, forKey: Keys.faceUnlockEnabled)
                self.defaults.set(palm, forKey: Keys.palmUnlockEnabled)
                self.updateLockedCameraReason()
            }
            .store(in: &cancellables)

        // 잠겨 있다고 무조건 켜지 않는다 — 사용자가 앞에 있을 때만 켠다.
        // 이게 없으면 잠그고 자리를 비운 동안 몇 시간이고 카메라가 돌아
        // 배터리와 발열을 먹는다(UserPresence 주석 참고).
        UserPresence.shared.$isPresent
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateLockedCameraReason() }
            .store(in: &cancellables)

        enrollment.$step
            .sink { [weak self] newStep in
                guard let self else { return }
                // newStep(방금 emit된 값)으로 직접 계산한다. self.enrollment.isActive 를
                // 다시 읽으면 @Published 의 willSet 타이밍 때문에 한 단계 이전 값을 본다.
                let active = EnrollmentSession.isActive(for: newStep)
                self.camera.setEnrolling(active)
                self.setReason(.enrolling, active)
                if !active { self.refreshProfiles() }
            }
            .store(in: &cancellables)

        UserPresence.attemptWindow = unlockAttemptWindow

        // 창이 없는 게 정상 상태이므로 세션 구성은 앱 시작 시 해 둔다.
        // 이걸 빼먹으면 start() 가 구성되지 않은 세션을 켜려 해서 프레임이 한 장도 오지 않는다.
        camera.prepare()
        DiagnosticLog.write("app 시작 · 프로필 \(profileNames) · 비번 \(passwordIsSet) · 접근성 \(hasAccessibility) · 해제 \(unlock.isEnabled)")

        if cameraAlwaysOn { setReason(.alwaysOn, true) }

        // 앱을 새로 빌드해서 띄운 직후엔 이 바이너리를 처음 실행하는 것이라,
        // macOS 가 코드서명 신뢰를 처음 평가하면서 키체인 복호화가 한 번 몇 초씩
        // 걸린다(실측 5.97초, 재실행 시 0.01초로 캐시됨). 이 비용이 실제 잠금
        // 해제 순간(화면이 잠겨 있어 진행 상황을 보여줄 수 없는 때)에 처음 발생하면
        // 사용자는 아무 반응이 없다고 느끼고 직접 비밀번호를 타이핑하기 시작해서
        // 우리가 주입하는 비밀번호와 뒤섞여 로그인이 실패한다.
        // 그래서 화면이 보이는 지금(앱 시작 시점) 미리 한 번 건드려 비용을 치른다.
        Self.warmKeychain()

        // 시스템 설정에서 권한을 켜도 앱에 알림이 오지 않는다. 주기적으로 확인한다.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ax = UnlockService.hasAccessibilityPermission(prompt: false)
                if ax != self.hasAccessibility { self.hasAccessibility = ax }
            }
        }
    }

    // MARK: - 카메라 수명

    /// 잠금 해제를 위해 카메라를 켤지 다시 판단한다.
    ///
    /// 세 가지가 모두 맞아야 켠다: 화면이 잠겨 있고, 잠금 해제가 켜져 있고,
    /// 사용자가 기기 앞에 있을 가능성이 있을 것. 마지막 조건이 없으면 잠그고
    /// 자리를 비운 내내 카메라가 돈다.
    private func updateLockedCameraReason() {
        let wanted = ScreenLockMonitor.shared.isLocked
            && unlock.isEnabled
            && UserPresence.shared.isPresent
        setReason(.locked, wanted)
    }

    func setReason(_ reason: CameraReason, _ active: Bool) {
        let before = reasons.isEmpty
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        let after = reasons.isEmpty
        guard before != after else { return }
        if after {
            camera.stop()
            DiagnosticLog.write("camera 정지 (남은 이유 없음)")
        } else {
            camera.start()
            DiagnosticLog.write("camera 시작 (이유: \(reasons.map(\.self)))")
        }
    }

    // MARK: - 상태 갱신

    func refreshProfiles() {
        profileNames = FaceProfileStore.shared.profileNames
    }

    func refreshPassword() {
        passwordIsSet = LoginPasswordStore.isSet
    }

    /// 테스트 창에서 나온 점수를 로그에 남긴다.
    ///
    /// 임계값을 근거 있게 정하려면 '본인 손'과 '다른 손'의 점수 분포가 필요한데,
    /// 화면에 잠깐 떴다 사라지면 아무것도 안 남는다. 초당 한 줄로 줄여서 남긴다
    /// — 매 프레임 쓰면 로그가 다른 기록을 밀어낸다.
    private var lastPalmTestLog = Date.distantPast
    private func logPalmTestScore(_ score: Float?) {
        guard Date().timeIntervalSince(lastPalmTestLog) >= 1.0 else { return }
        lastPalmTestLog = Date()
        DiagnosticLog.write(String(format: "palm 테스트 score=%@ (임계 %.2f)",
                                   score.map { String(format: "%.4f", $0) } ?? "nil",
                                   PalmConfig.matchThreshold))
    }

    /// 얼굴 실시간 대조. UnlockService.feed 와 같은 FaceProfileStore.verify 를 쓴다.
    /// 게이트를 통과 못 한 프레임(흐림·정렬 불량)은 임베딩이 없어 nil 로 둔다 —
    /// 0점으로 표시하면 "얼굴이 안 맞는다"로 오해하게 된다.
    private func updateFaceTestScore(_ aligned: AlignedFaceResult) {
        guard isFaceTestVisible else { return }
        guard let embedding = aligned.embedding, !FaceProfileStore.shared.isEmpty else {
            testFaceScore = nil
            testFaceName = nil
            return
        }
        let result = FaceProfileStore.shared.verify(embedding)
        testFaceScore = result.score
        testFaceName = result.profileName
    }

    func refreshPalmRegistration() {
        hasPalmRegistered = !PalmProfileStore.shared.isEmpty
        palmSampleCount = PalmProfileStore.shared.sampleCount
    }

    func requestAccessibility() {
        _ = UnlockService.hasAccessibilityPermission(prompt: true)
    }

    var isReadyForFaceUnlock: Bool {
        !profileNames.isEmpty && passwordIsSet && hasAccessibility
    }
    var isReadyForPalmUnlock: Bool {
        hasPalmRegistered && passwordIsSet && hasAccessibility
    }

    func resetSecurityDefaults() {
        unlockIdentityThreshold = SecurityDefaults.unlockIdentityThreshold
        livenessThreshold = SecurityDefaults.livenessThreshold
        requiredConsecutiveFrames = SecurityDefaults.requiredConsecutiveFrames
    }

    /// 등록된 얼굴·저장된 비밀번호·잠금 해제 활성화 상태를 전부 지운다.
    /// 다른 사람에게 넘기거나 처음부터 다시 설정하고 싶을 때 쓴다.
    /// 얼굴 등록은 건드리지 않는다 — 각 프로필은 얼굴 탭에서 개별 삭제 버튼으로
    /// 이미 지울 수 있고, 여기 묶어두면 비밀번호만 초기화하려다 등록된 얼굴까지
    /// 실수로 날릴 위험이 있다(실제로 이 일이 있었다).
    func resetPasswordAndUnlock() {
        faceUnlockEnabled.wrappedValue = false
        palmUnlockEnabled.wrappedValue = false
        LoginPasswordStore.clear()
        refreshPassword()
        DiagnosticLog.write("비밀번호·잠금 설정 초기화 실행됨")
    }

    // MARK: - 키체인 워밍업

    /// 백그라운드에서 비밀번호 항목을 한 번 복호화해 둔다.
    /// 목적은 결과가 아니라 '이 시점에 비용을 치르는 것' — 화면이 보이는 지금
    /// 코드서명 신뢰 평가가 끝나 있으면, 나중에 화면이 잠긴 채로 실제 잠금 해제가
    /// 일어날 때는 이미 캐시돼 있어 즉시 통과한다(실측: 첫 실행 8.89초 → 이후 0.01초).
    ///
    /// 앱 시작 직후엔 이 함수가 두 경로(init 마지막 줄, ScreenLockMonitor 구독의
    /// 초기값 방출)에서 거의 동시에 불릴 수 있어 락으로 중복 실행을 막는다.
    private static let warmLock = NSLock()
    private static var warmed = false

    private static func warmKeychain() {
        warmLock.lock()
        guard !warmed else { warmLock.unlock(); return }
        warmed = true
        warmLock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let start = Date()
            _ = LoginPasswordStore.withPassword { _ in true }
            let elapsed = Date().timeIntervalSince(start)
            DiagnosticLog.write(String(format: "keychain 워밍업 완료 (%.2f초)", elapsed))
        }
    }

    // MARK: - 로그인 시 실행

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            DiagnosticLog.write("로그인 시 실행: \(launchAtLogin)")
        } catch {
            DiagnosticLog.write("로그인 시 실행 설정 실패: \(error.localizedDescription)")
        }
    }
}
