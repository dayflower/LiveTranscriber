import AVFoundation
import Foundation

/// Captures an audio input device with `AVCaptureSession` and pushes converted
/// PCM buffers into a `sink` closure.
///
/// The sink receives buffers in the requested `outputFormat` on an internal
/// serial queue; downstream (engine input or mixer channel) must be safe to
/// call from there.
///
/// `@unchecked Sendable`: mutable state (`converter`) is only touched on the
/// internal serial queue.
public final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
  @unchecked Sendable
{
  /// A capturable audio input device, for presenting a picker in the UI.
  public struct Device: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isSystemDefault: Bool
  }

  public enum MicrophoneError: LocalizedError {
    case accessDenied
    case deviceNotFound(String)
    case setupFailed(String)

    public var errorDescription: String? {
      switch self {
      case .accessDenied:
        return
          "Microphone access is denied. Allow it in System Settings > Privacy & Security > Microphone."
      case .deviceNotFound(let id):
        return "Audio input device \"\(id)\" was not found."
      case .setupFailed(let reason):
        return "Could not set up microphone capture: \(reason)"
      }
    }
  }

  private let outputFormat: AVAudioFormat
  private let sink: @Sendable (AVAudioPCMBuffer) -> Void
  private let onError: @Sendable (String) -> Void
  private let converter = BufferConverter()
  private let queue = DispatchQueue(label: "live-transcriber.microphone")
  private let session = AVCaptureSession()

  public init(
    outputFormat: AVAudioFormat,
    sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
    onError: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.outputFormat = outputFormat
    self.sink = sink
    self.onError = onError
  }

  // MARK: - Device discovery

  private static func discoveredDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    ).devices
  }

  /// Capturable input devices, sorted by name, with the system default marked.
  public static func availableDevices() -> [Device] {
    let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
    return discoveredDevices()
      .map {
        Device(id: $0.uniqueID, name: $0.localizedName, isSystemDefault: $0.uniqueID == defaultID)
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// The system default input device, if any.
  public static func systemDefaultDevice() -> Device? {
    guard let device = AVCaptureDevice.default(for: .audio) else { return nil }
    return Device(id: device.uniqueID, name: device.localizedName, isSystemDefault: true)
  }

  // MARK: - Permission

  /// Ensure Microphone TCC access, prompting on first use.
  public static func requestAccess() async throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return
    case .notDetermined:
      guard await AVCaptureDevice.requestAccess(for: .audio) else {
        throw MicrophoneError.accessDenied
      }
    default:
      throw MicrophoneError.accessDenied
    }
  }

  // MARK: - Lifecycle

  /// Start capturing the device with the given `uniqueID`.
  public func start(deviceID: String) throws {
    guard let device = AVCaptureDevice(uniqueID: deviceID) else {
      throw MicrophoneError.deviceNotFound(deviceID)
    }

    session.beginConfiguration()
    defer { session.commitConfiguration() }

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw MicrophoneError.setupFailed("cannot add device input")
    }
    session.addInput(input)

    let output = AVCaptureAudioDataOutput()
    output.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(output) else {
      throw MicrophoneError.setupFailed("cannot add audio output")
    }
    session.addOutput(output)

    session.startRunning()
  }

  public func stop() {
    guard session.isRunning else { return }
    session.stopRunning()
  }

  // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

  public nonisolated func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard sampleBuffer.isValid, let pcm = sampleBuffer.pcmBuffer else { return }
    do {
      // Buffers carry no explicit start time downstream; the analyzer
      // sequences them contiguously (see TranscriptionEngine).
      sink(try converter.convert(pcm, to: outputFormat))
    } catch {
      onError("microphone conversion failed: \(error.localizedDescription)")
    }
  }
}
