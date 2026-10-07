import Darwin
import Foundation
import Testing

/// Whether this process runs the tests that encode or decode video through
/// VideoToolbox (issue 200): a Mac does; a virtual machine does not.
///
/// GitHub's macOS runners are virtual machines that paravirtualize
/// VideoToolbox: every encode or decode session is a request to the host's
/// media engine. There those tests took 20 to 150 s each instead of about one,
/// failed decodes, wrote truncated exports, and once blocked for good creating
/// an encoder. They run on a Mac before every commit instead, and
/// `RACESTUDIO_VIDEO_TESTS` overrides the default: `1` runs them anywhere,
/// `0` skips them anywhere.
enum VideoTests {

    /// Run the video tests here?
    static let isEnabled = run(isVirtualMachine: isVirtualMachine,
                               override: ProcessInfo.processInfo.environment["RACESTUDIO_VIDEO_TESTS"])

    /// Why they are skipped where they are.
    static let skipReason: Comment =
        "VideoToolbox is paravirtualized in a virtual machine; set RACESTUDIO_VIDEO_TESTS=1 to run these here"

    /// The decision: `override` `"1"` runs them and `"0"` skips them; any
    /// other value leaves it to whether this is a virtual machine.
    static func run(isVirtualMachine: Bool, override: String?) -> Bool {
        switch override {
        case "1": true
        case "0": false
        default: !isVirtualMachine
        }
    }

    /// Whether macOS runs under a hypervisor (`kern.hv_vmm_present`).
    private static var isVirtualMachine: Bool {
        var present: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0 && present == 1
    }
}
