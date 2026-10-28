#!/usr/bin/env python3
"""Disposable native UI review: synthetic recordings, in-memory PIN, distinct bundle IDs.
No fixture or authentication bypass is added to the production targets.
"""
import json, pathlib, shutil, subprocess, tempfile
source = pathlib.Path(__file__).resolve().parents[1]
root = pathlib.Path(tempfile.mkdtemp(prefix='wiselife-ui-review-', dir='/private/tmp'))
shutil.copytree(source, root/'app', ignore=shutil.ignore_patterns('build','.build','Pods','xcuserdata','__pycache__'))
app = root/'app'
project = app/'WristNotes.xcodeproj/project.pbxproj'
project.write_text(project.read_text().replace('cloud.karama.wisenote','cloud.karama.wisenote.ui-review'))
watch_info=app/'Sources/Watch/Info.plist'
watch_info.write_text(watch_info.read_text().replace('cloud.karama.wisenote','cloud.karama.wisenote.ui-review'))
model=app/'Sources/iPhone/AppLockModel.swift'
s=model.read_text().replace('biometricAvailable = value.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)', 'biometricAvailable = true')
s=s.replace('guard active, phase == .locked, biometricEnabled, !attemptedAutomaticBiometry else', 'guard !ProcessInfo.processInfo.arguments.contains("--preview-screen"), active, phase == .locked, biometricEnabled, !attemptedAutomaticBiometry else')
model.write_text(s)
(app/'Sources/iPhone/WristNotesApp.swift').write_text(r'''import SwiftUI
import Foundation
final class ReviewSecretStore: AppPasscodeSecretStore, @unchecked Sendable {
    private var data: Data?
    private let lock = NSLock()
    func read() throws -> Data? { lock.withLock { data } }
    func write(_ value: Data) throws { lock.withLock { data = value } }
}
@main @MainActor struct WristNotesApp: App {
    @StateObject private var lock: AppLockModel
    private let vault: AppPasscodeVault
    private let screen: String
    @State private var privateSheet = false
    init() {
        let args=ProcessInfo.processInfo.arguments
        screen=args.firstIndex(of:"--preview-screen").flatMap{args.indices.contains($0+1) ? args[$0+1] : nil} ?? "onboarding"
        let defaults=UserDefaults(suiteName:"WiseLife.UIReview")!
        defaults.removePersistentDomain(forName:"WiseLife.UIReview")
        defaults.set(screen != "onboarding",forKey:"WiseLife.AppPasscode.onboarding.v1")
        let vault=AppPasscodeVault(store:ReviewSecretStore())
        self.vault=vault
        _lock=StateObject(wrappedValue:AppLockModel(vault:vault,defaults:defaults))
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if screen == "settings" {
                    SettingsPage(title:"隐私与安全",subtitle:"为属于你的记录，加一道保护。") { AppPasscodeSettingsSection() }
                } else if screen == "change" {
                    AppPasscodeEditor(model:lock,mode:.change)
                } else {
                    VStack(spacing:24) { Text("个人记录").font(.largeTitle); Text("UI review fixture") }
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
            .environmentObject(lock)
            .opacity(lock.phase == .unlocked ? 1 : 0)
            .background(AppLockWindowBridge(model:lock,colorScheme:.light))
            .preferredColorScheme(.light)
            .sheet(isPresented:$privateSheet) { Text("PRIVATE SHEET MUST BE COVERED").font(.largeTitle) }
            .task {
                try? await Task.sleep(for:.milliseconds(400))
                if ["unlock","change","privacy","settings"].contains(screen) {
                    try? await vault.setInitialPasscode("135790",biometricState:screen == "unlock" ? Data([1,2,3,4]) : nil)
                    await lock.load()
                    if screen != "unlock" { _ = await lock.unlock(code:"135790") }
                    if screen == "privacy" {
                        privateSheet=true
                        try? await Task.sleep(for:.milliseconds(700))
                        lock.willResignActive();lock.didEnterBackground();lock.didBecomeActive()
                    }
                }
            }
        }
    }
}
''')
recorder=app/'Sources/Watch/WatchRecorder.swift'
s=recorder.read_text()
fixture=r'''
        let args=ProcessInfo.processInfo.arguments
        let screen=args.firstIndex(of:"--preview-screen").flatMap{args.indices.contains($0+1) ? args[$0+1] : nil} ?? "watch-home"
        let now=Date()
        pending=[PendingRecording(id:UUID(),kind:.thought,capturedAt:now.addingTimeInterval(-300),duration:32),
                 PendingRecording(id:UUID(),kind:.long,capturedAt:now.addingTimeInterval(-2400),duration:522,uploaded:true),
                 PendingRecording(id:UUID(),kind:.thought,capturedAt:now.addingTimeInterval(-5000),duration:42)]
        pending[2].transferFailed=true
        if screen == "watch-recording" {
            isRecording=true;elapsed=42;currentID=UUID();currentKind = .long;startedAt=now.addingTimeInterval(-42)
        }
        sessionRecoveryInProgress=false
        return
'''
s=s.replace('        super.init()\n','        super.init()\n'+fixture+'\n',1)
s=s.replace('    func transferPresentation(for entry: WatchLibraryEntry) -> WatchTransferPresentation {','''    func transferPresentation(for entry: WatchLibraryEntry) -> WatchTransferPresentation {
        if entry.recordingID == pending.first?.id { return .init(phase:.sending,fraction:0.64) }
''',1)
recorder.write_text(s)
(app/'Sources/Watch/WristNotesWatchApp.swift').write_text(r'''import SwiftUI
@main struct WristNotesWatchApp: App {
    @StateObject private var recorder=WatchRecorder()
    var body: some Scene {
        WindowGroup {
            WatchContentView(startOnLibrary:ProcessInfo.processInfo.arguments.contains("watch-list"))
                .environmentObject(recorder)
        }
    }
}
''')
with open(root/'pods.log','w') as log:
    subprocess.run(['pod','install','--no-repo-update'],cwd=app,stdout=log,stderr=subprocess.STDOUT,check=True)
subprocess.run(['/opt/homebrew/opt/ruby/bin/ruby','-rxcodeproj','-e',r'''
p=Xcodeproj::Project.open(ARGV[0]);p.targets.each{|t|t.build_configurations.each{|c|c.build_settings['IPHONEOS_DEPLOYMENT_TARGET']='15.0'}};p.save
''',str(app/'Pods/Pods.xcodeproj')],check=True)
print(json.dumps({'root':str(root),'workspace':str(app/'WristNotes.xcworkspace'),'phoneBundleID':'cloud.karama.wisenote.ui-review','watchBundleID':'cloud.karama.wisenote.ui-review.watchkitapp'}))
