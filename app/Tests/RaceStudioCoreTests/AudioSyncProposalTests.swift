import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.8 auto-sync **proposal** and **availability**: an
/// engine-sound estimate becomes a one-click proposal only when the core calls
/// it confident; anything weaker reads "No confident match"; and the button
/// explains itself when there is no video, no audio or no RPM to match.
@Suite struct AudioSyncProposalTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    private func estimate(offset: Double = -9.5, confident: Bool, confidence: Double = 0.9) -> AudioSyncEstimate {
        AudioSyncEstimate(offset: offset, score: 2.5, peakRatio: confident ? 3.4 : 1.1,
                          pitchPerRPM: 1.0 / 120.0, isConfident: confident, confidence: confidence)
    }

    // MARK: - Proposal

    /// A confident estimate becomes a confident proposal, its offset moved onto
    /// the video's clock by where the decoded audio starts.
    @Test func test_a_confident_estimate_is_proposed_on_the_video_clock() {
        let proposal = AudioSyncProposal(estimate: estimate(offset: -9.5, confident: true), audioStart: 0.25)

        #expect(proposal == .confident(offset: -9.25, confidence: 0.9))
        #expect(proposal.isApplicable)
        #expect(proposal.offset == -9.25)
    }

    /// A non-finite offset is no proposal at all, and a confidence outside
    /// `0...1` is clamped so it always persists.
    @Test func test_a_malformed_estimate_is_sanitised() {
        let nanOffset = AudioSyncEstimate(offset: .nan, score: 3, peakRatio: 3, pitchPerRPM: 1.0 / 120,
                                          isConfident: true, confidence: 0.9)
        let overconfident = AudioSyncEstimate(offset: 2, score: 3, peakRatio: 9, pitchPerRPM: 1.0 / 120,
                                              isConfident: true, confidence: 1.000_000_1)

        #expect(AudioSyncProposal(estimate: nanOffset, audioStart: 0) == .unavailable(.estimationFailed))
        #expect(AudioSyncProposal(estimate: overconfident, audioStart: 0) == .confident(offset: 2, confidence: 1))
    }

    /// A weak estimate is reported, never offered for one-click apply.
    @Test func test_a_weak_estimate_is_not_applicable() {
        let proposal = AudioSyncProposal(estimate: estimate(confident: false, confidence: 0.3), audioStart: 0)

        #expect(proposal == .weak(offset: -9.5, confidence: 0.3))
        #expect(!proposal.isApplicable)
        #expect(proposal.headline(locale: en) == "No confident match")
        #expect(proposal.headline(locale: ptBR) == "Nenhuma correspondência confiável")
        #expect(proposal.detail(locale: en)
                == "The engine sound does not line up with the RPM clearly enough to trust. "
                + "Align on a lap start instead.")
    }

    /// A confident proposal says where it would put the footage and how sure it is.
    @Test func test_a_confident_proposal_reads_its_offset_and_confidence() {
        let proposal = AudioSyncProposal.confident(offset: -113.632, confidence: 0.96)

        #expect(proposal.headline(locale: en) == "Engine sound matches the RPM at −113.632 s")
        #expect(proposal.headline(locale: ptBR) == "O som do motor coincide com o RPM em −113,632 s")
        #expect(proposal.detail(locale: en) == "Confidence: 96%")
        #expect(proposal.detail(locale: ptBR) == "Confiança: 96%")
        #expect(proposal.confidence == 0.96)
    }

    /// The confidence bar speaks its level for any estimated proposal.
    @Test func test_confidence_text_names_the_level() {
        #expect(AudioSyncProposal.weak(offset: 1, confidence: 0.3).confidenceText(locale: en) == "Confidence: 30%")
        #expect(AudioSyncProposal.confident(offset: 1, confidence: 0.91).confidenceText(locale: ptBR)
                == "Confiança: 91%")
        #expect(AudioSyncProposal.unavailable(.silentAudio).confidenceText(locale: en) == nil)
    }

    /// An unavailable result names its reason and carries no offset.
    @Test func test_an_unavailable_proposal_reads_its_reason() {
        let proposal = AudioSyncProposal.unavailable(.flatRPM)

        #expect(!proposal.isApplicable)
        #expect(proposal.offset == nil)
        #expect(proposal.confidence == nil)
        #expect(proposal.headline(locale: en) == "The RPM never changes, so there is nothing to match.")
        #expect(proposal.detail(locale: en) == nil)
    }

    /// Every failure reads as a sentence in both languages.
    @Test(arguments: AudioSyncFailure.allCases)
    func test_every_failure_has_a_message(failure: AudioSyncFailure) {
        #expect(!L10n.isFlagged(failure.message(locale: en)))
        #expect(!L10n.isFlagged(failure.message(locale: ptBR)))
        #expect(failure.message(locale: en) != failure.message(locale: ptBR))
    }

    // MARK: - Progress

    /// Reading reports how far through the audio it is; matching has no
    /// fraction (an indeterminate bar).
    @Test func test_phases_read_as_progress() {
        #expect(AudioSyncPhase.reading(0.42).label(locale: en) == "Reading the video's audio… 42%")
        #expect(AudioSyncPhase.reading(0.42).label(locale: ptBR) == "Lendo o áudio do vídeo… 42%")
        #expect(AudioSyncPhase.matching.label(locale: en) == "Matching the engine sound to the RPM…")
        #expect(AudioSyncPhase.reading(0.42).fraction == 0.42)
        #expect(AudioSyncPhase.reading(7).fraction == 1)
        #expect(AudioSyncPhase.matching.fraction == nil)
    }

    // MARK: - Availability

    /// With footage that has audio, an RPM channel and an estimator, the
    /// button is live and its help says what it does.
    @Test func test_auto_sync_is_available_with_audio_and_rpm() {
        let availability = AudioSyncAvailability.evaluate(hasVideo: true, hasAudioTrack: true,
                                                          rpmChannel: "RPM", canEstimate: true)

        #expect(availability == .available)
        #expect(availability.isAvailable)
        #expect(availability.help(locale: en).hasPrefix("Estimate the offset by matching the engine sound"))
    }

    /// Each missing ingredient disables the button with its own reason, checked
    /// in the order the operator can fix them.
    @Test func test_auto_sync_is_disabled_with_a_reason() {
        let noVideo = AudioSyncAvailability.evaluate(hasVideo: false, hasAudioTrack: nil,
                                                     rpmChannel: "RPM", canEstimate: true)
        let checking = AudioSyncAvailability.evaluate(hasVideo: true, hasAudioTrack: nil,
                                                      rpmChannel: "RPM", canEstimate: true)
        let silentFile = AudioSyncAvailability.evaluate(hasVideo: true, hasAudioTrack: false,
                                                        rpmChannel: "RPM", canEstimate: true)
        let noRPM = AudioSyncAvailability.evaluate(hasVideo: true, hasAudioTrack: true,
                                                   rpmChannel: nil, canEstimate: true)
        let noCore = AudioSyncAvailability.evaluate(hasVideo: true, hasAudioTrack: true,
                                                    rpmChannel: "RPM", canEstimate: false)

        #expect(noVideo == .unavailable(.noVideo))
        #expect(checking == .unavailable(.checkingAudio))
        #expect(silentFile == .unavailable(.noAudioTrack))
        #expect(noRPM == .unavailable(.noRPMChannel))
        #expect(noCore == .unavailable(.unsupported))
        #expect(!noRPM.isAvailable)
        #expect(silentFile.help(locale: en) == "This video has no audio track to match.")
        #expect(noRPM.help(locale: en) == "This session has no RPM channel to match the engine sound against.")
        #expect(noRPM.help(locale: ptBR) == "Esta sessão não tem canal de RPM para comparar com o som do motor.")
    }

    /// Every reason reads as a sentence in both languages.
    @Test(arguments: AudioSyncAvailability.Reason.allCases)
    func test_every_reason_has_help(reason: AudioSyncAvailability.Reason) {
        let availability = AudioSyncAvailability.unavailable(reason)

        #expect(!L10n.isFlagged(availability.help(locale: en)))
        #expect(!L10n.isFlagged(availability.help(locale: ptBR)))
    }
}
