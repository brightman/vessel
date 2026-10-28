import Foundation

/// Errors shared by local recording storage and the whole-file transfer pipeline.
enum RecordingTransportError: Error {
    case unavailable
    case conflict
    case invalidStorage
}

enum RecordingTransportDiagnostics {
    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    static func errorCode(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain)#\(value.code)"
    }

    static func errorDescription(_ error: Error) -> String {
        if let error = error as? RecordingTransportError {
            switch error {
            case .unavailable: return "传输状态暂不可用"
            case .conflict: return "录音状态冲突"
            case .invalidStorage: return "本地录音存储无效"
            }
        }
        if let error = error as? DecodingError {
            let path: [String]
            switch error {
            case .keyNotFound(let key, let context): path = context.codingPath.map(\.stringValue) + [key.stringValue]
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath.map(\.stringValue)
            @unknown default: path = []
            }
            return "录音信息解码失败\(path.isEmpty ? "" : "（\(path.suffix(3).joined(separator: "."))）")"
        }
        return errorCode(error)
    }
}
