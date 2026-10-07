import Foundation

/// Which video encoders this Mac has (issue 9.13) — what lets a plan reject
/// an HEVC export up front instead of failing mid-encode.
public struct EncoderAvailability: Equatable, Sendable {
    /// Whether an HEVC encoder (hardware or software) is installed.
    public let supportsHEVC: Bool

    public init(supportsHEVC: Bool) {
        self.supportsHEVC = supportsHEVC
    }

    /// Every codec available — for tests and previews.
    public static let all = EncoderAvailability(supportsHEVC: true)

    /// Whether `codec` can be encoded.
    public func supports(_ codec: ExportCodec) -> Bool {
        switch codec {
        case .h264: return true
        case .hevc: return supportsHEVC
        }
    }
}

extension ExportCodec {
    /// The longest frame edge the codec carries, in pixels: H.264 level 5.2
    /// tops out at 4096 wide; HEVC at the renderer's 8K limit.
    var maximumEdge: Int {
        switch self {
        case .h264: return 4_096
        case .hevc: return OverlayRenderer.maximumDimension
        }
    }

    /// The most pixels in one frame: H.264 level 5.2's 4096 × 2304; HEVC 8K.
    var maximumPixels: Int {
        switch self {
        case .h264: return 4_096 * 2_304
        case .hevc: return 8_192 * 4_320
        }
    }

    /// The smallest frame edge encoded, in pixels.
    static let minimumEdge = 16

    /// Bits per output pixel per frame the size estimate and the encoder's
    /// average bit rate use: about 12 Mb/s for 1080p30 H.264 and 7.5 Mb/s for
    /// HEVC — the rates YouTube recommends for uploads of that size.
    var bitsPerPixel: Double {
        switch self {
        case .h264: return 0.2
        case .hevc: return 0.12
        }
    }
}
