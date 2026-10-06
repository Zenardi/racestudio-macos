import Foundation

/// One role bound to one session channel (issue 9.9): which channel feeds the
/// role, and how its values convert into the unit the frame reports.
public struct TelemetryChannelBinding: Equatable, Sendable {
    /// The role this channel plays.
    public let role: TelemetryRole
    /// The channel's index in the session's channel listing — the index the data
    /// source reads samples by.
    public let channelIndex: Int
    /// The channel's name as the session lists it.
    public let channelName: String
    /// The unit the channel is logged in.
    public let sourceUnit: String
    /// The unit the frame reports the role in: the role's canonical unit when
    /// the source unit converts into it, else the source unit (pass-through).
    public let unit: String
    /// Source value → reported value.
    public let conversion: UnitConversion

    public init(role: TelemetryRole, channelIndex: Int, channelName: String,
                sourceUnit: String, unit: String, conversion: UnitConversion) {
        self.role = role
        self.channelIndex = channelIndex
        self.channelName = channelName
        self.sourceUnit = sourceUnit
        self.unit = unit
        self.conversion = conversion
    }
}

/// Which session channel plays each ``TelemetryRole`` (issue 9.9) — the overlay's
/// view of a session's channels, also what the layout (sibling issue) checks
/// widget availability against.
///
/// ``resolve(channels:)`` walks each role's ordered candidate names and binds the
/// first channel that matches by name (case- and whitespace-insensitive), has
/// samples, and is logged in a unit the role accepts. A role with no such
/// channel stays unbound, so the frame reports `nil` for it. ``overriding(_:with:)``
/// lets a later UI remap a role by hand.
public struct TelemetryChannelMap: Equatable, Sendable {

    /// The logger's own running-delta channels, most preferred first — offered
    /// as an alternative to the computed live delta (``DeltaSource/logger(channel:)``).
    /// `Predictive Time` is a predicted lap *time*, not a delta, so it is not one.
    public static let loggerDeltaCandidates = ["Best Run Diff", "Best Today Diff", "Ref Lap Diff", "Prev Lap Diff"]

    /// The session's channel listing the map was resolved against.
    public let channels: [Channel]
    private var bindings: [TelemetryRole: TelemetryChannelBinding]

    /// The logger delta channels this session carries, in preference order.
    public let loggerDeltaChannels: [String]

    private init(channels: [Channel], bindings: [TelemetryRole: TelemetryChannelBinding]) {
        self.channels = channels
        self.bindings = bindings
        self.loggerDeltaChannels = Self.loggerDeltaCandidates.filter { candidate in
            channels.contains { Self.normalized($0.name) == Self.normalized(candidate) && $0.sampleCount > 0 }
        }
    }

    /// Resolve every role against the session's `channels` (in listing order, so
    /// a binding's ``TelemetryChannelBinding/channelIndex`` is its read index).
    public static func resolve(channels: [Channel]) -> TelemetryChannelMap {
        var bindings: [TelemetryRole: TelemetryChannelBinding] = [:]
        for role in TelemetryRole.ordered {
            bindings[role] = firstMatch(for: role, in: channels)
        }
        return TelemetryChannelMap(channels: channels, bindings: bindings)
    }

    /// The channel bound to `role`, or `nil` when the session has none.
    public func binding(for role: TelemetryRole) -> TelemetryChannelBinding? {
        bindings[role]
    }

    /// Whether `role` has a channel.
    public func isAvailable(_ role: TelemetryRole) -> Bool {
        bindings[role] != nil
    }

    /// Every role that has a channel.
    public var availableRoles: Set<TelemetryRole> {
        Set(bindings.keys)
    }

    /// This map with `role` rebound to `channel` — a hand remap. `nil` unbinds
    /// the role, as does a channel this session does not list (it has no data to
    /// read). The channel's unit is converted when the role accepts it and
    /// passed through as-is otherwise: an explicit choice is honoured, and the
    /// binding's ``TelemetryChannelBinding/unit`` says what the values are in.
    public func overriding(_ role: TelemetryRole, with channel: Channel?) -> TelemetryChannelMap {
        var copy = self
        guard let channel, let index = channels.firstIndex(of: channel) else {
            copy.bindings[role] = nil
            return copy
        }
        let binding = Self.binding(role, channel: channel, index: index)
            ?? TelemetryChannelBinding(role: role, channelIndex: index, channelName: channel.name,
                                       sourceUnit: channel.unit, unit: channel.unit, conversion: .identity)
        copy.bindings[role] = binding
        return copy
    }

    // MARK: - Internals

    /// The first candidate (in the role's preference order) present in
    /// `channels` with samples and an accepted unit.
    private static func firstMatch(for role: TelemetryRole, in channels: [Channel]) -> TelemetryChannelBinding? {
        for candidate in role.candidateNames.map(normalized) {
            for (index, channel) in channels.enumerated()
            where channel.sampleCount > 0 && normalized(channel.name) == candidate {
                if let binding = binding(role, channel: channel, index: index) { return binding }
            }
        }
        return nil
    }

    /// `channel` bound to `role` when the role accepts its unit, else `nil`.
    private static func binding(_ role: TelemetryRole, channel: Channel, index: Int) -> TelemetryChannelBinding? {
        guard let conversion = role.conversion(fromUnit: channel.unit) else { return nil }
        return TelemetryChannelBinding(role: role, channelIndex: index, channelName: channel.name,
                                       sourceUnit: channel.unit, unit: role.canonicalUnit ?? channel.unit,
                                       conversion: conversion)
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
