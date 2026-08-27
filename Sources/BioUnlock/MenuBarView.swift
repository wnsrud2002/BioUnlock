//
//  MenuBarView.swift
//  BioUnlock
//
//  메뉴바 팝오버. 상태 확인과 켜고 끄기만 하고, 나머지는 설정 창으로 보낸다.
//

import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var app: AppCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: MenuBarIcon.name(for: app))
                    .foregroundStyle(app.unlock.isEnabled ? Color.accentColor : .secondary)
                Text("BioUnlock").font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            Toggle("얼굴로 잠금 해제", isOn: app.unlockEnabled)
                .toggleStyle(.switch)
                .disabled(!app.isReadyToUnlock)
                .font(.system(size: 12))

            if !app.isReadyToUnlock {
                VStack(alignment: .leading, spacing: 2) {
                    if app.profileNames.isEmpty { requirement("얼굴 등록 필요") }
                    if !app.passwordIsSet { requirement("로그인 비밀번호 저장 필요") }
                    if !app.hasAccessibility { requirement("접근성 권한 필요") }
                }
            }

            Divider()

            Text(statusText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            if app.unlock.isEnabled, app.unlock.lastScore > 0 {
                ProgressView(value: Double(min(1, app.unlock.lastScore)))
                    .tint(app.unlock.lastScore >= FaceIDConfig.unlockIdentityThreshold ? .green : .orange)
            }

            Divider()

            Button("설정…") { open(WindowID.settings) }
            Button("디버그 창…") { open(WindowID.debug) }
            Button("종료") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.plain)
        .padding(12)
        .frame(width: 240)
    }

    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }

    private func requirement(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
    }

    private var statusText: String {
        switch app.unlock.state {
        case .idle: return app.unlock.isEnabled ? "대기 중" : "꺼짐"
        case .waiting: return String(format: "인식 중 · %.3f", app.unlock.lastScore)
        case .matched(let s): return String(format: "일치 %.3f", s)
        case .unlocking: return "해제 중…"
        case .failed(let r): return r
        case .disabled(let r): return r
        }
    }
}

@MainActor
enum MenuBarIcon {
    static func name(for app: AppCoordinator) -> String {
        guard app.unlock.isEnabled else { return "faceid" }
        switch app.unlock.state {
        case .matched, .unlocking: return "lock.open.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "faceid"
        }
    }
}

enum WindowID {
    static let settings = "settings"
    static let debug = "debug"
}
