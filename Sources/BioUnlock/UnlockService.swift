//
//  UnlockService.swift
//  BioUnlock
//
//  잠금 감지 → 얼굴 인식 → 비밀번호 주입.
//
//  안전 규칙 (하나라도 어기면 엉뚱한 앱에 비밀번호를 타이핑하게 된다):
//    1. 주입 직전에 CGSession 으로 잠금 상태를 '다시' 확인한다.
//    2. 시도마다 UUID 를 붙여, 그 사이 상태가 바뀌면 낡은 시도를 무효화한다.
//    3. 재시도는 1회까지. 무한 재시도는 계정 잠김을 부른다.
//    4. 비밀번호 문자열과 버퍼는 사용 직후 0으로 덮는다.
//

import Foundation
import Combine
import CoreGraphics
import ApplicationServices
import IOKit.pwr_mgt
import AppKit
import UnlockKit
import Unlockpalm

@MainActor
final class UnlockService: ObservableObject {

    enum State: Equatable {
        case idle                 // 화면이 켜져 있음
        case waiting              // 잠김, 얼굴 찾는 중
        case matched(Float)       // 연속 통과, 주입 예정
        case unlocking
        case failed(String)
        case disabled(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var consecutive: Int = 0
    @Published private(set) var lastScore: Float = 0
    @Published private(set) var lastLiveness: Float = 0
    @Published private(set) var rejectedAsSpoof: Bool = false
    /// 얼굴과는 별도의 연속 프레임 카운터. 둘 중 하나만 통과해도(OR) 해제된다.
    @Published private(set) var palmConsecutive: Int = 0
    @Published private(set) var lastPalmScore: Float = 0

    /// 얼굴/손바닥을 독립적으로 켜고 끌 수 있다 — 손바닥은 라이브니스가 없어서
    /// 얼굴만 켜고 손바닥은 꺼 두고 싶을 수 있다(그 반대도 마찬가지).
    @Published var faceUnlockEnabled: Bool = false {
        didSet { if !isEnabled { reset() } }
    }
    @Published var palmUnlockEnabled: Bool = false {
        didSet { if !isEnabled { reset() } }
    }
    /// 둘 중 하나라도 켜져 있는지 — 잠금 감지·카메라 수명 관리 등 공통 로직에서만 쓴다.
    /// 실제 인식 게이트는 feed(aligned:)/feedPalm(score:)에서 각자의 플래그를 본다.
    var isEnabled: Bool { faceUnlockEnabled || palmUnlockEnabled }

    private var attemptID = UUID()
    private var injecting = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        ScreenLockMonitor.shared.$isLocked
            .removeDuplicates()
            .sink { [weak self] locked in self?.handleLockChange(locked) }
            .store(in: &cancellables)
    }

    // MARK: - 권한

    @discardableResult
    static func hasAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: - 상태 전이

    private func handleLockChange(_ locked: Bool) {
        guard isEnabled else { state = .disabled("꺼짐"); return }
        if locked {
            consecutive = 0
            palmConsecutive = 0
            attemptID = UUID()
            state = .waiting
            DiagnosticLog.write("unlock: 화면 잠김 — 인식 시작")
        } else {
            reset()
            DiagnosticLog.write("unlock: 화면 해제됨")
        }
    }

    private func reset() {
        consecutive = 0
        palmConsecutive = 0
        rejectedAsSpoof = false
        injecting = false
        attemptID = UUID()
        state = ScreenLockMonitor.shared.isLocked ? .waiting : .idle
    }

    // MARK: - 프레임 입력

    func feed(aligned: AlignedFaceResult) {
        guard faceUnlockEnabled, !injecting, case .waiting = state else { return }
        guard ScreenLockMonitor.shared.isLocked else { return }
        guard let embedding = aligned.embedding else { consecutive = 0; return }

        let result = FaceProfileStore.shared.verify(embedding)
        lastScore = result.score

        // 신원이 맞아도 실물이 아니면 통과시키지 않는다.
        // 순서가 중요하다 — 사진은 신원 점수를 통과하므로 여기서 막아야 한다.
        if FaceIDConfig.antiSpoofEnabled {
            guard let spoof = aligned.spoof else {
                // 판정을 못 했으면 통과시키지 않는다(fail-closed).
                consecutive = 0
                return
            }
            lastLiveness = spoof.smoothScore
            guard spoof.isReal else {
                rejectedAsSpoof = true
                consecutive = 0
                return
            }
            rejectedAsSpoof = false
        }

        guard result.score >= FaceIDConfig.unlockIdentityThreshold else {
            consecutive = 0
            return
        }

        consecutive += 1
        guard consecutive >= FaceIDConfig.requiredConsecutiveFrames else { return }

        state = .matched(result.score)
        DiagnosticLog.write(String(format: "unlock: 인식 성공 score=%.4f live=%.4f name=%@ (연속 %d프레임)",
                                   result.score, lastLiveness, result.profileName ?? "-", consecutive))
        beginUnlock()
    }

    /// 손바닥 대조 결과를 받는다. score가 nil이면(등록 안 됨/유효 픽셀 부족 등)
    /// 판정을 못 한 것이므로 통과시키지 않는다(fail-closed).
    ///
    /// 경고: 손바닥 쪽에는 아직 라이브니스(사진·화면 재생 방어)가 전혀 없다.
    /// 얼굴은 AntiSpoofDetector가 막지만 손바닥은 코드가 맞으면 그대로 통과한다.
    /// 등록해야만 켜지는 기능이라 기본 상태에선 위험이 없지만, 등록한 순간부터는
    /// 그 손바닥 사진 한 장으로도 뚫릴 수 있다는 뜻이다.
    func feedPalm(score: Float?) {
        guard palmUnlockEnabled, !injecting, case .waiting = state else { return }
        guard ScreenLockMonitor.shared.isLocked else { return }
        guard let score else { palmConsecutive = 0; return }
        lastPalmScore = score

        guard score >= PalmConfig.matchThreshold else {
            palmConsecutive = 0
            return
        }

        palmConsecutive += 1
        guard palmConsecutive >= PalmConfig.requiredConsecutiveFrames else { return }

        state = .matched(score)
        DiagnosticLog.write(String(
            format: "unlock: 손바닥 인식 성공 score=%.4f (연속 %d프레임, 라이브니스 없음)",
            score, palmConsecutive))
        beginUnlock()
    }

    // MARK: - 주입

    private func beginUnlock() {
        guard !injecting else { return }
        injecting = true

        guard LoginPasswordStore.isSet else {
            state = .failed("비밀번호가 저장되지 않음")
            injecting = false
            return
        }
        guard Self.hasAccessibilityPermission(prompt: true) else {
            state = .failed("접근성 권한 필요 — 시스템 설정 > 개인정보 보호와 보안 > 손쉬운 사용")
            injecting = false
            return
        }

        state = .unlocking
        let id = UUID()
        attemptID = id
        wakeDisplay()

        // 디스플레이가 깨어나 잠금화면이 키 입력을 받을 준비가 될 시간을 준다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.inject(attempt: 1, id: id)
        }
    }

    private func inject(attempt: Int, id: UUID) {
        // 안전 규칙 1·2: 낡은 시도 무효화 + 잠금 상태 재확인.
        guard attemptID == id, isEnabled else { injecting = false; return }
        // 캐시된 플래그가 아니라 지금 이 순간의 세션 상태로 판정한다.
        guard ScreenLockMonitor.screenIsLocked() else {
            DiagnosticLog.write("unlock: 주입 직전 잠금이 풀려 취소")
            injecting = false
            state = .idle
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            state = .failed("이벤트 소스를 만들 수 없음")
            injecting = false
            return
        }

        // virtualKey 51 = Delete. 뚜껑을 열 때 눌린 잔여 문자를 지운다.
        // 필드가 비어 있으면 백스페이스는 아무 일도 하지 않으니 항상 보내도 안전하다.
        for _ in 0..<FaceIDConfig.unlockClearKeystrokes {
            CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)?.post(tap: .cghidEventTap)
        }

        let posted = LoginPasswordStore.withPassword { password -> Bool in
            var chars = Array(password.utf16)
            defer { for i in chars.indices { chars[i] = 0 } }

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

            // virtualKey 36 = Return
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
            return true
        } ?? false

        guard posted else {
            state = .failed("비밀번호를 복호화하지 못함")
            injecting = false
            return
        }
        DiagnosticLog.write("unlock: 비밀번호 주입 (시도 \(attempt))")

        // 안전 규칙 3: 재시도 1회까지.
        DispatchQueue.main.asyncAfter(deadline: .now() + FaceIDConfig.unlockRetryDelay) { [weak self] in
            guard let self, self.attemptID == id else { return }
            if ScreenLockMonitor.screenIsLocked() {
                if attempt < FaceIDConfig.unlockMaxAttempts {
                    DiagnosticLog.write("unlock: 아직 잠김 — 재시도")
                    self.inject(attempt: attempt + 1, id: id)
                } else {
                    DiagnosticLog.write("unlock: 실패 — 재시도 한도 도달")
                    self.state = .failed("해제되지 않음. 비밀번호를 다시 저장해 보세요")
                    self.injecting = false
                    self.consecutive = 0
                    self.palmConsecutive = 0
                }
            } else {
                DiagnosticLog.write("unlock: 성공")
                self.injecting = false
                self.state = .idle
            }
        }
    }

    /// 디스플레이가 꺼져 있으면 키 입력이 잠금화면에 닿지 않는다.
    private func wakeDisplay() {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("BioUnlock face match" as CFString,
                                         kIOPMUserActiveLocal,
                                         &assertion)
    }
}
