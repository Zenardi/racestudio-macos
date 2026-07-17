import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `LinkedViewRegistry` / `CursorBroadcaster` (issue 4.7) — the
/// broadcast fan-out that keeps linked views in sync without a feedback loop.
@Suite struct LinkedViewRegistryTests {

    /// A linked view that counts the broadcasts it receives.
    private final class SpyView: CursorLinked {
        private(set) var notifications = 0
        private(set) var lastTime: Double?
        func cursorDidMove(to cursor: WorkspaceCursor) {
            notifications += 1
            lastTime = cursor.timePosition
        }
    }

    private func cursor() -> WorkspaceCursor {
        WorkspaceCursor(times: [0, 10], distances: [0, 100], time: 3)
    }

    @Test func test_broadcast_notifies_others_once() {
        let registry = LinkedViewRegistry()
        let a = SpyView(), b = SpyView(), c = SpyView()
        registry.register(a); registry.register(b); registry.register(c)

        registry.broadcast(cursor(), from: a)

        #expect(b.notifications == 1)
        #expect(c.notifications == 1)
        #expect(b.lastTime == 3, "the moved cursor is delivered")
    }

    @Test func test_broadcast_skips_originator() {
        let registry = LinkedViewRegistry()
        let a = SpyView(), b = SpyView()
        registry.register(a); registry.register(b)

        registry.broadcast(cursor(), from: a)

        #expect(a.notifications == 0, "the originator is not re-notified (no feedback loop)")
        #expect(b.notifications == 1)
    }

    @Test func test_unregister_stops_delivery() {
        let registry = LinkedViewRegistry()
        let a = SpyView(), b = SpyView()
        registry.register(a); registry.register(b)
        registry.unregister(b)

        registry.broadcast(cursor(), from: a)

        #expect(b.notifications == 0)
    }

    @Test func test_registering_twice_does_not_double_deliver() {
        let registry = LinkedViewRegistry()
        let a = SpyView(), b = SpyView()
        registry.register(a)
        registry.register(b)
        registry.register(b) // duplicate registration

        registry.broadcast(cursor(), from: a)

        #expect(b.notifications == 1, "a view registered twice is still notified once")
    }

    @Test func test_deallocated_view_is_skipped() {
        let registry = LinkedViewRegistry()
        let a = SpyView()
        registry.register(a)
        do {
            let transient = SpyView()
            registry.register(transient)
        } // `transient` deallocates here; the registry holds it weakly

        // Broadcasting must neither crash nor resurrect the dead view.
        registry.broadcast(cursor(), from: a)
        #expect(a.notifications == 0)
    }

    @Test func test_broadcast_through_the_broadcaster_protocol() {
        let registry = LinkedViewRegistry()
        let a = SpyView(), b = SpyView()
        registry.register(a); registry.register(b)

        let broadcaster: CursorBroadcaster = registry
        broadcaster.broadcast(cursor(), from: a)

        #expect(b.notifications == 1)
    }
}
