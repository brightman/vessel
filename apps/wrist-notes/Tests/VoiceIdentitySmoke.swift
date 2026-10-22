import Foundation
@main struct VoiceIdentitySmoke {
 static func main() throws {
  func check(_ value: @autoclosure () throws -> Bool) rethrows { let result = try value(); precondition(result) }
  func rejects(_ operation: () throws -> Void) { do { try operation(); fatalError("accepted invalid input") } catch {} }
  let a = [Float](repeating: 0, count: 255) + [1]
  let b = [Float](repeating: 0, count: 254) + [1, 0]
  rejects { _ = try VoiceIdentityPolicy.makeProfile(embeddings: [a,a,a], duration: 29) }
  rejects { _ = try VoiceIdentityPolicy.makeProfile(embeddings: [a,b,a], duration: 40) }
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
  try check(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  try check(try root.appendingPathComponent("profile.json").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  try Data("corrupt".utf8).write(to: root.appendingPathComponent("profile.json"))
  rejects { _ = try store.load() }
  try store.delete(); try store.delete(); try check(try store.load() == nil)
  print("VoiceIdentity storage and policy PASS")
 }
}
