import PhotosCore
import SwiftUI

/// One titled progress row for lists and empty states on macOS, iOS, and iPadOS: a short title, a count line, and the
/// native determinate bar while the total is known. Without a total, `showsIndeterminateProgress` shows the native
/// indeterminate indicator next to the title instead. The row stays a standard list row; it draws no glass.
public struct ActivityProgressRow: View {
    private let title: String?
    private let detail: String?
    private let fraction: Double?
    private let showsIndeterminateProgress: Bool
    private let alignment: HorizontalAlignment

    public init(
        title: String?, detail: String? = nil, fraction: Double? = nil, showsIndeterminateProgress: Bool = false,
        alignment: HorizontalAlignment = .leading
    ) {
        self.title = title
        self.detail = detail
        self.fraction = fraction.map(ActivityProgressBar.clamped)
        self.showsIndeterminateProgress = showsIndeterminateProgress
        self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            if title != nil || (fraction == nil && showsIndeterminateProgress) {
                HStack(spacing: 8) {
                    if fraction == nil, showsIndeterminateProgress {
                        ProgressView()
                            .controlSize(.small)
                            .tint(ProtonColor.primary)
                    }
                    if let title {
                        Text(title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let fraction {
                ActivityProgressBar(fraction: fraction, accessibilityLabel: Self.accessibilityLabel(title, detail))
            }
        }
    }

    /// VoiceOver names the bar after the row's title, or after its count line when the row has no title. The bar
    /// itself reports the fraction as its value.
    nonisolated static func accessibilityLabel(_ title: String?, _ detail: String?) -> String? {
        title ?? detail
    }
}

/// The one determinate progress bar of macOS, iOS and iPadOS: the native linear bar in the app's primary color. It
/// takes the width its container offers; the detail text (count and percent) belongs above it, as in
/// `ActivityProgressRow`.
public struct ActivityProgressBar: View {
    private let fraction: Double
    private let accessibilityLabel: String?

    public init(fraction: Double, accessibilityLabel: String? = nil) {
        self.fraction = Self.clamped(fraction)
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        let bar = ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(ProtonColor.primary)
        if let accessibilityLabel {
            bar.accessibilityLabel(accessibilityLabel)
        } else {
            bar
        }
    }

    nonisolated static func clamped(_ fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }
}

/// Sizes a progress line inside an empty, waiting or overlay state: 70 % of the state's width, counted up to the
/// shared readable progress width, and at least 120 pt unless the state itself is narrower. Rows do not use this
/// layout; their bar takes the full row width. The line stays centered and is never measured and fed back into layout.
public struct ActivityProgressStateLayout: Layout {
    /// The one readable width of a progress line in a state.
    nonisolated static let readableWidth: CGFloat = 320
    nonisolated static let minimumWidth: CGFloat = 120
    nonisolated static let widthRatio: CGFloat = 0.7

    public init() {}

    nonisolated static func availableWidth(for proposal: CGFloat?) -> CGFloat {
        min(readableWidth, max(0, proposal ?? readableWidth))
    }

    nonisolated static func lineWidth(in available: CGFloat) -> CGFloat {
        min(available, max(minimumWidth, available * widthRatio))
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = Self.availableWidth(for: proposal.width)
        let line = subviews.first?.sizeThatFits(ProposedViewSize(width: Self.lineWidth(in: available), height: nil))
        return CGSize(width: available, height: line?.height ?? 0)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
            proposal: ProposedViewSize(width: Self.lineWidth(in: bounds.width), height: nil))
    }
}
