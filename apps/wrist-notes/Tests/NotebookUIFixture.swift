import Foundation

/// Synthetic data. This utility accepts only the dedicated review simulator container.
@main struct NotebookUIFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Supply QA simulator container") }
        let container=URL(fileURLWithPath:CommandLine.arguments[1])
        guard container.path.contains("3898445B-1B0A-4D10-94DA-FFA88744E5C5/data/Containers/Data/") else { fatalError("Dedicated QA simulator only") }
        let db=try DaybookDatabase(url:container.appendingPathComponent("Library/Application Support/WristNotes/Database/daybook.sqlite3"))
        let repo=try FlashCaptureRepository(database:db)
        guard try repo.assets().isEmpty else { fatalError("Seed only empty QA notebook") }
        let now=Date.now
        var seeds:[FlashAsset]=[]
        for (title,text) in [("为灵感留一个出口","每天散步后留下一句话，让想法慢慢积累。"),("把会议变成下一步","讨论结束时先写下一件最小的可行动任务。"),("给生活留些空白","不必把每一分钟都排满，留一些偶遇的空间。") ] {
            let source=ActionSource(id:UUID(),title:title,quote:text,capturedAt:now,timeZoneID:"Asia/Shanghai",recordingKind:"manual",timeZoneKnown:true)
            var idea=FlashAsset(kind:.idea,title:title,text:text,source:source);idea.origin = .manual
            seeds.append(try repo.save(idea))
        }
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyy-MM-dd"
        for (title,amount,currency,direction) in [("午餐",Int64(3500),"CNY",FlashAsset.Direction.expense),("书籍",Int64(12800),"CNY",.expense),("项目收入",Int64(360000),"CNY",.income),("订阅",Int64(2000),"USD",.expense)] {
            var item=FlashAsset(kind:.expense,title:title,text:title,source:seeds[0].source,direction:direction,amountMinor:amount,currency:currency,category:"演示账目",date:f.string(from:now));item.origin = .manual;_=try repo.save(item)
        }
        let draft=NotebookIdeaDraft(seeds:Array(seeds.prefix(2)),direction:"合成候选，用于交互验证",candidates:[.init(title:"散步后的下一步",text:"散步后写下一件最想尝试的小事，给它十分钟。")])
        try NotebookIdeaRepository(database:db).save(draft)
        let people=try NotebookPeopleRepository(database:db)
        _=try people.save(id:nil,expectedRevision:nil,name:"林晓（示例）",organization:"产品团队",relationships:["同事","朋友"])
        _=try people.save(id:nil,expectedRevision:nil,name:"陈安（示例）",organization:nil,relationships:["家人"])
        let sourceID=UUID(),photoID=UUID()
        var point=CaptureLocation(latitude:31.2304,longitude:121.4737,source:.photoMetadata)!
        point.address=CaptureAddress(text:"示例地点 · 上海",localeIdentifier:"zh_CN")
        var capture=PhotoCaptureMetadata(capturedAt:now,device:"演示相机",importMethod:.library,location:point,timeZoneKnown:true)
        capture.capturedTimeZoneIdentifier="Asia/Shanghai";capture.originalLocalDate=f.string(from:now)
        try db.execute("INSERT INTO photo_moments(id,captured_at,caption,recognized_text) VALUES(?,?,?,?)",[.text(sourceID.uuidString),.real(now.timeIntervalSinceReferenceDate),.text("地点统计合成示例"),.text("")])
        try db.execute("INSERT INTO photo_attachments(id,moment_id,position,filename,recognized_text,capture) VALUES(?,?,0,?,'',?)",[.text(photoID.uuidString),.text(sourceID.uuidString),.text(photoID.uuidString+".jpg"),try DaybookDatabase.json(capture)])
        print("Notebook synthetic fixture seeded in isolated QA simulator")
    }
}
