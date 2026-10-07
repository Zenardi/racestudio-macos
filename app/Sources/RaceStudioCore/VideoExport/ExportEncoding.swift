import AVFoundation
import Foundation
import VideoToolbox

/// The encoder settings of an overlay export (issue 9.13): what the plan
/// decided, spelled as `AVAssetWriterInput` and `AVAssetReaderOutput`
/// dictionaries.
enum ExportEncoding {

    /// The video encoder's settings: the plan's codec, size and average bit
    /// rate, a keyframe every two seconds, Rec. 709 tags, and the hardware
    /// encoder preferred (VideoToolbox falls back to software without one).
    static func video(for plan: ExportPlan) -> [String: Any] {
        let fps = plan.footage.frameRate.framesPerSecond
        let profile: String
        switch plan.request.settings.codec {
        case .h264: profile = AVVideoProfileLevelH264HighAutoLevel
        case .hevc: profile = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        return [
            AVVideoCodecKey: plan.request.settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: plan.outputWidth,
            AVVideoHeightKey: plan.outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: max(Int((fps * 2).rounded()), 1),
                AVVideoProfileLevelKey: profile
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true
            ]
        ]
    }

    /// The timescale every frame time of `grid` is exact in: the smallest
    /// multiple of its rate's numerator that is at least 600 — 30000 for
    /// 29.97 fps, 600 for 25, 30 or 60. The writer's default, 600, cannot
    /// hold 1001/30000 s, and would round NTSC frame times by up to a
    /// millisecond.
    static func timescale(for grid: FrameGrid) -> CMTimeScale {
        let numerator = max(grid.numerator, 1)
        return CMTimeScale(clamping: numerator * max((600 + numerator - 1) / numerator, 1))
    }

    /// The AAC encoder's settings for `audio`: its rate where AAC takes it
    /// (44.1 or 48 kHz, else 48 kHz), mono or stereo, at `bitRate`.
    static func audio(for audio: FootageAudio, bitRate: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate(of: audio),
            AVNumberOfChannelsKey: channels(of: audio),
            AVChannelLayoutKey: channelLayout(channels(of: audio)),
            AVEncoderBitRateKey: bitRate
        ]
    }

    /// The decoded sound the encoder takes: 32-bit float PCM at the encoder's
    /// rate and channel count (downmixed when the footage has more).
    static func pcm(for audio: FootageAudio) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate(of: audio),
            AVNumberOfChannelsKey: channels(of: audio),
            AVChannelLayoutKey: channelLayout(channels(of: audio)),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }

    private static func sampleRate(of audio: FootageAudio) -> Double {
        [44_100, 48_000].contains(audio.sampleRate) ? audio.sampleRate : 48_000
    }

    private static func channels(of audio: FootageAudio) -> Int {
        audio.channels >= 2 ? 2 : 1
    }

    private static func channelLayout(_ channels: Int) -> Data {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }
}

extension EncoderAvailability {
    /// The encoders this Mac can actually use (hardware or software), checked
    /// once: a codec counts only if a 1080p compression session for it can be
    /// made — an encoder listed but unusable, as in a virtual machine without
    /// the media engine, does not.
    public static let system = EncoderAvailability(supportsHEVC: canEncode(kCMVideoCodecType_HEVC))

    /// Whether `makeSession` — VideoToolbox by default — can open a
    /// compression session for `codec`.
    static func canEncode(_ codec: CMVideoCodecType,
                          makeSession: (CMVideoCodecType) -> OSStatus = openCompressionSession) -> Bool {
        makeSession(codec) == noErr
    }

    /// Open, and at once close, a 1080p compression session for `codec`.
    private static func openCompressionSession(_ codec: CMVideoCodecType) -> OSStatus {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 1_920, height: 1_080, codecType: codec,
                                                encoderSpecification: nil, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status
    }
}
