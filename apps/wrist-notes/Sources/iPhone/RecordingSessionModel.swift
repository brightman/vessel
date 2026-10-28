import Combine
import Foundation

/// All SQLite/recovery/media validation is serialized away from UI and WCSession callbacks.
// Mutable repository state is confined to queue; only perform() crosses threads.
private final class RecordingSessionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WiseLife.RecordingSessionPresentation", qos: .utility)
    private let open: () throws -> RecordingSessionRepository
    private var repository: RecordingSessionRepository?
    init(open: @escaping () throws -> RecordingSessionRepository) { self.open = open }
    func perform<T>(_ operation: @escaping (RecordingSessionRepository) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let repository = try self.repository ?? self.open()
                    self.repository = repository
                    continuation.resume(returning: try operation(repository))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct RecordingSessionDetail {
    let session: RecordingSessionSummary?
    let chunks: [RecordingChunkDescriptor]
    let gaps: [RecordingSessionGap]
    let ranges: [RecordingSourceRange]
    let cleanupPending: Bool
}

@MainActor final class RecordingSessionModel: ObservableObject {
    @Published private(set) var sessions: [RecordingSessionSummary] = []
    @Published private(set) var daySessions: [RecordingSessionSummary] = []
    @Published private(set) var calendarDates: [Date] = []
    @Published private(set) var cleanupIDs: [UUID] = []
    @Published private(set) var hasMore = false
    @Published private(set) var loading = false
    @Published private(set) var revision = 0
    @Published var errorMessage: String?
    private let worker: RecordingSessionWorker
    private var observation: AnyCancellable?
    private var task: Task<Void, Never>?
    private var requested = false
    private var recoverRequested = false
    private var requestRevision = 0
    private var limit = 50
    private var day = Date.now
    private var month = Date.now

    init(root: URL? = nil, openRepository: (() throws -> RecordingSessionRepository)? = nil) {
        let directory = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceNotes", isDirectory: true)
        worker = RecordingSessionWorker(open: openRepository ?? {
            try RecordingSessionRepository(root: directory.appendingPathComponent("RecordingSessions", isDirectory: true),
                database: DaybookDatabase(url: DaybookDatabase.metadataURL(forRoot: directory)))
        })
        observation = NotificationCenter.default.publisher(for: Notification.Name.recordingSourcesDidChange)
            .sink { [weak self] _ in Task { @MainActor [weak self] in self?.refresh() } }
    }

    var allKnownSessions: [RecordingSessionSummary] {
        var ids = Set<UUID>()
        return (sessions + daySessions).filter { ids.insert($0.id).inserted }
    }
    func session(_ id: UUID) -> RecordingSessionSummary? { allKnownSessions.first { $0.id == id } }
    func selectDay(_ date: Date) { day = date; refresh() }
    func selectMonth(_ date: Date) { month = date; refresh() }
    func loadMore() { limit += 50; refresh() }

    func refresh(recover: Bool = false) {
        requested = true; recoverRequested = recoverRequested || recover; requestRevision += 1
        guard task == nil else { return }
        loading = true
        task = Task { [weak self] in
            guard let self else { return }
            while self.requested {
                self.requested = false
                let token = self.requestRevision, recover = self.recoverRequested
                self.recoverRequested = false
                let calendar = Calendar.current
                let day = calendar.dateInterval(of: .day, for: self.day)!
                let month = calendar.dateInterval(of: .month, for: self.month)!
                let limit = self.limit
                do {
                    let result = try await self.worker.perform { repository in
                        if recover { try repository.recover() }
                        func all(in window: DateInterval) throws -> [RecordingSessionSummary] {
                            var values: [RecordingSessionSummary] = [], offset = 0
                            while true {
                                let page = try repository.sessions(overlapping: window.start, end: window.end, limit: 200, offset: offset)
                                values += page; offset += page.count
                                if page.count < 200 { return values }
                            }
                        }
                        // Repository page caps at 200; preserve general pagination beyond that cap.
                        var sessions: [RecordingSessionSummary] = [], offset = 0
                        while sessions.count < limit + 1 {
                            let count = min(200, limit + 1 - sessions.count)
                            let page = try repository.sessions(limit: count, offset: offset)
                            sessions += page; offset += page.count
                            if page.count < count { break }
                        }
                        return (sessions, try all(in: day), try all(in: month), try repository.pendingCleanupSessionIDs())
                    }
                    guard self.requestRevision == token else { continue }
                    self.sessions = Array(result.0.prefix(limit)); self.hasMore = result.0.count > limit
                    self.daySessions = result.1
                    self.calendarDates = RecordingSessionPresentation.occupiedDates(result.2, within: month, calendar: calendar)
                    self.cleanupIDs = result.3; self.errorMessage = nil; self.revision += 1
                } catch {
                    if self.requestRevision == token { self.errorMessage = "无法读取完整录音：\(error.localizedDescription)" }
                }
            }
            self.loading = false; self.task = nil
        }
    }

    /// Complete requested evidence coverage is independent of the first library page or selected UI day.
    func records(in scope: DateInterval, legacyIDs: Set<UUID>) async throws -> [DayRecord] {
        try await worker.perform { repository in
            var result: [RecordingSessionSummary] = [], offset = 0
            while true {
                let page = try repository.sessions(overlapping:scope.start,end:scope.end,limit:200,offset:offset)
                result += page; offset += page.count
                if page.count < 200 { break }
            }
            return RecordingSessionPresentation.records(result,legacyIDs:legacyIDs)
        }
    }

    func detail(_ id: UUID) async throws -> RecordingSessionDetail {
        try await worker.perform { repository in
            let session = try repository.session(id: id)
            return RecordingSessionDetail(session: session, chunks: try repository.chunks(sessionID: id),
                gaps: try repository.gaps(sessionID: id), ranges: session == nil ? [] : try repository.sourceRanges(sessionID: id),
                cleanupPending: try repository.cleanupPending(sessionID: id))
        }
    }

    @discardableResult func delete(_ id: UUID) async -> Bool {
        do {
            try await worker.perform { try $0.deleteSession(id) }
            sessions.removeAll { $0.id == id }; daySessions.removeAll { $0.id == id }
            revision += 1; refresh()
            NotificationCenter.default.post(name:Notification.Name.recordingSourcesDidChange,object:nil,userInfo:["deletedSessionID":id])
            return true
        } catch { errorMessage = "删除未完成，请解锁后重试。"; return false }
    }
}
