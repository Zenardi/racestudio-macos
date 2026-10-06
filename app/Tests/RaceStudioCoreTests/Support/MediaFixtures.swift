import AVFoundation
import CoreVideo
import Foundation

/// Media generated inside the tests (issue 9.8) — synthetic tones and a
/// video-only movie, written to a temporary directory and never committed.
enum MediaFixtures {

    /// A fresh temporary directory for one test's files.
    static func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rsmedia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write `seconds` of a `freq` Hz tone (amplitude `amp`) at `rate` Hz on
    /// `channels` channels to `url` — WAV for a `.wav` name, AAC for `.m4a`.
    static func writeTone(to url: URL, freq: Double, seconds: Double, rate: Double = 48_000,
                          channels: AVAudioChannelCount = 2, amp: Float = 0.5) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: channels, interleaved: false) else {
            throw CocoaError(.featureUnsupported)
        }
        var settings = format.settings
        if url.pathExtension == "m4a" {
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                        AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 128_000]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData else { throw CocoaError(.featureUnsupported) }
        for i in 0..<Int(frames) {
            let sample = amp * Float(sin(2 * .pi * freq * Double(i) / rate))
            for channel in 0..<Int(channels) { data[channel][i] = sample }
        }
        buffer.frameLength = frames
        try file.write(from: buffer)
    }

    /// Write a short **video-only** movie (grey JPEG frames, no audio track).
    static func writeSilentMovie(to url: URL, frames: Int = 10) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.jpeg, AVVideoWidthKey: 64, AVVideoHeightKey: 64
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pixels: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixels)
            guard let pixels else { throw CocoaError(.featureUnsupported) }
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }
}
