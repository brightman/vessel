import Foundation
@main struct VoiceIdentitySmoke {
 static func main() throws {
  func check(_ value: @autoclosure () throws -> Bool) rethrows { let result = try value(); precondition(result) }
  func rejects(_ operation: () throws -> Void) { do { try operation(); fatalError("accepted invalid input") } catch {} }
  let a = [Float](repeating: 0, count: 255) + [1]
  let b = [Float](repeating: 0, count: 254) + [1, 0]
  rejects { _ = try VoiceIdentityPolicy.makeProfile(embeddings: [a,a,a], duration: 29) }
  rejects { _ = try VoiceIdentityPolicy.makeProfile(embeddings: [a,b,a], duration: 40) }
  // One corrupted window in an otherwise consistent solo enrollment should not
  // invalidate the whole take. Two discordant windows must still be rejected.
  let recovered = try VoiceIdentityPolicy.makeProfile(embeddings: [a,a,a,a,b], duration: 40)
  check(recovered.embeddings.count == 4)
  rejects { _ = try VoiceIdentityPolicy.makeProfile(embeddings: [a,a,a,b,b], duration: 40) }
  // Same-speaker samples can contain a low pairwise score while each sample
  // remains close to their shared voice center. A distinct noisy tail is excluded.
  let halfAngleX = Float(sqrt(0.86)), halfAngleY = Float(sqrt(0.14))
  let left = [halfAngleX, halfAngleY, Float(0)] + [Float](repeating: 0, count: 253)
  let right = [halfAngleX, -halfAngleY, Float(0)] + [Float](repeating: 0, count: 253)
  let center = [Float(1), 0, 0] + [Float](repeating: 0, count: 253)
  let unrelated = [Float(0), 0, 1] + [Float](repeating: 0, count: 253)
  let liveProfile = try VoiceIdentityPolicy.makeProfile(
    embeddings: [left, right, center, center, center, unrelated], duration: 32)
  check(liveProfile.embeddings.count == 5)
  check(VoiceIdentityPolicy.matches(embeddings: [left, right], profile: liveProfile))
  check(!VoiceIdentityPolicy.matches(embeddings: [left, unrelated], profile: liveProfile))
  rejects { _ = try VoiceIdentityPolicy.makeProfile(
    embeddings: [center, center, center, unrelated, unrelated, unrelated], duration: 32) }
  rejects { _ = try VoiceIdentityPolicy.makeProfile(embeddings: [[.nan]], duration: 40) }
  let profile = try VoiceIdentityPolicy.makeProfile(embeddings: [a,a,a], duration: 40)
  check(VoiceIdentityPolicy.matches(embeddings: [a,a], profile: profile))
  check(!VoiceIdentityPolicy.matches(embeddings: [b,b], profile: profile))
  check(!VoiceIdentityPolicy.matches(embeddings: [a,b], profile: profile))
  check(!VoiceIdentityPolicy.matches(embeddings: [a], profile: profile))
  check(!VoiceIdentityPolicy.matches(embeddings: [[1,0],[1,0]], profile: profile))
  let uncertain = (0..<256).map { $0 == 255 ? Float(0.7) : ($0 == 254 ? Float(sqrt(0.51)) : 0) }
  check(!VoiceIdentityPolicy.matches(embeddings: [uncertain,uncertain], profile: profile))
  check(!VoiceIdentityPolicy.matches(embeddings: [[.infinity]], profile: profile))
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = VoiceProfileStore(root: root)
  try check(try store.load() == nil)
  try store.save(profile); try check(try store.load() == profile)
  let replacement = try VoiceIdentityPolicy.makeProfile(embeddings: [b,b,b], duration: 60)
  try store.save(replacement); try check(try store.load() == replacement)
  rejects { try store.save(VoiceProfile(id: UUID(), enrolledAt: Date(), recordingDuration: 40, modelID: "unknown", embeddings: [a,a,a])) }
  try check(try store.load() == replacement)
  #if os(iOS)
  try check(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  try check(try root.appendingPathComponent("profile.json").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  #endif
  try Data("corrupt".utf8).write(to: root.appendingPathComponent("profile.json"))
  rejects { _ = try store.load() }
  try store.delete(); try store.delete(); try check(try store.load() == nil)

  // The production store must migrate the previous protected file to its device-only
  // persistence backend and recover it through a newly constructed store instance.
  let legacyRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: legacyRoot) }
  let legacyStore = VoiceProfileStore(root: legacyRoot)
  try legacyStore.save(profile)
  let persistence = MemoryVoiceProfilePersistence()
  let migratedStore = VoiceProfileStore(root: nil, persistence: persistence, legacyRoot: legacyRoot)
  try check(try migratedStore.load() == profile)
  check(!FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("profile.json").path))
  let reopenedStore = VoiceProfileStore(root: nil, persistence: persistence, legacyRoot: legacyRoot)
  try check(try reopenedStore.load() == profile)
  try reopenedStore.delete()
  try check(try reopenedStore.load() == nil)
  print("VoiceIdentity storage and policy PASS")
 }
}

private final class MemoryVoiceProfilePersistence: VoiceProfilePersistence, @unchecked Sendable {
  private var stored: Data?
  func load() throws -> Data? { stored }
  func save(_ data: Data) throws { stored = data }
  func delete() throws { stored = nil }
}
