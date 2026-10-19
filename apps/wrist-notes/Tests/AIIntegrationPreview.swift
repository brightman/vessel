// Compiled only into the disposable preview app by prepare_ui_preview.py.
// Uses synthetic notes and a local fixture server; never runs in production builds.
@MainActor
enum AIIntegrationPreview {
    static func run(model: NotesModel, noteID: UUID) async {
        let resultURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai-integration-result.json")
        var checks: [String] = []
        do {
            func require(_ condition: Bool, _ label: String) throws {
                if !condition { throw AIServiceError.invalidConfiguration(label) }
                checks.append(label)
            }
            let editor = AISettingsModel(settings: model.settings)
            editor.configuration = AIConfiguration(mode: .custom, model: "fixture-model",
                baseURL: ProcessInfo.processInfo.environment["WN_TEST_BASE_URL"]!)
            editor.apiKey = "fixture-key-not-real"
            try require(!editor.canSave, "untested config cannot save")
            editor.startTest()
            for _ in 0..<200 {
                if editor.state != .testing { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(editor.state == .success, "real URLSession connection test passed")
            try editor.save()
            let reloaded = AppSettings()
            try require(reloaded.ai.model == "fixture-model", "configuration reload")
            let key = try reloaded.apiKey()
            try require(key == "fixture-key-not-real", "iOS Keychain write and read")
            await model.summarize(noteID)
            try require(model.note(noteID)?.summary == "测试总结：保存想法，周五复盘。", "configured model result persisted on note")
            try require(model.note(noteID)?.summaryState == .ready, "summary ready state")
            editor.configuration.model = "unauthorized-model"
            editor.startTest()
            for _ in 0..<200 {
                if editor.state != .testing { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            try require(editor.state == .failure(AIServiceError.authentication.localizedDescription), "authentication error shown")
            try require(!editor.canSave && model.settings.ai.model == "fixture-model", "failed draft does not replace saved model")
            try model.settings.saveAI(AIConfiguration(), apiKey: "")
            await model.summarize(noteID)
            try require(model.settings.ai.mode == .local, "switch back to local")
            // Availability varies by simulator. The HTTP fixture verifies that this step makes no remote request.
            try require([ProcessingState.unavailable, .failed, .ready].contains(model.note(noteID)?.summaryState ?? .running), "local route finished")
            try JSONSerialization.data(withJSONObject: ["ok": true, "checks": checks]).write(to: resultURL, options: .atomic)
        } catch {
            try? JSONSerialization.data(withJSONObject: ["ok": false, "checks": checks, "error": error.localizedDescription]).write(to: resultURL, options: .atomic)
        }
    }
}
