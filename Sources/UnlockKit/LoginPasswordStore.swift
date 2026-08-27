//
//  LoginPasswordStore.swift
//  BioUnlock
//
//  macOS 로그인 비밀번호 보관.
//
//  macOS 는 서드파티가 잠금화면 인증 경로에 들어오는 것을 SIP 로 막는다.
//  그래서 이 방식은 '생체인증'이 아니라 '얼굴이 맞으면 저장해 둔 비밀번호를
//  가상 키보드로 대신 쳐 주는' 자동화다. 다음을 감수해야 성립한다:
//
//    - 앱이 로그인 비밀번호를 평문으로 복원 가능한 형태로 들고 있어야 한다.
//      Secure Enclave 가 지켜주는 구조가 아니다.
//    - 접근성 권한이 필요하다.
//
//  최소한의 방어: 저장 전에 실제 계정으로 검증하고, ChaChaPoly 로 암호화하며,
//  키는 키체인에 따로 두고, 사용 직후 메모리를 0으로 덮는다.
//

import Foundation
import CryptoKit
import OpenDirectory

public enum LoginPasswordStore {

    private static let account = "BioUnlockLoginPassword"
    private static let keyAccount = "BioUnlockPasswordKey"

    /// 데이터를 읽지 않고 존재만 확인한다(메인 스레드 안전).
    public static var isSet: Bool { KeychainStore.exists(account: account) }

    /// 실제 로그인 계정으로 비밀번호를 검증한다.
    /// 틀린 비밀번호를 저장해두면 잠금화면에서 실패 횟수만 쌓인다.
    public static func verifyAgainstAccount(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(),
                                  type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers,
                                         name: NSUserName(),
                                         attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            DiagnosticLog.write("비밀번호 검증 실패: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    public static func save(_ password: String) -> Bool {
        guard verifyAgainstAccount(password) else { return false }
        guard let key = encryptionKey(createIfMissing: true) else { return false }
        var plain = Data(password.utf8)
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard let sealed = try? ChaChaPoly.seal(plain, using: key) else { return false }
        KeychainStore.delete(account: account)
        let status = KeychainStore.add(sealed.combined, account: account)
        DiagnosticLog.write(status == errSecSuccess ? "로그인 비밀번호 저장됨" : "비밀번호 저장 실패 \(status)")
        return status == errSecSuccess
    }

    public static func clear() {
        KeychainStore.delete(account: account)
        DiagnosticLog.write("로그인 비밀번호 삭제됨")
    }

    /// 복호화한 비밀번호를 클로저 안에서만 쓰게 하고, 나올 때 메모리를 덮는다.
    public static func withPassword<T>(_ body: (String) -> T) -> T? {
        guard case .found(let blob) = KeychainStore.load(account: account),
              let key = encryptionKey(createIfMissing: false),
              let box = try? ChaChaPoly.SealedBox(combined: blob),
              var plain = try? ChaChaPoly.open(box, using: key) else { return nil }
        defer { plain.resetBytes(in: 0..<plain.count) }
        guard let text = String(data: plain, encoding: .utf8) else { return nil }
        return body(text)
    }

    private static func encryptionKey(createIfMissing: Bool) -> SymmetricKey? {
        switch KeychainStore.load(account: keyAccount) {
        case .found(let data):
            return SymmetricKey(data: data)
        case .failed(let status):
            // 읽기 실패에서 새 키를 만들면 기존 비밀번호를 못 풀게 된다.
            DiagnosticLog.write("비밀번호 키를 읽을 수 없음 status=\(status)")
            return nil
        case .missing:
            guard createIfMissing else { return nil }
            let key = SymmetricKey(size: .bits256)
            let data = key.withUnsafeBytes { Data($0) }
            guard KeychainStore.add(data, account: keyAccount) == errSecSuccess else { return nil }
            return key
        }
    }
}
