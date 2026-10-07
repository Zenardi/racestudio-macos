import Testing

/// Where the tests that encode or decode video run (issue 200): on a Mac,
/// not on a virtual machine, unless `RACESTUDIO_VIDEO_TESTS` says otherwise.
@Suite struct VideoTestsTests {

    @Test func test_a_mac_runs_the_video_tests() {
        #expect(VideoTests.run(isVirtualMachine: false, override: nil))
    }

    @Test func test_a_virtual_machine_skips_them() {
        #expect(!VideoTests.run(isVirtualMachine: true, override: nil))
    }

    @Test func test_one_runs_them_on_a_virtual_machine() {
        #expect(VideoTests.run(isVirtualMachine: true, override: "1"))
    }

    @Test func test_zero_skips_them_on_a_mac() {
        #expect(!VideoTests.run(isVirtualMachine: false, override: "0"))
    }

    @Test(arguments: ["", "yes", "true", " 1"])
    func test_any_other_value_leaves_the_default(_ value: String) {
        #expect(VideoTests.run(isVirtualMachine: false, override: value))
        #expect(!VideoTests.run(isVirtualMachine: true, override: value))
    }
}
