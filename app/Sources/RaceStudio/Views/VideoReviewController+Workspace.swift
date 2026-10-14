import Combine
import RaceStudioCore

/// The footage and its alignment are part of the session's workspace (issue
/// 9.20): it is saved whenever either changes, and handed back — through
/// ``VideoReviewController/restore(_:sessionStartEpoch:)`` — when the session
/// reopens.
extension VideoReviewController: WorkspaceVideo {
    var attachmentChanges: AnyPublisher<Void, Never> {
        Publishers.Merge3($attachment.dropFirst().map { _ in () },
                          review.$sync.dropFirst().map { _ in () },
                          review.$status.dropFirst().map { _ in () })
            .eraseToAnyPublisher()
    }
}
