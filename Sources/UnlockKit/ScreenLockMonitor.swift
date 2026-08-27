//
//  ScreenLockMonitor.swift
//  Unlockface
//
//  화면 잠금 상태 감시.
//
//  알림(com.apple.screenIsLocked)은 '전환 시점'만 알려주고 놓칠 수 있다.
//  실제 판정은 항상 CGSessionCopyCurrentDictionary 로 다시 확인한다 —
//  비밀번호를 주입하기 직전에 이 확인이 틀리면 다른 앱에 비밀번호를 타이핑하게 된다.
//

import Foundation
import Combine
import CoreGraphics
import AppKit

public final class ScreenLockMonitor: ObservableObject {
    public static let shared = ScreenLockMonitor()

    @Published public private(set) var isLocked: Bool = false

    private var pollTimer: Timer?

    private init() {
        isLocked = Self.screenIsLocked()

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(handleLocked),
                        name: .init("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(handleUnlocked),
                        name: .init("com.apple.screenIsUnlocked"), object: nil)

        // 알림을 놓치는 경우가 있어 주기적으로도 맞춰본다.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Self.screenIsLocked()
            if now != self.isLocked {
                DispatchQueue.main.async { self.isLocked = now }
                DiagnosticLog.write("lock 상태 변화(polling) → \(now ? "잠김" : "해제")")
            }
        }
    }

    @objc private func handleLocked() {
        DispatchQueue.main.async { self.isLocked = true }
        DiagnosticLog.write("lock 알림: 잠김")
    }

    @objc private func handleUnlocked() {
        DispatchQueue.main.async { self.isLocked = false }
        DiagnosticLog.write("lock 알림: 해제")
    }

    /// 진짜 판정. 주입 직전에 반드시 이 함수로 다시 확인할 것.
    public static func screenIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}
