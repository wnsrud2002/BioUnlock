//
//  BioUnlockApp.swift
//  BioUnlock
//
//  메뉴바 상주 앱. 창은 있어도 되고 없어도 되며, 인식 로직은 AppCoordinator 가 소유한다.
//

import SwiftUI
import UnlockKit

@main
struct BioUnlockApp: App {
    @StateObject private var app = AppCoordinator.shared

    init() {
        // GUI 를 띄우기 전에 일괄 모드를 가로챈다.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--batch"), args.count > i + 2 {
            exit(BatchEmbedder.run(inputDir: args[i + 1], outputPath: args[i + 2]))
        }
        if let i = args.firstIndex(of: "--spoof"), args.count > i + 1 {
            exit(BatchEmbedder.spoofCheck(inputDir: args[i + 1]))
        }
        if let i = args.firstIndex(of: "--score"), args.count > i + 2 {
            exit(BatchEmbedder.score(embeddingsPath: args[i + 1], outputPath: args[i + 2]))
        }
        if args.contains("--test-keychain") {
            exit(Self.testKeychain())
        }
        if let i = args.firstIndex(of: "--self-test"), args.count > i + 1 {
            let dir = args[i + 1]
            let pngs = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix("_raw.png") }
                .sorted()
                .map { (dir as NSString).appendingPathComponent($0) }
            EmbedderSelfTest.run(paths: pngs)
            exit(0)
        }
    }

    /// 진단용: 잠금 해제가 실제로 건드리는 키체인 항목 3개를 지금 이 프로세스의
    /// 서명으로 읽어본다. 프롬프트 없이 통과하면 ACL 신뢰가 정상, 막히면(타임아웃)
    /// 그 항목의 "항상 허용"이 아직 안 걸려 있다는 뜻이다.
    private static func testKeychain() -> Int32 {
        func timed(_ label: String, _ body: () -> Bool) {
            let start = Date()
            let ok = body()
            let elapsed = Date().timeIntervalSince(start)
            print("\(label): \(ok ? "성공" : "실패") (\(String(format: "%.2f", elapsed))초)")
        }
        timed("BioUnlockLoginPassword 복호화") {
            LoginPasswordStore.withPassword { _ in true } ?? false
        }
        timed("BioUnlockMasterKey 조회(존재확인)") {
            KeychainStore.exists(account: "BioUnlockMasterKey")
        }
        return 0
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(app: app)
        } label: {
            Image(systemName: MenuBarIcon.name(for: app))
        }
        .menuBarExtraStyle(.window)

        Window("BioUnlock 설정", id: WindowID.settings) {
            SettingsView(app: app)
        }
        .windowResizability(.contentSize)

        Window("BioUnlock 디버그", id: WindowID.debug) {
            DebugView(app: app)
        }
        .windowResizability(.contentMinSize)
    }
}
