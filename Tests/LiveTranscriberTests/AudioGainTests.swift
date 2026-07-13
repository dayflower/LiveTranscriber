import AVFAudio
import Foundation
import Testing

@testable import LiveTranscriberCore

@Suite("AudioGain")
struct AudioGainTests {
  private func floatBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    return buffer
  }

  private func int16Buffer(_ samples: [Int16]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      buffer.int16ChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    return buffer
  }

  private func passedSamples(_ gain: AudioGain, _ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    nonisolated(unsafe) var forwarded: AVAudioPCMBuffer?
    gain.tap { forwarded = $0 }(buffer)
    return forwarded!
  }

  @Test func scalesAndClampsFloatSamples() {
    let gain = AudioGain(2)
    let output = passedSamples(gain, floatBuffer([0.25, -0.25, 0.75, -0.75]))
    let samples = UnsafeBufferPointer(start: output.floatChannelData![0], count: 4)
    #expect(Array(samples) == [0.5, -0.5, 1, -1])
  }

  @Test func scalesAndClampsInt16Samples() {
    let gain = AudioGain(2)
    let output = passedSamples(gain, int16Buffer([1000, -1000, 20000, -20000]))
    let samples = UnsafeBufferPointer(start: output.int16ChannelData![0], count: 4)
    #expect(Array(samples) == [2000, -2000, Int16.max, Int16.min])
  }

  @Test func unityGainLeavesSamplesUntouched() {
    let gain = AudioGain()
    let output = passedSamples(gain, floatBuffer([0.25, -0.75]))
    let samples = UnsafeBufferPointer(start: output.floatChannelData![0], count: 2)
    #expect(Array(samples) == [0.25, -0.75])
  }

  @Test func gainCanBeChangedWhileFlowing() {
    let gain = AudioGain()
    gain.set(0.5)
    let output = passedSamples(gain, floatBuffer([0.5, -1]))
    let samples = UnsafeBufferPointer(start: output.floatChannelData![0], count: 2)
    #expect(Array(samples) == [0.25, -0.5])
  }
}
