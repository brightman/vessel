import Foundation

enum NotebookPeopleError: LocalizedError {
    case conflict, invalidName
    var errorDescription:String? { switch self {
    case .conflict: return "联系人已更新，请刷新后重试。"
    case .invalidName: return "请输入联系人姓名。"
    } }
}
struct NotebookPerson: Identifiable, Sendable {
    let id:String
    let name:String
    let organization:String?
    let relationships:[String]
    let revision:Int
}
struct NotebookPersonSource: Identifiable, Sendable {
    let sourceID:UUID
    let sourceKey:String
    let speakerID:String
    let capturedAt:Date
    let start:Double?
    let end:Double?
    let needsReview:Bool
    var id:String { sourceKey+":"+speakerID }
}
enum NotebookRelationships {
    static let presets = ["家人","同事","同学","朋友","客户","路人","其他"]
    static func normalized(_ values:[String]) -> [String] {
        var seen=Set<String>()
        return values.map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty && seen.insert($0).inserted}
    }
}
