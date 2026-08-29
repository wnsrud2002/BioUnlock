//
//  PalmProfileStore.swift
//  Unlockpalm
//
//  등록된 손바닥 샘플들을 들고 있다가 대조 요청에 응답한다.
//
//  샘플이 여러 장인 이유(FaceProfileStore와 같은 논리): 참조가 한 장뿐이면 등록
//  당시의 각도·거리에서 조금만 벗어나도 점수가 무너진다. 실측(2026-08-28)에서
//  같은 손인데도 0.57~0.84로 출렁였고 10번 중 1번만 잠금이 풀렸다. 여러 장 중
//  '가장 잘 맞는 것'을 쓰면 그 출렁임의 아래쪽 꼬리가 올라간다.
//
//  얼굴과 다른 점 하나: 얼굴은 최고값 0.85 + 중심 0.15로 섞지만 손바닥은 최고값만
//  쓴다. CompCode는 방향 인덱스(0…5)라 코드끼리 평균을 내면 '중간 방향'이라는
//  엉뚱한 값이 나온다 — 임베딩 벡터처럼 평균낼 수 있는 표현이 아니다.
//

import Foundation
import CoreGraphics
import CryptoKit
import UnlockKit

/// 등록 결과 한 벌.
///
/// 초근접 경로로 바꾸면서 정준 좌표(canonical)가 사라졌다. 랜드마크로 정렬할
/// 때는 그 좌표가 코드와 짝을 이뤄야 했지만, 초근접은 화면 중앙을 그대로 쓰고
/// 회전만 이미지 자체에서 정규화하므로 코드 외에 따로 들고 다닐 게 없다.
public struct PalmProfile: Codable, Equatable {
    public let codes: [PalmCode]

    public init(codes: [PalmCode]) {
        self.codes = codes
    }
}

public final class PalmProfileStore {
    public static let shared = PalmProfileStore()

    /// 상태를 지키는 잠금. 키체인·파일 I/O 중에는 잡지 않는다.
    private let stateLock = NSLock()
    private var profile: PalmProfile?

    private let ioQueue = DispatchQueue(label: "tech.biounlock.palm.io", qos: .userInitiated)
    private let keyAccount = "BioUnlockPalmKey"
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "tech.biounlock.app")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("palmprints.encrypted")
        // 키체인 복호화가 메인 스레드를 막지 않도록 비동기로 읽는다(FaceProfileStore와 동일).
        ioQueue.async { [weak self] in self?.performLoad() }
    }

    /// 로드·등록·삭제로 샘플이 바뀌면 메인 스레드에서 불린다.
    public var onSamplesChanged: (() -> Void)?

    public var isEmpty: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return profile == nil
    }

    public var sampleCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return profile?.codes.count ?? 0
    }

    /// 등록 결과 전체를 한 번에 교체한다. 부분 추가는 지원하지 않는다 —
    /// 등록 세션이 통째로 다시 도는 편이 언제 찍힌 샘플인지 추적하기 쉽다.
    public func register(_ newProfile: PalmProfile) {
        stateLock.lock(); profile = newProfile; stateLock.unlock()
        save()
        notifyChanged()
    }

    public func clear() {
        stateLock.lock(); profile = nil; stateLock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
        KeychainStore.delete(account: keyAccount)
        notifyChanged()
    }

    /// 등록된 샘플이 없으면 nil(= 대조 불가, fail-closed로 이어져야 한다).
    /// 있으면 샘플들 중 최고 점수. 개별 비교가 전부 nil(겹침 부족)이어도 nil.
    public func verify(_ candidate: PalmCode) -> Float? {
        stateLock.lock(); let refs = profile?.codes ?? []; stateLock.unlock()
        guard !refs.isEmpty else { return nil }
        return refs.compactMap { PalmMatcher.score($0, candidate) }.max()
    }

    // MARK: - 암호화 저장

    private func notifyChanged() {
        DispatchQueue.main.async { [weak self] in self?.onSamplesChanged?() }
    }

    /// - Parameter createIfMissing: 키가 '확실히 없을 때만' 새로 만든다.
    ///   읽기 실패(권한 거부 등)에서 새 키를 만들면 기존 데이터를 영영 못 푼다
    ///   — FaceProfileStore가 실제로 그렇게 프로필을 잃은 적이 있어 같은 규칙을 지킨다.
    private func masterKey(createIfMissing: Bool) -> SymmetricKey? {
        switch KeychainStore.load(account: keyAccount) {
        case .found(let data):
            return SymmetricKey(data: data)
        case .failed(let status):
            DiagnosticLog.write("palm 키를 읽을 수 없음 status=\(status) — 새 키를 만들지 않고 중단")
            return nil
        case .missing:
            guard createIfMissing else { return nil }
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            guard KeychainStore.add(data, account: keyAccount) == errSecSuccess else { return nil }
            return key
        }
    }

    private func save() {
        let snapshot = { stateLock.lock(); defer { stateLock.unlock() }; return profile }()
        guard let snapshot else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard let key = self.masterKey(createIfMissing: true),
                  let plain = try? JSONEncoder().encode(snapshot),
                  let sealed = try? ChaChaPoly.seal(plain, using: key) else {
                DiagnosticLog.write("palm 저장 실패")
                return
            }
            do {
                try sealed.combined.write(to: self.fileURL, options: [.atomic, .completeFileProtection])
                DiagnosticLog.write("palm 저장됨 (샘플 \(snapshot.codes.count))")
            } catch {
                DiagnosticLog.write("palm 파일 쓰기 실패: \(error.localizedDescription)")
            }
        }
    }

    /// ioQueue 에서만 호출. 키체인 복호화가 포함되므로 메인 스레드에서 부르면 안 된다.
    private func performLoad() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        // 읽기 경로에서는 절대 키를 만들지 않는다.
        guard let key = masterKey(createIfMissing: false) else { return }
        guard let raw = try? Data(contentsOf: fileURL),
              let box = try? ChaChaPoly.SealedBox(combined: raw),
              let plain = try? ChaChaPoly.open(box, using: key),
              let decoded = try? JSONDecoder().decode(PalmProfile.self, from: plain) else {
            // 스키마가 바뀌면(예: 정준 좌표 도입 전 파일) 여기로 온다. 옛 코드는
            // 새 정준 좌표와 짝이 안 맞아 어차피 못 쓰므로 재등록을 유도한다.
            DiagnosticLog.write("palm 복호화/디코딩 실패 — 재등록이 필요하다")
            return
        }
        stateLock.lock(); profile = decoded; stateLock.unlock()
        DiagnosticLog.write("palm 로드 완료 (샘플 \(decoded.codes.count))")
        notifyChanged()
    }
}
