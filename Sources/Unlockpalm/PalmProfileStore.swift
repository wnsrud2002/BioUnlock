//
//  PalmProfileStore.swift
//  Unlockpalm
//
//  등록된 손바닥 코드 하나를 들고 있다가 대조 요청에 응답한다.
//
//  FaceProfileStore와 이름은 대칭이지만 지금은 훨씬 못하다 — 세션 메모리에만
//  있고(앱을 끄면 사라짐), 암호화도 디스크 저장도 없다. 여러 프로필도 아직
//  못 다룬다(등록하면 이전 것을 덮어쓴다). "일단 잠금해제가 되는지" 보려는
//  단계라 FaceProfileStore 수준의 안전장치(ChaChaPoly 암호화, 키체인 분리
//  보관, 원자적 파일 쓰기)는 전부 나중 몫이다.
//

import Foundation

public final class PalmProfileStore {
    public static let shared = PalmProfileStore()

    private let lock = NSLock()
    private var registered: PalmCode?

    private init() {}

    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return registered == nil
    }

    public func register(_ code: PalmCode) {
        lock.lock(); registered = code; lock.unlock()
    }

    public func clear() {
        lock.lock(); registered = nil; lock.unlock()
    }

    /// 등록된 코드가 없으면 nil(= 대조 불가, fail-closed로 이어져야 한다).
    public func verify(_ candidate: PalmCode) -> Float? {
        lock.lock(); let ref = registered; lock.unlock()
        guard let ref else { return nil }
        return PalmMatcher.score(ref, candidate)
    }
}
