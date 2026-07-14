import Foundation
import Testing

@testable import LiveTranscriberApp

@Suite("SpeakerProfileStore")
struct SpeakerProfileStoreTests {
  private func makeStore() throws -> (store: SpeakerProfileStore, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SpeakerProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
    return (SpeakerProfileStore(directory: directory), directory)
  }

  @Test("Samples round-trip through the WAV file")
  func roundTrip() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let samples = (0..<32_000).map { Float(sin(Double($0) * 0.01)) * 0.5 }
    let id = UUID()
    try store.save(samples: samples, for: id)
    let restored = try store.load(for: id)

    #expect(restored.count == samples.count)
    // Float32 PCM is lossless.
    #expect(restored == samples)
  }

  @Test("Delete removes the sample; loading it then fails")
  func deleteRemoves() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    let id = UUID()
    try store.save(samples: [0.1, 0.2, 0.3], for: id)
    store.delete(for: id)
    #expect(throws: Error.self) { try store.load(for: id) }
  }
}
