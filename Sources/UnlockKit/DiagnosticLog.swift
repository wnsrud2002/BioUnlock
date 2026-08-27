//
//  DiagnosticLog.swift
//  Unlockface
//
//  통합 로그는 필터가 걸려 누락되는 경우가 있어 파일로 직접 남긴다.
//

import Foundation

public enum DiagnosticLog {
    public static let url: URL = {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Unlockface.log")
    }()

    private static let queue = DispatchQueue(label: "tech.unlockface.log", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
