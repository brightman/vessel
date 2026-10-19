// Appended only to the disposable simulator preview; uses synthetic data and a localhost fixture.
import Foundation
import HealthKit

final class MeetingPreviewSecretStore: SecretStore {
    private var value = ""
    func read() throws -> String { value }
    func write(_ value: String) throws { self.value = value }
}

@MainActor
enum MeetingIntegrationPreview {
    private static var didRun = false
    static func run(model: NotesModel, noteID: UUID) async {
        guard !didRun else { return }
        didRun = true
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("meeting-integration-result.json")
        var checks: [String] = []
        do {
            func require(_ condition: Bool, _ label: String) throws {
                guard condition else { throw AIServiceError.invalidConfiguration(label) }
                checks.append(label)
            }
            await model.openTimeline(noteID)
            let milliseconds = HKQuantity(unit: .second(), doubleValue: 0.0325).doubleValue(for: .secondUnit(with: .milli))
            try require(abs(milliseconds - 32.5) < 0.0001, "HRV seconds convert to SDNN milliseconds")
            try require(model.timelines[noteID]?.hrvPoints.count == 3, "HRV measurement windows load into the timeline")
            try require(model.timelines[noteID]?.statesOfMind.count == 2, "momentary and daily subjective records load")
            try require(HKHeartRateMotionContext.sedentary.rawValue == 1 && HKHeartRateMotionContext.active.rawValue == 2,
                "motion context values match the HealthKit enum contract")
            try require(HKStateOfMind.Label.stressed.rawValue == 29 && HKStateOfMind.Association.work.rawValue == 17,
                "subjective label and association mapping matches the HealthKit enum contract")
            let syntheticMoment = HKStateOfMind(date: model.note(noteID)!.capturedAt.addingTimeInterval(12), kind: .momentaryEmotion,
                valence: -0.3, labels: [.stressed], associations: [.work])
            let mappedMoment = HeartRateService.stateOfMindPoint(from: syntheticMoment, calendar: .current)
            try require(mappedMoment?.labelsText == "有压力" && mappedMoment?.associationsText == "工作" && mappedMoment?.dayStart == nil,
                "actual HealthKit subjective samples map to self-report values without daily scope")
            let syntheticDaily = HKStateOfMind(date: syntheticMoment.startDate, kind: .dailyMood, valence: 0, labels: [], associations: [])
            let mappedDaily = HeartRateService.stateOfMindPoint(from: syntheticDaily, calendar: .current)
            try require(mappedDaily?.kind == .dailyMood && mappedDaily?.dayStart != nil && mappedDaily?.dayEnd != nil,
                "actual daily HealthKit samples preserve their calendar boundaries")
            let quantity = HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 70)
            let activeSample = HKQuantitySample(type: HKQuantityType(.heartRate), quantity: quantity,
                start: syntheticMoment.startDate, end: syntheticMoment.startDate,
                metadata: [HKMetadataKeyHeartRateMotionContext: HKHeartRateMotionContext.active.rawValue])
            let unknownSample = HKQuantitySample(type: HKQuantityType(.heartRate), quantity: quantity,
                start: syntheticMoment.startDate, end: syntheticMoment.startDate)
            try require(HeartRateService.motionContext(from: activeSample) == 2 && HeartRateService.motionContext(from: unknownSample) == nil,
                "actual heart-rate sample metadata preserves activity and missing context")
            let mindEvents = StateOfMindEvidence.records(in: model.timelines[noteID]!, note: model.note(noteID)!)
            try require(mindEvents.first { $0.point.kind == .momentaryEmotion }?.excerpts.count == 1,
                "momentary emotion matches timestamped words")
            try require(mindEvents.first { $0.point.kind == .dailyMood }?.excerpts.isEmpty == true,
                "daily mood never becomes a timestamped trigger")
            let configuration = AIConfiguration(mode: .custom, model: "meeting-fixture",
                baseURL: ProcessInfo.processInfo.environment["WN_MEETING_TEST_BASE_URL"]!)
            try model.settings.saveAI(configuration, apiKey: "fixture-key-not-real")
            model.analyze(noteID)
            try require(model.analysisModels[noteID] == nil && model.analysisErrors[noteID] != nil, "remote health analysis requires per-run confirmation")
            model.analyze(noteID, authorizedRemote: configuration)
            for _ in 0..<300 {
                if model.analysisModels[noteID] == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let note = model.note(noteID)!
            let timeline = model.timelines[noteID]!
            try require(timeline.currentAnalysis(for: note)?.text.contains("fixture") == true, "analysis response persisted with matching input revision")
            try require(timeline.currentAnalysis(for: note)?.text.contains("32.5–45.5 ms") == true, "analysis includes observed HRV window statistics")
            try require(timeline.currentAnalysis(for: note)?.text.contains("1 个采样时活动中") == true, "analysis includes actual motion context statistics")
            try require(timeline.currentAnalysis(for: note)?.text.contains("M1") == true && timeline.currentAnalysis(for: note)?.text.contains("本人记录有些不愉快") == true,
                "analysis includes subjective evidence as self-report")
            let root = output.deletingLastPathComponent().appendingPathComponent("VoiceNotes")
            let stored = try NoteTimelineStore(root: root).load(noteID)
            try require(stored.currentAnalysis(for: note) != nil, "analysis survives sidecar reload")
            try require(stored.hrvPoints == timeline.hrvPoints, "HRV and original measurement windows survive reload")
            try require(stored.statesOfMind == timeline.statesOfMind && stored.points == timeline.points, "subjective records and motion metadata survive reload")
            await model.setStateOfMindEnabled(false)
            try require(model.timelines[noteID]?.statesOfMind.isEmpty == true && model.timelines[noteID]?.analysis == nil, "disable subjective records clears only their cache and analysis")
            try require(model.timelines[noteID]?.points == timeline.points && model.timelines[noteID]?.hrvPoints == timeline.hrvPoints,
                "subjective opt-out preserves heart rate and HRV")
            // Restore synthetic input and reload through a new model to verify the independent opt-outs.
            try NoteTimelineStore(root: root).save(timeline, id: noteID)
            model.settings.stateOfMindEnabled = true
            let reloadedModel = NotesModel(settings: model.settings)
            await reloadedModel.openTimeline(noteID)
            await reloadedModel.setHRVEnabled(false)
            try require(reloadedModel.timelines[noteID]?.hrvPoints.isEmpty == true && reloadedModel.timelines[noteID]?.analysis == nil, "disable HRV clears its samples and derived analysis")
            try require(reloadedModel.timelines[noteID]?.points == timeline.points && reloadedModel.settings.heartRateEnabled, "disable HRV retains heart-rate data and opt-in")
            try require(reloadedModel.timelines[noteID]?.statesOfMind == timeline.statesOfMind, "HRV opt-out preserves subjective records")
            reloadedModel.save(id: noteID, title: note.title, transcript: note.transcript + " 手动修改。")
            try require(reloadedModel.timelines[noteID]?.segments.isEmpty == true, "manual edits discard old time alignment")
            try require(reloadedModel.timelines[noteID]?.analysis == nil, "manual edits invalidate old analysis")
            reloadedModel.analyze(noteID, authorizedRemote: configuration)
            reloadedModel.cancelAnalysis(noteID)
            for _ in 0..<100 {
                if reloadedModel.analysisModels[noteID] == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(reloadedModel.analysisModels[noteID] == nil && reloadedModel.timelines[noteID]?.analysis == nil, "cancelled analysis cannot write a result")
            await reloadedModel.setHeartRateEnabled(false)
            try require(reloadedModel.timelines[noteID]?.points.isEmpty == true, "disable clears cached heart-rate data")
            try require(reloadedModel.timelines[noteID]?.hrvPoints.isEmpty == true && !model.settings.hrvEnabled, "heart-rate opt-out also disables HRV")
            try require(reloadedModel.timelines[noteID]?.statesOfMind == timeline.statesOfMind && model.settings.stateOfMindEnabled, "heart-rate opt-out preserves independent subjective records")
            reloadedModel.analyze(noteID, authorizedRemote: configuration)
            for _ in 0..<300 {
                if reloadedModel.analysisModels[noteID] == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(reloadedModel.timelines[noteID]?.currentAnalysis(for: reloadedModel.note(noteID)!) != nil,
                "subjective-only analysis works with heart-rate access disabled")
            await reloadedModel.setStateOfMindEnabled(false)
            try require(reloadedModel.timelines[noteID]?.statesOfMind.isEmpty == true && reloadedModel.timelines[noteID]?.analysis == nil,
                "final opt-out clears subjective data and derived report")
            try require(model.note(noteID) != nil && model.audioURL(noteID) != nil, "disable preserves note and audio")
            try model.settings.saveAI(AIConfiguration(), apiKey: "")
            try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(to: output, options: .atomic)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription]).write(to: output, options: .atomic)
        }
    }
}
