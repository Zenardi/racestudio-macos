import Foundation

/// A view that participates in the linked-cursor workspace (issue 4.7): it is
/// notified when *another* view moves the shared cursor.
public protocol CursorLinked: AnyObject {
    /// Called when another registered view moves the shared cursor.
    func cursorDidMove(to cursor: WorkspaceCursor)
}

/// Broadcasts cursor moves to the linked views, skipping the originator so a
/// move never echoes back into a feedback loop (issue 4.7).
public protocol CursorBroadcaster: AnyObject {
    func broadcast(_ cursor: WorkspaceCursor, from origin: CursorLinked)
}

/// The registry of linked views and the broadcast fan-out (issue 4.7).
///
/// Views ``register(_:)`` on appear and ``unregister(_:)`` on disappear. A
/// ``broadcast(_:from:)`` reaches every *other* registered view exactly once.
/// Views are held weakly and keyed by identity, so a deallocated view is skipped
/// and registering the same view twice does not double-deliver.
public final class LinkedViewRegistry: CursorBroadcaster {

    /// A weak reference so the registry never keeps a view alive.
    private final class WeakBox {
        weak var value: CursorLinked?
        init(_ value: CursorLinked) { self.value = value }
    }

    private var views: [ObjectIdentifier: WeakBox] = [:]

    public init() {}

    /// Register `view` to receive broadcasts. Registering it again replaces the
    /// same entry (keyed by identity), so it is never notified twice.
    public func register(_ view: CursorLinked) {
        views[ObjectIdentifier(view)] = WeakBox(view)
    }

    /// Stop delivering broadcasts to `view`.
    public func unregister(_ view: CursorLinked) {
        views.removeValue(forKey: ObjectIdentifier(view))
    }

    /// Notify every registered view except `origin` that the cursor moved.
    public func broadcast(_ cursor: WorkspaceCursor, from origin: CursorLinked) {
        let originID = ObjectIdentifier(origin)
        for (id, box) in views where id != originID {
            box.value?.cursorDidMove(to: cursor)
        }
    }
}
