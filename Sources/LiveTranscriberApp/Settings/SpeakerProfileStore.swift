import AVFAudio
import Foundation

/// A speaker registered for diarization enrollment. The name doubles as the
/// transcript label; the enrollment sample lives in `SpeakerProfileStore`
/// under `id`.
struct SpeakerProfile: Codable, Hashable, Identifiable, Sendable {
  let id: UUID
  var name: String
  /// Length of the stored enrollment sample, for display.
  var duration: TimeInterval
}

/// Stores speaker-enrollment samples as WAV files (16 kHz mono Float32) in
/// Application Support. This is the deliberate exception to "audio is never
/// persisted": only these explicitly recorded samples ever reach disk,
/// session audio never does.
struct SpeakerProfileStore {
  /// The recorder and the diarizer models share this rate.
  static let sampleRate = 16_000.0

  let directory: URL

  init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LiveTranscriber/Speakers", isDirectory: true)
  }

  private func url(for id: UUID) -> URL {
    directory.appendingPathComponent("\(id.uuidString).wav", isDirectory: false)
  }

  func save(samples: [Float], for id: UUID) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1,
      interleaved: false)!
    let file = try AVAudioFile(
      forWriting: url(for: id),
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Self.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
      ],
      commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    samples.withUnsafeBufferPointer { pointer in
      buffer.floatChannelData![0].update(from: pointer.baseAddress!, count: samples.count)
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
    // Buffered frames only reach disk on close; without it the tail of the
    // sample is lost.
    file.close()
  }

  func load(for id: UUID) throws -> [Float] {
    let file = try AVAudioFile(forReading: url(for: id))
    // `processingFormat` is always deinterleaved Float32 at the file's rate,
    // and the store only writes 16 kHz mono, so no conversion is needed.
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
    else { throw CocoaError(.fileReadCorruptFile) }
    var samples: [Float] = []
    samples.reserveCapacity(Int(file.length))
    // read(into:) may return fewer frames than the buffer holds even before
    // the end of the file; loop until EOF.
    while file.framePosition < file.length {
      try file.read(into: buffer)
      guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
      samples.append(
        contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
    return samples
  }

  func delete(for id: UUID) {
    try? FileManager.default.removeItem(at: url(for: id))
  }
}
