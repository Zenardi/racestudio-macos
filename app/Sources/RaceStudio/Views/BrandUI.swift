import SwiftUI
import RaceStudioCore

/// Shared, brand-tokenized building blocks for the SwiftUI shell (issue 7.5, #143).
///
/// Every colour, font, gap, and icon here comes from the `RaceStudioCore` ``Theme``
/// via `\.theme`, resolving per light/dark ``ColorScheme`` — so the app's designed
/// **empty / loading / error** states and common chrome are drawn once, from the
/// same tokens the reference screen (7.3) uses, instead of ad-hoc `.secondary`
/// text scattered per view. Presentation only: these carry no logic.

/// The semantic role of a designed state — picks a WCAG-AA-proven tint.
enum BrandStateRole {
    case info
    case success
    case error
}

/// A designed state — never a blank screen: a tinted SF Symbol, a title, an
/// optional message, and an optional action, centered and drawn from the ``Theme``.
/// Replaces hand-rolled `VStack`s of `.largeTitle` + `.secondary` text.
struct BrandStateView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    let role: BrandStateRole
    let symbol: String
    let title: String
    var message: String?
    var actionLabel: String?
    var action: (() -> Void)?

    init(role: BrandStateRole = .info, symbol: String, title: String,
         message: String? = nil, actionLabel: String? = nil, action: (() -> Void)? = nil) {
        self.role = role
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        VStack(spacing: theme.spacing.sm) {
            // The icon + title + message read as one VoiceOver element; the action
            // button stays OUTSIDE this group so it remains an independently
            // focusable, activatable control (combining it would hide the action).
            VStack(spacing: theme.spacing.sm) {
                Image(systemName: symbol)
                    .font(.token(theme.typography.largeTitle))   // scales with Dynamic Type
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.token(theme.typography.headline))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.token(theme.typography.callout))
                        .foregroundStyle(theme.palette.textSecondary.color(scheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.palette.accent.color(scheme))
                    .padding(.top, theme.spacing.xs)
            }
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconColor: Color {
        switch role {
        case .info: return theme.palette.textSecondary.color(scheme)
        case .success: return theme.palette.positive.color(scheme)
        case .error: return theme.palette.negative.color(scheme)
        }
    }
}

/// A designed loading state: a spinner (indeterminate) or a determinate bar, with
/// a themed label and the brand accent tint, plus an optional Cancel.
struct BrandLoadingView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    let title: String
    var value: Double?
    var cancel: (() -> Void)?

    init(_ title: String, value: Double? = nil, cancel: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.cancel = cancel
    }

    var body: some View {
        VStack(spacing: theme.spacing.md) {
            progress
                .tint(theme.palette.accent.color(scheme))
            if let cancel {
                Button("Cancel", action: cancel)
            }
        }
        .padding(theme.spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var progress: some View {
        let label = Text(title)
            .font(.token(theme.typography.callout))
            .foregroundStyle(theme.palette.textSecondary.color(scheme))
        if let value {
            ProgressView(value: value) { label }.frame(width: 240)
        } else {
            ProgressView { label }
        }
    }
}

private struct BrandCanvasModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(theme.palette.background.color(scheme))
    }
}

extension View {
    /// Fills the view's background with the brand canvas token for the appearance.
    func brandCanvas() -> some View { modifier(BrandCanvasModifier()) }
}

private struct BrandGlassCardModifier: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let radius: Double
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(theme.palette.separator.color(scheme)))
    }
}

extension View {
    /// A translucent **glass** card surface — a SwiftUI `Material` (the macOS-13-safe
    /// precursor to iOS/macOS-26 Liquid Glass), with a hairline brand border. The
    /// single place the app's "glass chrome" is defined, so it can later be swapped
    /// for `.glassEffect()` behind `#available` without touching call sites.
    ///
    /// Reserved for chrome/containers: `.regularMaterial` is Apple's most legible
    /// content material, and the brand text drawn on it stays high-contrast
    /// (`textPrimary`/`textSecondary`). Text whose contrast must be *proven* keeps a
    /// solid surface token instead.
    func brandGlassCard(cornerRadius radius: Double) -> some View {
        modifier(BrandGlassCardModifier(radius: radius))
    }
}
