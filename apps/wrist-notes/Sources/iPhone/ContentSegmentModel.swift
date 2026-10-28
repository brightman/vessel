import Foundation
import Combine

/// All pages are bounded SQL reads. The requested scope is complete regardless of UI pagination.
enum ContentSegmentSnapshot {
    static func read(_ processing: AudioProcessingRepository, scope: DateInterval, requireComplete: Bool = true) throws -> [DayRecord] {
        let db = processing.derivedDatabase
        // A day's transcript can span hours; keep a consistent WAL snapshot
        // without holding the writer needed by location, health and recap state.
        return try db.readTransaction {
        var result: [DayRecord] = [], offset = 0
        while true {
            try Task.checkCancellation()
            let rows = try db.query("""
                SELECT c.payload,s.descriptor,s.revision AS source_revision,s.configuration_key,p.content_signature,p.transcript FROM content_segments c JOIN audio_processing_sources s ON s.source_key=c.source_key
                LEFT JOIN content_segment_presentations p ON p.segment_id=c.id
                WHERE c.deleted=0 AND EXISTS (SELECT 1 FROM content_segment_ranges r WHERE r.segment_id=c.id
                AND json_extract(CAST(s.descriptor AS TEXT),'$.capturedAt')+r.end>?
                AND json_extract(CAST(s.descriptor AS TEXT),'$.capturedAt')+r.start<?)
                ORDER BY c.source_key,c.start,c.id LIMIT 100 OFFSET ?
                """,[.real(scope.start.timeIntervalSinceReferenceDate),.real(scope.end.timeIntervalSinceReferenceDate),.integer(Int64(offset))])
            for row in rows {
                let segment = try DaybookDatabase.decode(ContentSegment.self,row["payload"])
                let source = try DaybookDatabase.decode(AudioSourceSnapshot.self,row["descriptor"])
                let signature = segment.provenance.semanticContentSignature ?? segment.provenance.contentSignature
                guard row["content_signature"]?.string == signature, row["transcript"]?.data != nil,
                      row["configuration_key"]?.string == segment.provenance.configurationKey,
                      try row.requiredInt("source_revision") == segment.sourceRevision else {
                    // UI may show already prepared segments while processing continues.
                    // AI/full-date evidence must never silently accept an incomplete snapshot.
                    if requireComplete { throw ContentSegmentError.staleRevision }
                    continue
                }
                let spans = try DaybookDatabase.decode([AudioTranscriptSpan].self,row["transcript"])
                if let projected = ContentSegmentPresentation.record(segment,source:source,spans:spans).recordingProjection(from:scope.start,to:scope.end) { result.append(projected) }
            }
            offset += rows.count
            if rows.count < 100 { return result }
        }
        }
    }
}

/// Deletion ownership is portable so the actual cache path can be tested without an iOS host.
@MainActor class ContentSegmentCache: ObservableObject {
    @Published fileprivate(set) var records: [DayRecord] = []
    @Published fileprivate(set) var library: [ContentSegment] = []
    @Published fileprivate(set) var calendarDates: [Date] = []
    @Published fileprivate(set) var revision = 0
    fileprivate var known = Set<UUID>()
    fileprivate var token = UUID()
    fileprivate var epoch = 0
    fileprivate var onDeletion: (() -> Void)?
    private var deletionObservation: AnyCancellable?
    init() {
        _ = LegacyAudioDeletionLedger.shared
        deletionObservation = NotificationCenter.default.publisher(for:LegacyAudioDeletionLedger.notification).sink { [weak self] note in
            if let id = note.userInfo?["legacyNoteID"] as? UUID { LegacyAudioDeletionLedger.shared.record(id) }
            // Main-thread repository writes invalidate before the delete action returns.
            if Thread.isMainThread { MainActor.assumeIsolated { self?.invalidateDeletedSources() } }
            else { Task { @MainActor [weak self] in self?.invalidateDeletedSources() } }
        }
    }
    private func invalidateDeletedSources() {
        epoch += 1; token = UUID()
        records = LegacyAudioDeletionLedger.shared.filter(records)
        library.removeAll { $0.sourceID.kind == .legacyNote && LegacyAudioDeletionLedger.shared.contains($0.sourceID.id) }
        known = Set(library.map(\.id)).union(records.map(\.id))
        // Occupancy is cheap to reload and must not advertise a deleted-only day meanwhile.
        calendarDates = []; revision += 1; onDeletion?()
    }
    func publish(records: [DayRecord], library: [ContentSegment], dates: [Date]) {
        let visibleRecords = LegacyAudioDeletionLedger.shared.filter(records)
        let visibleLibrary = library.filter { $0.sourceID.kind != .legacyNote || !LegacyAudioDeletionLedger.shared.contains($0.sourceID.id) }
        if self.records != visibleRecords { self.records = visibleRecords }
        if self.library != visibleLibrary { self.library = visibleLibrary }
        known.formUnion(self.library.map(\.id))
        if calendarDates != dates { calendarDates = dates }
    }
}

#if os(iOS) || CONTENT_SEGMENT_MODEL_TESTS

struct ContentSegmentDetail: Sendable {
    let segment: ContentSegment
    let source: AudioSourceSnapshot
    let state: ContentProcessingState
    let spans: [AudioTranscriptSpan]
    let hasMore: Bool
    let neighbors: [ContentSegment]
}

@MainActor final class ContentSegmentModel: ContentSegmentCache {
    /// Only an unread date shows a foreground loading indicator. Already loaded
    /// dates, including empty ones, stay visible during background updates.
    @Published private(set) var loading = false
    @Published private(set) var refreshing = false
    @Published private(set) var hasMore = false
    @Published var errorMessage: String?
    private let processing: AudioProcessingModel
    private var observations: [AnyCancellable] = []
    private var day = Date.now
    private var month = Date.now
    private var limit = 50
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var loadedDay: DateInterval?
    private var loadedMonth: DateInterval?

    init(processing: AudioProcessingModel) {
        self.processing = processing
        super.init()
        onDeletion = { [weak self] in self?.refresh() }
        for name in [AudioProcessingModel.contentDidChange,Notification.Name.recordingSourcesDidChange] {
            observations.append(NotificationCenter.default.publisher(for:name).sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }; self.epoch += 1; self.revision += 1; self.refresh()
                }
            })
        }
    }
    func contains(_ id: UUID) -> Bool { known.contains(id) }
    func selectDay(_ date: Date) {
        let scope = Calendar.current.dateInterval(of:.day,for:date)!
        if scope == Calendar.current.dateInterval(of:.day,for:day), errorMessage == nil,
           loadedDay == scope || refreshTask != nil { return }
        day = date; refresh()
    }
    func selectMonth(_ date: Date) {
        let scope = Calendar.current.dateInterval(of:.month,for:date)!
        if scope == Calendar.current.dateInterval(of:.month,for:month), errorMessage == nil,
           loadedMonth == scope || refreshTask != nil { return }
        month = date; refresh()
    }
    func loadMore() { limit += 50; refresh() }
    func refresh() {
        token = UUID(); refreshRequested = true
        let needsDay = loadedDay != Calendar.current.dateInterval(of:.day,for:day)!
        if loading != needsDay { loading = needsDay }
        // Keep at most one reader and one pending refresh. Cancelling/restarting
        // on every worker notification queues redundant SQLite work and can
        // prevent the latest snapshot from ever reaching the screen.
        guard refreshTask == nil else { return }
        refreshing = true
        refreshTask = Task {
            defer { refreshTask = nil; refreshing = false; loading = false }
            while refreshRequested {
                refreshRequested = false
                let request = token
                let dayScope = Calendar.current.dateInterval(of:.day,for:day)!
                let monthScope = Calendar.current.dateInterval(of:.month,for:month)!
                let count = limit
                do {
                    let snapshot = try await load(scope:dayScope,requireComplete:false)
                    try Task.checkCancellation()
                    guard token == request else { continue }
                    // Publish the requested day before unrelated library/calendar pagination.
                    if records != snapshot { records = snapshot }
                    loadedDay = dayScope
                    if loading { loading = false }
                    let result = try await processing.withRepository { processing in
                        try Task.checkCancellation()
                        let db = processing.derivedDatabase
                        var library: [ContentSegment] = [], libraryOffset = 0
                        while library.count < count+1 {
                            try Task.checkCancellation()
                            let pageCount = min(100,count+1-library.count)
                            let rows = try db.query("SELECT c.payload FROM content_segments c JOIN audio_processing_sources s ON s.source_key=c.source_key WHERE c.deleted=0 ORDER BY json_extract(CAST(s.descriptor AS TEXT),'$.capturedAt')+c.start DESC,c.id LIMIT ? OFFSET ?",[.integer(Int64(pageCount)),.integer(Int64(libraryOffset))])
                            library += try rows.map { try DaybookDatabase.decode(ContentSegment.self,$0["payload"]) }
                            libraryOffset += rows.count; if rows.count < pageCount { break }
                        }
                        // Date occupancy needs only actual ranges, never transcript bodies.
                        var dates = Set<Date>(), offset = 0
                        while true {
                            try Task.checkCancellation()
                            let ranges = try db.query("SELECT s.descriptor,r.start,r.end FROM content_segment_ranges r JOIN content_segments c ON c.id=r.segment_id JOIN audio_processing_sources s ON s.source_key=c.source_key WHERE c.deleted=0 ORDER BY c.id,r.position LIMIT 200 OFFSET ?",[.integer(Int64(offset))])
                            for row in ranges {
                                let source = try DaybookDatabase.decode(AudioSourceSnapshot.self,row["descriptor"])
                                let low = max(monthScope.start,source.capturedAt.addingTimeInterval(try row.requiredDouble("start")))
                                let high = min(monthScope.end,source.capturedAt.addingTimeInterval(try row.requiredDouble("end")))
                                var day = Calendar.current.startOfDay(for:low)
                                while low < high && day < high {
                                    dates.insert(day); day = Calendar.current.date(byAdding:.day,value:1,to:day)!
                                }
                            }
                            offset += ranges.count; if ranges.count < 200 { break }
                        }
                        return (library,dates.sorted())
                    }
                    guard token == request else { continue }
                    publish(records:snapshot,library:Array(result.0.prefix(count)),dates:result.1); hasMore = result.0.count > count
                    loadedMonth = monthScope
                    errorMessage = nil
                } catch is CancellationError { }
                catch { if token == request { errorMessage = "无法读取录音片段，请解锁后重试。" } }
            }
        }
    }
    func load(scope: DateInterval, requireComplete: Bool = true) async throws -> [DayRecord] {
        let captured = epoch
        let result = try await processing.withRepository { try ContentSegmentSnapshot.read($0,scope:scope,requireComplete:requireComplete) }
        try Task.checkCancellation()
        guard captured == epoch else { throw ContentSegmentError.staleRevision }
        let current = LegacyAudioDeletionLedger.shared.filter(result)
        known.formUnion(current.map(\.id)); return current
    }
    func replacingAudio(_ parents: [DayRecord], kind: AudioSourceKind) -> [DayRecord] {
        let derived = records.filter { $0.contentProvenance?.sourceKind == kind.rawValue }
        let ids = Set(derived.compactMap { $0.contentProvenance?.sourceID })
        let groupedSourceIDs = Set(parents.filter { ids.contains($0.id) }.compactMap(\.recordingGroupID))
        return parents.filter { !ids.contains($0.recordingSessionID ?? $0.id) && !($0.recordingGroupID.map(groupedSourceIDs.contains) ?? false) } + derived
    }
    func sourcePage(_ source: AudioSourceID, limit: Int, offset: Int) async throws -> [ContentSegment] {
        let values = try await processing.withRepository { try ContentSegmentRepository(database:$0.derivedDatabase).segments(sourceID:source,limit:min(100,limit),offset:offset) }
        known.formUnion(values.map(\.id)); return values
    }
    func detail(_ id: UUID, limit: Int = 100) async throws -> ContentSegmentDetail? {
        try await processing.withRepository { processing in
            let repository = ContentSegmentRepository(database:processing.derivedDatabase)
            guard let segment = try repository.segment(id:id), let source = try processing.currentSource(segment.sourceID) else { return nil }
            var spans: [AudioTranscriptSpan] = [], offset = 0
            while spans.count < limit + 1 {
                let page = try repository.spans(segmentID:id,limit:min(100,limit+1-spans.count),offset:offset)
                spans += page; offset += page.count
                if page.isEmpty { break }
            }
            let row = try processing.derivedDatabase.query("SELECT count(*) AS count FROM content_segments WHERE source_key=? AND deleted=0 AND start<?",[.text(segment.sourceID.key),.real(segment.ranges.first?.sessionStartOffset ?? 0)]).first
            let index = Int(try row?.requiredInt("count") ?? 0)
            return ContentSegmentDetail(segment:segment,source:source,state:try repository.state(sourceID:segment.sourceID),spans:Array(spans.prefix(limit)),hasMore:spans.count>limit,neighbors:try repository.segments(sourceID:segment.sourceID,limit:3,offset:max(0,index-1)))
        }
    }
    func mutate(sourceID: AudioSourceID, _ operation: @escaping @Sendable (ContentSegmentRepository) throws -> Void) async -> Bool {
        do {
            try await processing.withRepository {
                let repository = ContentSegmentRepository(database:$0.derivedDatabase)
                try operation(repository)
            }
            // The edit is already durable. Artifact work may lose a source revision
            // race and is retried by the worker; it must not report the edit as failed.
            epoch += 1; revision += 1; refresh(); processing.rebuildContent(sourceID); errorMessage = nil; return true
        } catch { errorMessage = "片段已更新或操作未完成，请刷新后重试。"; return false }
    }
}
#endif
