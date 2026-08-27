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

/// 등록 결과 한 벌. 코드와 정준 좌표는 반드시 함께 다녀야 한다 —
/// 다른 정준 좌표로 정렬한 코드끼리 비교하면 ROI가 서로 다른 곳을 가리켜
/// 점수가 무의미해진다.
public struct PalmProfile: Codable, Equatable {
    public let codes: [PalmCode]
    /// 이 사용자의 실측 형상으로 재추정한 정준 5점(PalmAligner.calibrated).
    public let canonical: [CGPoint]

    public init(codes: [PalmCode], canonical: [CGPoint]) {
        self.codes = codes
        self.canonical = canonical
    }
}

public final class PalmProfileStore {
    public static let shared = PalmProfileStore()

    /// 상태를 지키는 잠금. 키체인·파일 I/O 중에는 잡지 않는다.
    private let stateLock = NSLock()
    private var profile: PalmProfile?
    private var pendingCanonical: [CGPoint]?

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

    /// 지금 정렬에 써야 할 정준 좌표. 인증 경로와 등록 경로가 반드시 같은 값을
    /// 봐야 하므로 여기 한 곳에서만 정한다.
    ///
    /// 우선순위: 보정 중 임시값 > 등록된 프로필 > 기본값.
    /// 등록 2단계(코드 수집)에서는 아직 저장되지 않은 새 정준 좌표로 ROI를 잘라야
    /// 하는데, 반쪽짜리 프로필을 디스크에 쓰지 않으려고 임시값을 따로 둔다.
    public var activeCanonical: [CGPoint] {
        stateLock.lock(); defer { stateLock.unlock() }
        return pendingCanonical ?? profile?.canonical ?? PalmAligner.defaultCanonical192
    }

    /// 등록 2단계 시작 — 이 좌표로 ROI를 자르게 한다. 저장은 하지 않는다.
    public func beginCalibration(_ canonical: [CGPoint]) {
        stateLock.lock(); pendingCanonical = canonical; stateLock.unlock()
    }

    /// 등록이 끝나거나 취소되면 반드시 불러야 한다 — 안 부르면 임시값이 남아
    /// 저장된 프로필과 다른 좌표로 인증하게 된다.
    public func endCalibration() {
        stateLock.lock(); pendingCanonical = nil; stateLock.unlock()
    }

    /// 등록 결과 전체를 한 번에 교체한다. 부분 추가는 지원하지 않는다 —
    /// 정준 좌표가 바뀌면 기존 코드가 전부 무효가 되기 때문이다.
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
