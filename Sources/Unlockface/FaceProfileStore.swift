//
//  FaceProfileStore.swift
//  Unlockface
//
//  등록된 얼굴 프로필의 저장·대조.
//
//  원본 이미지는 절대 저장하지 않는다. 512차원 임베딩만 남기고, 그마저도
//  ChaChaPoly 로 암호화해 디스크에 둔다. 키는 키체인에 따로 보관한다.
//

import Foundation
import CryptoKit
import UnlockKit

/// 한 포즈 버킷에서 뽑은 샘플 하나.
struct PoseSample: Codable, Equatable {
    let bucket: String
    let embedding: [Float]
    let sharpness: Float
}

/// 사용자 한 명의 프로필.
struct FaceProfile: Codable, Equatable {
    var samples: [PoseSample]
    /// 전체 샘플의 평균 임베딩. 아웃라이어 한 개로 뚫리는 것을 막는 데 쓴다.
    var centroid: [Float]
    /// 등록 당시 정면 자세의 원본값. 사용자마다 얼굴 비대칭·착석 위치가 달라
    /// 정면을 봐도 yawProxy 가 0으로 떨어지지 않는다(실측 -0.05).
    var neutralYawProxy: Double
    var neutralPitchRatio: Double
    var createdAt: Date

    var bucketsCovered: Set<String> { Set(samples.map(\.bucket)) }
}

/// 대조 결과.
struct VerificationResult {
    let score: Float
    let bestSample: Float
    let centroidScore: Float
    let profileName: String?
}

final class FaceProfileStore {
    static let shared = FaceProfileStore()

    /// 상태를 지키는 잠금. 키체인·파일 I/O 중에는 절대 잡지 않는다.
    private let stateLock = NSLock()
    private var profiles: [String: FaceProfile] = [:]

    /// 무거운 작업(키체인 복호화, 파일 I/O)을 돌리는 큐.
    /// 키체인 읽기는 승인 대화상자를 띄울 수 있어 메인 스레드에서 하면 앱이 멈춘다.
    private let ioQueue = DispatchQueue(label: "tech.unlockface.profiles.io", qos: .userInitiated)

    /// 로드·등록·삭제로 프로필이 바뀌면 메인 스레드에서 불린다.
    var onProfilesChanged: (() -> Void)?

    private(set) var isLoaded = false

    private let keyAccount = "UnlockfaceMasterKey"
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "tech.unlockface.app")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("faceprints.encrypted")
        // 초기화에서 동기 로드를 하면 키체인이 프롬프트를 띄우려다 메인 스레드가 멈춘다.
        ioQueue.async { [weak self] in self?.performLoad() }
    }

    // MARK: - 조회

    var profileNames: [String] { withState { $0.keys.sorted() } }
    var isEmpty: Bool { withState { $0.isEmpty } }

    func profile(named name: String) -> FaceProfile? { withState { $0[name] } }

    private func withState<T>(_ body: ([String: FaceProfile]) -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body(profiles)
    }

    // MARK: - 등록 / 삭제

    func register(name: String, samples: [PoseSample], neutralYawProxy: Double, neutralPitchRatio: Double) {
        let centroid = VectorMath.average(samples.map(\.embedding))
        let profile = FaceProfile(samples: samples,
                                  centroid: centroid,
                                  neutralYawProxy: neutralYawProxy,
                                  neutralPitchRatio: neutralPitchRatio,
                                  createdAt: Date())
        stateLock.lock(); profiles[name] = profile; stateLock.unlock()
        save()
        // 방금 등록한 '이 사람'의 보정값을 적용한다. 예전엔 .values.first 로
        // Dictionary 에서 아무나(순회 순서는 안정적이지 않다) 골라서, 두 번째
        // 사람을 등록해도 첫 번째 사람 기준 보정이 계속 남는 결함이 있었다.
        applyCalibration(profile)
        notifyChanged()
        DiagnosticLog.write("profile 등록 '\(name)' 샘플=\(samples.count) 버킷=\(profile.bucketsCovered.sorted())")
    }

    func delete(name: String) {
        stateLock.lock(); profiles.removeValue(forKey: name); stateLock.unlock()
        save()
        notifyChanged()
        DiagnosticLog.write("profile 삭제 '\(name)'")
    }

    func deleteAll() {
        stateLock.lock(); profiles.removeAll(); stateLock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
        KeychainStore.delete(account: keyAccount)
        notifyChanged()
        DiagnosticLog.write("profile 전체 삭제")
    }

    // MARK: - 대조

    /// 가이드라인 공식: 최고 유사도 0.85 + 중심 유사도 0.15.
    /// 최고값만 쓰면 운 좋은 샘플 하나로 뚫리고, 중심만 쓰면 포즈 변화에 약해진다.
    /// visionQueue 에서 프레임마다 불린다. 잠금 구간은 내적 몇 번뿐이라 짧다.
    func verify(_ embedding: [Float]) -> VerificationResult {
        withState { profiles in
            var best: Float = 0
            var bestCentroid: Float = 0
            var bestName: String?

            for (name, profile) in profiles {
                var localMax: Float = 0
                for sample in profile.samples {
                    let s = VectorMath.cosineSimilarity(embedding, sample.embedding)
                    if s > localMax { localMax = s }
                }
                let c = profile.centroid.isEmpty ? 0
                    : VectorMath.cosineSimilarity(embedding, profile.centroid)
                let combined = localMax * FaceIDConfig.identityMaxWeight
                    + c * FaceIDConfig.identityCentroidWeight
                let currentBest = best * FaceIDConfig.identityMaxWeight
                    + bestCentroid * FaceIDConfig.identityCentroidWeight
                if bestName == nil || combined > currentBest {
                    best = localMax
                    bestCentroid = c
                    bestName = name
                }
            }

            let score = best * FaceIDConfig.identityMaxWeight
                + bestCentroid * FaceIDConfig.identityCentroidWeight
            return VerificationResult(score: score,
                                      bestSample: best,
                                      centroidScore: bestCentroid,
                                      profileName: bestName)
        }
    }

    /// 특정 프로필의 등록 때 잰 중립값을 자세 계산에 반영한다.
    ///
    /// 이 값은 '등록 중 포즈 버킷 판정'에만 쓰이고 언락 판정(임베딩 유사도)에는
    /// 안 쓰이므로, 누구 것이 적용돼 있든 보안에는 영향이 없다. 여러 프로필 중
    /// 하나를 임의로 고르는 대신, 호출부가 '이 시점에 관련 있는 사람'(방금 등록을
    /// 마친 사람)을 명시적으로 넘기게 한다.
    func applyCalibration(_ profile: FaceProfile) {
        FaceIDConfig.yawProxyNeutral = profile.neutralYawProxy
        FaceIDConfig.pitchNeutralRatio = profile.neutralPitchRatio
        DiagnosticLog.write(String(format: "calibration 적용 yawNeutral=%+.4f pitchNeutral=%.4f",
                                   profile.neutralYawProxy, profile.neutralPitchRatio))
    }

    // MARK: - 암호화 저장

    enum KeyState: Equatable {
        case ok
        case missing
        /// 키가 있는데 읽지 못하는 상태. 절대 새 키를 만들면 안 된다.
        case unreadable(OSStatus)
    }

    private(set) var keyState: KeyState = .ok

    /// - Parameter createIfMissing: 키가 '확실히 없을 때만' 새로 만든다.
    ///   읽기 실패(권한 거부 등)에서는 무슨 일이 있어도 만들지 않는다.
    ///   그렇게 하면 기존 키를 덮어 프로필이 영구 소실된다.
    private func masterKey(createIfMissing: Bool) -> SymmetricKey? {
        switch KeychainStore.load(account: keyAccount) {
        case .found(let data):
            keyState = .ok
            return SymmetricKey(data: data)

        case .failed(let status):
            keyState = .unreadable(status)
            DiagnosticLog.write("마스터 키를 읽을 수 없음(status=\(status)). 새 키를 만들지 않고 중단한다.")
            return nil

        case .missing:
            guard createIfMissing else {
                keyState = .missing
                return nil
            }
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            let status = KeychainStore.add(data, account: keyAccount)
            guard status == errSecSuccess else {
                keyState = .unreadable(status)
                DiagnosticLog.write("치명적: 마스터 키 생성 실패 status=\(status)")
                return nil
            }
            keyState = .ok
            DiagnosticLog.write("마스터 키 신규 생성")
            return key
        }
    }

    private func notifyChanged() {
        DispatchQueue.main.async { [weak self] in self?.onProfilesChanged?() }
    }

    private func save() {
        let snapshot = withState { $0 }
        guard let key = masterKey(createIfMissing: true),
              let plain = try? JSONEncoder().encode(snapshot),
              let sealed = try? ChaChaPoly.seal(plain, using: key) else {
            DiagnosticLog.write("profile 저장 실패")
            return
        }
        do {
            try sealed.combined.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            DiagnosticLog.write("profile 파일 쓰기 실패: \(error.localizedDescription)")
        }
    }

    /// ioQueue 에서만 호출. 키체인 복호화가 포함되므로 메인 스레드에서 부르면 안 된다.
    private func performLoad() {
        defer {
            DispatchQueue.main.async { [weak self] in
                self?.isLoaded = true
                self?.onProfilesChanged?()
            }
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        // 읽기 경로에서는 절대 키를 만들지 않는다.
        guard let key = masterKey(createIfMissing: false) else {
            DiagnosticLog.write("프로필 파일은 있으나 마스터 키를 얻지 못함 — 로드 중단(파일 보존)")
            return
        }
        guard let raw = try? Data(contentsOf: fileURL),
              let box = try? ChaChaPoly.SealedBox(combined: raw),
              let plain = try? ChaChaPoly.open(box, using: key),
              let decoded = try? JSONDecoder().decode([String: FaceProfile].self, from: plain) else {
            DiagnosticLog.write("profile 복호화 실패 — 파일이 손상됐거나 키가 바뀜")
            return
        }
        stateLock.lock(); profiles = decoded; stateLock.unlock()
        DiagnosticLog.write("profile 로드 \(decoded.keys.sorted())")
        // 앱 시작 시점엔 여기서 보정값을 적용하지 않는다. 프로필이 여럿이면
        // 그중 누구 걸 고를지 알 방법이 없고(Dictionary 순회 순서는 안정적이지
        // 않다), 어차피 이 값은 오직 '등록 세션 중' 포즈 버킷 판정에만 쓰인다.
        // 다음 등록이 시작될 때 EnrollmentSession.start() 가 기본값으로
        // 리셋하므로 여기서 미리 채워둘 이유가 없다.
    }
}
