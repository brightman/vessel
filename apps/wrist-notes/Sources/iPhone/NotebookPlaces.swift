import Foundation

struct NotebookPlaceEvidence:Sendable {
    let id:String
    let sourceID:UUID
    let sourceKind:String
    let capturedAt:Date
    let timeZoneIdentifier:String?
    let location:CaptureLocation
    var originalLocalDate:String? = nil
}
struct NotebookPlace:Identifiable,Sendable {
    let id:String
    let name:String
    let type:String?
    let days:Int
    let revision:Int
    var coordinateHint:String? = nil
}
struct NotebookPlaceVisit:Identifiable,Sendable {
    let id:String
    let sourceID:UUID
    let sourceKind:String
    let capturedAt:Date
    let day:String
    let dateBasis:String
    let timeZoneIdentifier:String
}
enum NotebookPlaceGrid {
    /// Fixed 0.001-degree cells (~111m north/south). Addresses never participate in identity.
    static func id(_ location:CaptureLocation)->String {
        "grid-v1:\(Int(floor(location.latitude*1000))):\(Int(floor(location.longitude*1000)))"
    }
    static let types=["家","公司","学校","商场","其他"]
    static func day(_ date:Date,zone:String)->String {
        let formatter=DateFormatter();formatter.calendar=Calendar(identifier:.gregorian)
        formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(identifier:zone) ?? TimeZone(secondsFromGMT:0)!
        formatter.dateFormat="yyyy-MM-dd";return formatter.string(from:date)
    }
    static func validDay(_ day:String)->Bool {
        let formatter=DateFormatter();formatter.calendar=Calendar(identifier:.gregorian);formatter.locale=Locale(identifier:"en_US_POSIX")
        formatter.timeZone=TimeZone(secondsFromGMT:0)!;formatter.dateFormat="yyyy-MM-dd";formatter.isLenient=false
        guard let date=formatter.date(from:day) else { return false };return self.day(date,zone:"UTC")==day
    }
}
enum NotebookPlacesError:LocalizedError {
    case conflict, invalidEvidence
    var errorDescription:String? {
        switch self {
        case .conflict: return "地点名称已更新，请刷新后重试。"
        case .invalidEvidence: return "地点来源信息不一致，请刷新后重试。"
        }
    }
}
