import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `LinkedViewRegistry` / `CursorBroadcaster` (issue 4.7) — the
/// broadcast fan-out that keeps linked views in sync without a feedback loop.
@MainActor
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

    /// A counter shared with a view, so a broadcast to it is observable even
    /// after the view itself has deallocated.
    private final class Counter { var value = 0 }
    private final class CountingView: CursorLinked {
        let counter: Counter
        init(_ counter: Counter) { self.counter = counter }
        func cursorDidMove(to cursor: WorkspaceCursor) { counter.value += 1 }
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
        let counter = Counter()
        let live = SpyView()
        registry.register(live)
        do {
            let transient = CountingView(counter)
            registry.register(transient)
        } // `transient` deallocates here; the registry holds it weakly

        // Broadcast from a third view so both `live` and the dead `transient`
        // are non-originators; the dead view must be skipped (not resurrected).
        let originator = SpyView()
        registry.register(originator)
        registry.broadcast(cursor(), from: originator)

        #expect(live.notifications == 1, "the live view is still notified")
        #expect(counter.value == 0, "the deallocated view is never notified (its counter is untouched)")
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
