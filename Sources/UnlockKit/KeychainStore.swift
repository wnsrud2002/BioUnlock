//
//  KeychainStore.swift
//  Unlockface
//
//  마스터 키 보관. 얼굴 임베딩 파일은 이 키로 암호화되고, 키 자체는 파일과
//  분리해 키체인에 둔다. 파일만 복사해 가서는 복호화할 수 없어야 한다.
//
//  중요: '키가 없음'과 '키를 읽을 수 없음'을 반드시 구분해야 한다.
//  헤드리스 프로세스나 서명이 바뀐 빌드에서는 읽기가 거부(-60008 등)되는데,
//  이걸 '없음'으로 취급해 새 키를 만들면 기존 키가 덮여 프로필이 영구 소실된다.
//  (실제로 그렇게 잃었다. 그래서 이 API 는 실패 상태를 그대로 돌려준다.)
//

import Foundation
import Security

public enum KeychainStore {

    public enum LoadResult {
        case found(Data)
        case missing
        case failed(OSStatus)
    }

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "tech.unlockface.app"
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// 항목이 있는지만 본다. 데이터를 요청하지 않으므로 복호화가 일어나지 않고,
    /// 따라서 접근 승인 대화상자도 뜨지 않는다. 메인 스레드에서 불러도 안전하다.
    public static func exists(account: String) -> Bool {
        var q = query(account: account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    /// 실제 비밀값을 읽는다. 복호화를 유발하므로 승인 대화상자가 뜰 수 있다.
    /// 절대 메인 스레드에서 부르지 말 것 — UI 가 뜨기 전이면 그대로 멈춘다.
    public static func load(account: String) -> LoadResult {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return .failed(errSecInternalError) }
            return .found(data)
        case errSecItemNotFound:
            return .missing
        default:
            DiagnosticLog.write("keychain 조회 실패 account=\(account) status=\(status)")
            return .failed(status)
        }
    }

    /// 없을 때만 추가한다. 기존 항목은 절대 지우거나 덮지 않는다.
    /// 이미 있으면 errSecDuplicateItem 을 그대로 돌려준다.
    public static func add(_ data: Data, account: String) -> OSStatus {
        var q = query(account: account)
        q[kSecValueData as String] = data
        // 잠금화면에서도 동작해야 하므로 첫 잠금 해제 이후 항상 접근 가능해야 한다.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess {
            DiagnosticLog.write("keychain 추가 실패 account=\(account) status=\(status)")
        }
        return status
    }

    /// 명시적 삭제. 프로필 전체 삭제 같은 사용자 의도가 있을 때만 부른다.
    @discardableResult
    public static func delete(account: String) -> Bool {
        SecItemDelete(query(account: account) as CFDictionary) == errSecSuccess
    }
}
