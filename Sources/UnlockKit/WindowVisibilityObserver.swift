//
//  WindowVisibilityObserver.swift
//  BioUnlock
//
//  SwiftUI 의 onAppear/onDisappear 는 창을 최소화해도 불리지 않는다 — 창만
//  화면에서 사라질 뿐 뷰는 여전히 마운트돼 있다. 그래서 설정/디버그 창을
//  최소화한 채로 두면 카메라 참조 이유가 계속 살아있어 카메라가 꺼지지 않는
//  버그가 있었다(실측: 20분 넘게 켜진 채 방치됨). 이 브릿지가 그 간극을 메운다.
//

import SwiftUI
import AppKit

public struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    public init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let center = NotificationCenter.default
            context.coordinator.tokens = [
                center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main) { _ in
                    onChange(false)
                },
                center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main) { _ in
                    onChange(true)
                }
            ]
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        let center = NotificationCenter.default
        coordinator.tokens.forEach { center.removeObserver($0) }
    }

    public final class Coordinator {
        var tokens: [NSObjectProtocol] = []
    }
}
