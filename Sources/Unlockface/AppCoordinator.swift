//
//  AppCoordinator.swift
//  Unlockface
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

@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    let camera = CameraController()
    let enrollment = EnrollmentSession()
    let unlock = UnlockService()

    @Published private(set) var profileNames: [String] = []
    @Published private(set) var passwordIsSet: Bool = false
    @Published private(set) var hasAccessibility: Bool = false

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
    enum CameraReason: Hashable { case alwaysOn, debugWindow, faceTab, enrolling, locked }
    private var reasons: Set<CameraReason> = []

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let cameraAlwaysOn = "cameraAlwaysOn"
        static let unlockEnabled = "unlockEnabled"
        static let antiSpoofEnabled = "antiSpoofEnabled"
        static let unlockIdentityThreshold = "unlockIdentityThreshold"
        static let livenessThreshold = "livenessThreshold"
        static let requiredConsecutiveFrames = "requiredConsecutiveFrames"
    }

    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    /// unlock.isEnabled 는 하위 객체의 값이라 뷰에서 직접 바인딩할 수 없다.
    /// 코디네이터를 통해 읽고 쓰게 하고, 변경 알림은 아래에서 위로 전달한다.
    var unlockEnabled: Binding<Bool> {
        Binding(get: { self.unlock.isEnabled },
                set: { self.unlock.isEnabled = $0 })
    }

    private init() {
        cameraAlwaysOn = defaults.bool(forKey: Keys.cameraAlwaysOn)
        launchAtLogin = SMAppService.mainApp.status == .enabled

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
        refreshProfiles()
        passwordIsSet = LoginPasswordStore.isSet
        hasAccessibility = UnlockService.hasAccessibilityPermission(prompt: false)

        unlock.isEnabled = defaults.bool(forKey: Keys.unlockEnabled)

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

        // 프레임은 한 곳에서 받아 필요한 곳으로 나눠준다.
        camera.onFrame = { [weak self] face, aligned in
            guard let self else { return }
            self.enrollment.feed(face: face, aligned: aligned)
            self.unlock.feed(aligned: aligned)
        }

        // 잠금 상태에 따라 카메라를 켜고 끈다. 해제될 때마다 키체인도 데워둔다.
        ScreenLockMonitor.shared.$isLocked
            .removeDuplicates()
            .sink { [weak self] locked in
                guard let self else { return }
                self.setReason(.locked, locked && self.unlock.isEnabled)
                if !locked { Self.warmKeychain() }
            }
            .store(in: &cancellables)

        unlock.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                self.defaults.set(enabled, forKey: Keys.unlockEnabled)
                self.setReason(.locked, enabled && ScreenLockMonitor.shared.isLocked)
            }
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

    func requestAccessibility() {
        _ = UnlockService.hasAccessibilityPermission(prompt: true)
    }

    var isReadyToUnlock: Bool {
        !profileNames.isEmpty && passwordIsSet && hasAccessibility
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
        unlockEnabled.wrappedValue = false
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
