//
//  UserPresence.swift
//  UnlockKit
//
//  "지금 사용자가 기기 앞에 있을 가능성이 있는가" — 카메라를 켤지 판단하는 신호.
//
//  왜 필요한가
//  ----------
//  화면이 잠긴 내내 카메라를 켜 두고 있었다. 잠그고 자리를 비우면 몇 시간이고
//  계속 돌면서 배터리를 먹고 발열이 생긴다(게다가 녹색 LED 가 상시 점등한다).
//  실제로 잠금 해제가 일어나는 건 사용자가 돌아온 직후 몇 초뿐이므로, 그 순간에만
//  켜면 된다. Face ID·Windows Hello 도 같은 방식이다.
//
//  무엇을 신호로 쓰나
//  ------------------
//    1) 디스플레이 잠자기 — 화면이 꺼져 있으면 사용자는 확실히 앞에 없다.
//       뚜껑을 닫아도 여기로 잡힌다.
//    2) 마지막 입력 이후 경과 시간 — 잠금화면에서도 HID 이벤트는 시스템에
//       기록되므로 앱이 이벤트를 가로채지 않고도 알 수 있다.
//    3) 디스플레이가 깨어난 순간 — 뚜껑을 열면 화면은 켜지지만 키·트랙패드
//       입력은 없을 수 있다. 이걸 따로 잡지 않으면 이 앱의 대표 사용 시나리오
//       ("뚜껑 열면 인식")가 깨진다.
//

import Foundation
import CoreGraphics
import AppKit

public final class UserPresence: ObservableObject {
    public static let shared = UserPresence()

    /// 디스플레이가 깨어 있고, 최근에 사용자 활동(입력 또는 화면 깨어남)이 있었는가.
    @Published public private(set) var isPresent: Bool = false

    /// 활동 후 이 시간까지만 '앞에 있다'로 본다. 지나면 카메라를 끄고, 다음 활동에
    /// 다시 켠다. 짧으면 배터리에 좋고, 길면 느긋하게 인식된다.
    public static var attemptWindow: TimeInterval = 30

    /// 잠금 해제를 기다리는 중인가. 이때만 촘촘히 살피고 App Nap 도 막는다.
    private var isAlert = false
    private var activityToken: NSObjectProtocol?

    private var timer: Timer?
    private var wasDisplayAsleep = false
    private var lastWakeAt: Date?

    /// 화면이 잠기고 잠금 해제가 켜져 있는 동안 true 로 둔다.
    ///
    /// 두 가지를 바꾼다:
    ///   - 폴링 간격을 촘촘하게(트랙패드를 건드린 뒤 바로 켜지도록)
    ///   - App Nap 을 막는다. 카메라가 꺼지고 창도 없으면 macOS 가 이 앱을 절전
    ///     상태로 돌리는데, 그러면 타이머가 수 초~수십 초로 늘어져 "트랙패드를
    ///     건드려도 한참 뒤에 켜지는" 문제가 생긴다. 시스템 잠자기는 그대로
    ///     허용하는 옵션이라(AllowingIdleSystemSleep) 맥이 자는 걸 막지는 않는다.
    public func setAlert(_ alert: Bool) {
        guard alert != isAlert else { return }
        isAlert = alert
        startTimer()

        if alert {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "잠금 해제 대기 — 사용자 활동 감지")
        } else if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        DiagnosticLog.write("presence 감시 \(alert ? "촘촘히(App Nap 차단)" : "느슨하게")")
    }

    private func startTimer() {
        timer?.invalidate()
        let interval: TimeInterval = isAlert ? 0.4 : 2.0
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        // 기본 모드에만 넣으면 메뉴 추적 같은 상황에서 멈춘다.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private init() {
        wasDisplayAsleep = Self.isDisplayAsleep
        // 뚜껑을 열자마자 반응하도록 알림도 같이 받는다. 1초 폴링만으로는
        // 최대 1초가 밀리는데, 그 사이 사용자는 이미 화면을 보고 있다.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleScreensWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil)

        startTimer()
        evaluate()
    }

    @objc private func handleScreensWake() {
        lastWakeAt = Date()
        evaluate()
    }

    private func evaluate() {
        let asleep = Self.isDisplayAsleep
        // 폴링으로도 깨어남 전환을 잡는다(알림을 놓치는 경우 대비).
        if wasDisplayAsleep && !asleep { lastWakeAt = Date() }
        wasDisplayAsleep = asleep

        let sinceWake = lastWakeAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let sinceInput = Self.secondsSinceUserInput
        let recent = min(sinceWake, sinceInput) <= Self.attemptWindow
        let present = !asleep && recent

        guard present != isPresent else { return }
        isPresent = present
        DiagnosticLog.write(String(
            format: "presence %@ (디스플레이 %@, 마지막입력 %.0f초 전, 깨어난지 %@)",
            present ? "있음" : "없음",
            asleep ? "꺼짐" : "켜짐",
            sinceInput,
            sinceWake == .greatestFiniteMagnitude ? "-" : String(format: "%.0f초", sinceWake)))
    }

    // MARK: - 시스템 상태

    public static var isDisplayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// 마지막 사용자 입력 이후 경과 시간. 잠금화면에서도 동작한다 —
    /// 이벤트 탭을 걸지 않고 시스템이 이미 기록한 값을 읽는 것이라 권한도 필요 없다.
    public static var secondsSinceUserInput: TimeInterval {
        // ~0 은 '아무 입력이나'를 뜻하는 kCGAnyInputEventType.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}
