import Foundation

@main struct DaybookPlacesSmoke {
    static func main() throws {
        let date = Calendar.current.startOfDay(for: .now).addingTimeInterval(100)
        var note = VoiceNote(id: UUID(), kind: .long, capturedAt: date, duration: 20)
        note.transcript = "测试原文"
        let point = CaptureLocation(latitude: 31.2345, longitude: 121.5432, measuredAt: date, source: .watchRecording)!
        precondition(DaybookPlaces.records(notes: [note], photos: []).isEmpty)
        note.location = point
        note.origin = RecordingOrigin(device: "Apple Watch", deviceID: "", fileName: "", recordingTimeIsEstimated: false)
        let audio = DaybookPlaces.voice(note)
        let places = DaybookPlaces.records(notes: [note], photos: [])
        precondition(places.count == 1 && places[0].parentRecordID == note.id && places[0].capturedAt == date)
        precondition(audio.captureDevice == "Apple Watch" && audio.text == "测试原文")
        let unresolvedSummary = DaybookPlaces.homeSummary(places)
        precondition(unresolvedSummary.placeCount == 1 && unresolvedSummary.recordCount == 1)
        precondition(unresolvedSummary.labels.isEmpty, "raw coordinates must not be exposed as home place names")
        let retrieval = DaybookRetrieval()
        let privateScope = try retrieval.prepare(question: "总结这一天", records: [audio] + places, selectedDate: date, allowedKinds: [.voice])
        precondition(!privateScope.context.contains("31.2345") && !privateScope.context.contains("121.5432"))
        let locationScope = try retrieval.prepare(question: "总结这一天", records: [audio] + places, selectedDate: date, allowedKinds: [.location])
        precondition(locationScope.context.contains("31.2345"))
        precondition(!locationScope.context.contains("测试原文"), "Location permission doesn't grant the media text")
        note.location?.address = CaptureAddress(text: "上海市浦东新区世纪大道 1 号", localeIdentifier: "zh-Hans")!
        let addressed = DaybookPlaces.records(notes: [note], photos: [])
        precondition(addressed[0].title == "上海市浦东新区世纪大道 1 号", "timeline title must use the resolved address")
        let addressedSummary = DaybookPlaces.homeSummary(addressed)
        precondition(addressedSummary.placeCount == 1 && addressedSummary.labels == ["上海市浦东新区世纪大道 1 号"])
        let repeatedAddress = DaybookPlaces.homeSummary(addressed + addressed)
        precondition(repeatedAddress.placeCount == 1 && repeatedAddress.recordCount == 2 && repeatedAddress.labels.count == 1,
                     "same resolved address counts as one place while retaining every location record")
        precondition(DaybookPlaces.homeSummary([]).recordCount == 0, "empty day still has a stable summary model")
        let privateAddress = try retrieval.prepare(question: "总结这一天", records: [DaybookPlaces.voice(note)] + addressed, selectedDate: date, allowedKinds: [.voice])
        precondition(!privateAddress.context.contains("世纪大道"), "resolved addresses require the separate AI location permission")
        let permittedAddress = try retrieval.prepare(question: "总结这一天", records: addressed, selectedDate: date, allowedKinds: [.location])
        precondition(permittedAddress.context.contains("世纪大道"))
        let photo = PhotoAttachment(id: UUID(), filename: "unused", recognizedText: "", capture: PhotoCaptureMetadata(device: nil, importMethod: .library, location: point))
        let moment = PhotoMoment(id: UUID(), capturedAt: .now, caption: "", recognizedText: "", photos: [photo])
        precondition(DaybookPlaces.photo(moment).captureDevice == "设备未知")
        precondition(DaybookPlaces.records(notes: [], photos: [moment]).isEmpty, "An undated historical photo must not imply a visit today")
        print("Places projection: device, missing-location omission, original time, parent link, separate AI permissions passed")
    }
}
