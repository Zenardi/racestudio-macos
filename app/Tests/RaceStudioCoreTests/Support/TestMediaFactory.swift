import AVFoundation
import CoreVideo
import Foundation
@testable import RaceStudioCore

/// Synthetic footage written by the overlay-export tests (issue 9.13) with
/// `AVAssetWriter` — never committed, a few kilobytes each.
///
/// Every frame is one solid colour that **encodes its index**
/// (``colour(ofFrame:)``), so a frame read back from any output names the
/// source frame it came from (``frameIndex(red:green:blue:)``); the sound is
/// a 1 kHz sine.
enum TestMediaFactory {

    /// What to write.
    struct Spec {
        var width = 320
        var height = 180
        var frameRate = FrameGrid(numerator: 30, denominator: 1)
        var frames = 90
        var audio = true
        var rotation: FootageRotation = .none
        /// A white square in the stored frame's top-left corner, to tell its
        /// orientation.
        var marker = false

        /// The video's length in seconds.
        var duration: Double { Double(frames) * frameRate.frameDuration }
    }

    static let audioRate = 48_000.0
    static let markerSize = 40

    /// An 8-bit sRGB colour.
    struct RGB: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    /// The colour of frame `index`: each channel one of eight levels, 32
    /// apart, so a few levels of codec error never change the index read back.
    static func colour(ofFrame index: Int) -> RGB {
        func level(_ digit: Int) -> UInt8 { UInt8(16 + 32 * (digit % 8)) }
        return RGB(red: level(index), green: level(index / 8), blue: level(index / 64))
    }

    /// The frame index a colour read back encodes, or `nil` when it is no
    /// frame colour (an overlay pixel).
    static func frameIndex(red: UInt8, green: UInt8, blue: UInt8) -> Int? {
        func digit(_ byte: UInt8) -> Int? {
            let value = (Double(byte) - 16) / 32
            let rounded = value.rounded()
            return abs(value - rounded) < 0.35 && (0...7).contains(rounded) ? Int(rounded) : nil
        }
        guard let red = digit(red), let green = digit(green), let blue = digit(blue) else { return nil }
        return red + 8 * green + 64 * blue
    }

    /// Write a movie to `url` (`.mp4`).
    static func writeMovie(_ spec: Spec = Spec(), to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000],
            // Tagged Rec. 709 as cameras tag their footage: untagged SD-sized
            // video is read as BT.601 and colour-converted into the export.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ])
        video.expectsMediaDataInRealTime = false
        // The timescale cameras write 30 and 29.97 fps in: the writer's default
        // (600) cannot hold 1001/30000 s, and would round the frame times.
        video.mediaTimeScale = 30_000
        video.transform = transform(for: spec.rotation, width: spec.width, height: spec.height)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width, kCVPixelBufferHeightKey as String: spec.height
        ])
        writer.add(video)
        let audio = spec.audio ? audioInput() : nil
        if let audio { writer.add(audio) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var feed = Feed(spec: spec, audioFrames: spec.audio ? Int(spec.duration * audioRate) : 0)
        while !feed.isDone {
            if try feed.appendVideo(to: adaptor) || feed.appendAudio(to: audio) { continue }
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    /// Write `seconds` of the 1 kHz sine alone to `url` (`.m4a`): footage
    /// with no video track.
    static func writeAudioOnly(seconds: Double = 3, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let audio = audioInput()
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var feed = Feed(spec: Spec(frames: 0, audio: true), audioFrames: Int(seconds * audioRate))
        while !feed.isDone {
            if try feed.appendAudio(to: audio) { continue }
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    // MARK: - Internals

    private static func audioInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audioRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000
        ])
        input.expectsMediaDataInRealTime = false
        return input
    }

    /// The track matrix a camera writes for `rotation`.
    static func transform(for rotation: FootageRotation, width: Int, height: Int) -> CGAffineTransform {
        let (w, h) = (CGFloat(width), CGFloat(height))
        switch rotation {
        case .none: return .identity
        case .clockwise90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case .upsideDown: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .counterclockwise90: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        }
    }

    /// The samples still to append, interleaved by time.
    private struct Feed {
        let spec: Spec
        let audioFrames: Int
        var videoFrame = 0
        var audioFrame = 0
        static let chunk = 1_024

        var isDone: Bool { videoFrame >= spec.frames && audioFrame >= audioFrames }

        /// Appends whenever the input is ready — the writer's readiness flags do
        /// the interleaving (holding video back for the encoder's look-ahead
        /// would deadlock both inputs) — and marks the input finished after its
        /// last sample, or the writer waits on it for the other track forever.
        mutating func appendVideo(to adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> Bool {
            guard videoFrame < spec.frames, adaptor.assetWriterInput.isReadyForMoreMediaData else { return false }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.featureUnsupported) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.featureUnsupported) }
            TestMediaFactory.fill(buffer, frame: videoFrame, marker: spec.marker)
            let time = CMTime(value: CMTimeValue(videoFrame * spec.frameRate.denominator),
                              timescale: CMTimeScale(spec.frameRate.numerator))
            guard adaptor.append(buffer, withPresentationTime: time) else { throw CocoaError(.fileWriteUnknown) }
            videoFrame += 1
            if videoFrame == spec.frames { adaptor.assetWriterInput.markAsFinished() }
            return true
        }

        mutating func appendAudio(to input: AVAssetWriterInput?) throws -> Bool {
            guard let input, audioFrame < audioFrames, input.isReadyForMoreMediaData else { return false }
            let count = min(Self.chunk, audioFrames - audioFrame)
            guard input.append(try TestMediaFactory.sine(from: audioFrame, count: count)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            audioFrame += count
            if audioFrame == audioFrames { input.markAsFinished() }
            return true
        }
    }

    /// Paint `buffer` frame `index`'s colour, with the corner marker if asked.
    static func fill(_ buffer: CVPixelBuffer, frame index: Int, marker: Bool) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), height = CVPixelBufferGetHeight(buffer)
        let colour = colour(ofFrame: index)
        var pattern: [UInt8] = [colour.blue, colour.green, colour.red, 255]
        memset_pattern4(base, &pattern, rowBytes * height)
        guard marker else { return }
        var white: [UInt8] = [255, 255, 255, 255]
        for row in 0..<min(markerSize, height) {
            memset_pattern4(base + row * rowBytes, &white, markerSize * 4)
        }
    }

    /// `count` mono 16-bit samples of the 1 kHz sine, from sample `start`.
    private static func sine(from start: Int, count: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: audioRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        let samples = (start..<start + count).map { Int16(12_000 * sin(2 * .pi * 1_000 * Double($0) / audioRate)) }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: count * 2, flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        guard let format, let block else { throw CocoaError(.featureUnsupported) }
        samples.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                CMBlockBufferReplaceDataBytes(with: address, blockBuffer: block, offsetIntoDestination: 0,
                                              dataLength: count * 2)
            }
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(audioRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.featureUnsupported) }
        return sample
    }
}
