import AVFAudio
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Captures application or whole-system audio via ScreenCaptureKit and pushes
/// converted PCM buffers into a `sink` closure.
///
/// The first `SCShareableContent` access triggers the Screen & System Audio
/// Recording TCC prompt (there is no Info.plist key for it).
///
/// `@unchecked Sendable`: mutable state (`converter`) is only touched on the
/// internal serial queue; `stream` is only touched from the actor-agnostic
/// start/stop pair, which the pipeline calls sequentially.
public final class AppAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable
{
  /// A running application whose audio can be captured, for the UI picker.
  public struct CapturableApp: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
  }

  public enum AppAudioError: LocalizedError {
    case noDisplay
    case applicationNotRunning(String)

    public var errorDescription: String? {
      switch self {
      case .noDisplay:
        return "No capturable display was found."
      case .applicationNotRunning(let bundleID):
        return "Application \"\(bundleID)\" is not running or cannot be captured."
      }
    }
  }

  private let outputFormat: AVAudioFormat
  private let sink: @Sendable (AVAudioPCMBuffer) -> Void
  private let onError: @Sendable (String) -> Void
  /// Called when the stream stops on its own (e.g. permission revoked).
  private let onStopped: @Sendable (String) -> Void
  private let frameRate: Int
  private let converter = BufferConverter()
  private let queue = DispatchQueue(label: "live-transcriber.app-audio")
  private var stream: SCStream?

  public init(
    outputFormat: AVAudioFormat,
    frameRate: Int = 10,
    sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    onError: @escaping @Sendable (String) -> Void = { _ in },
    onStopped: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.outputFormat = outputFormat
    self.frameRate = max(1, frameRate)
    self.sink = sink
    self.onError = onError
    self.onStopped = onStopped
  }

  // MARK: - Content discovery

  /// Running applications with a bundle identifier, sorted by name.
  public static func availableApps() async throws -> [CapturableApp] {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    return content.applications
      .filter { !$0.bundleIdentifier.isEmpty }
      .map { CapturableApp(id: $0.bundleIdentifier, name: $0.applicationName) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  // MARK: - Lifecycle

  /// Start capturing the given source. Bundle identifiers must match a
  /// running application exactly (the UI picks from `availableApps()`).
  public func start(source: CaptureConfiguration.AppAudioSource) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard let display = content.displays.first else { throw AppAudioError.noDisplay }

    let filter: SCContentFilter
    switch source {
    case .systemAudio:
      filter = SCContentFilter(display: display, excludingWindows: [])
    case .application(let bundleID):
      guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
        throw AppAudioError.applicationNotRunning(bundleID)
      }
      filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
    }

    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = Int(outputFormat.sampleRate)
    configuration.channelCount = Int(outputFormat.channelCount)
    // Only audio is consumed; keep the mandatory video path tiny. The frame
    // interval does not change audio arrival cadence (that follows the
    // audio clock) but a higher rate can slightly lower latency.
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
    configuration.queueDepth = 5

    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    try await stream.startCapture()
    self.stream = stream
  }

  public func stop() async {
    guard let stream else { return }
    self.stream = nil
    try? await stream.stopCapture()
  }

  // MARK: - SCStreamOutput

  public nonisolated func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio, sampleBuffer.isValid, let pcm = sampleBuffer.pcmBuffer else { return }
    do {
      // No explicit start time downstream; the analyzer sequences buffers
      // contiguously (see TranscriptionEngine).
      sink(try converter.convert(pcm, to: outputFormat))
    } catch {
      onError("app audio conversion failed: \(error.localizedDescription)")
    }
  }

  // MARK: - SCStreamDelegate

  public nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    onStopped("app audio capture stopped: \(error.localizedDescription)")
  }
}
