import Foundation
import Observation
import SwiftUI

/// One verified tip celebration. The piece plan stays stable while the native canvas animates it.
public struct TipJarCelebration: Identifiable, Sendable {
    public let id: UUID
    let startedAt: Date
    let pieces: [TipJarConfettiPiece]
}

/// Main-actor event source for the cross-platform tip celebration overlay.
@MainActor
@Observable
public final class TipJarCelebrationCoordinator {
    public static let shared = TipJarCelebrationCoordinator()

    public private(set) var activeCelebration: TipJarCelebration?

    private var nextSeed: UInt64 = 0x9E37_79B9_7F4A_7C15

    public init() {}

    @discardableResult
    public func celebrate() -> UUID {
        nextSeed &+= 1
        let celebration = TipJarCelebration(
            id: UUID(),
            startedAt: Date(),
            pieces: TipJarConfettiPlan.makePieces(seed: nextSeed)
        )
        activeCelebration = celebration
        return celebration.id
    }

    public func finish(celebrationID: UUID) {
        guard activeCelebration?.id == celebrationID else { return }
        activeCelebration = nil
    }
}

enum TipJarCelebrationMetrics {
    static let duration: TimeInterval = 4.2
    static let pieceCount = 180
    static let minimumPieceSize: CGFloat = 2.0
    static let maximumPieceSize: CGFloat = 4.2
}

struct TipJarConfettiPiece: Sendable {
    let x: CGFloat
    let startY: CGFloat
    let delay: TimeInterval
    let speed: CGFloat
    let size: CGFloat
    let aspect: CGFloat
    let sway: CGFloat
    let swayFrequency: CGFloat
    let phase: CGFloat
    let spin: CGFloat
    let tiltInfluence: CGFloat
    let colorIndex: Int
    let isDot: Bool
}

private enum TipJarConfettiPlan {
    static func makePieces(seed: UInt64) -> [TipJarConfettiPiece] {
        var generator = TipJarConfettiGenerator(seed: seed)
        return (0..<TipJarCelebrationMetrics.pieceCount).map { _ in
            TipJarConfettiPiece(
                x: generator.value(in: -0.02...1.02),
                startY: generator.value(in: -0.18...0.02),
                delay: TimeInterval(generator.value(in: 0.0...0.48)),
                speed: generator.value(in: 0.28...0.48),
                size: generator.value(
                    in: TipJarCelebrationMetrics.minimumPieceSize...TipJarCelebrationMetrics.maximumPieceSize
                ),
                aspect: generator.value(in: 0.55...1.0),
                sway: generator.value(in: 0.008...0.024),
                swayFrequency: generator.value(in: 2.0...5.0),
                phase: generator.value(in: 0.0...(2 * .pi)),
                spin: generator.value(in: -4.5...4.5),
                tiltInfluence: generator.value(in: 0.06...0.18),
                colorIndex: generator.integer(in: 0..<TipJarConfettiPalette.colors.count),
                isDot: generator.value(in: 0.0...1.0) > 0.34
            )
        }
    }
}

private struct TipJarConfettiGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func value(in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    mutating func integer(in range: Range<Int>) -> Int {
        range.lowerBound + Int(unit() * CGFloat(range.count))
    }

    private mutating func unit() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let sample = Double(state >> 11) / 9_007_199_254_740_992.0
        return CGFloat(sample)
    }
}

private enum TipJarConfettiPalette {
    static let colors: [Color] = [
        ProtonColor.primary,
        ProtonColor.brandMark,
        ProtonColor.warning,
        ProtonColor.danger,
        Color(red: 0.25, green: 0.72, blue: 0.92),
    ]
}

/// Non-interactive, full-surface celebration overlay for macOS, iOS, and iPadOS.
public struct TipJarCelebrationOverlay: View {
    @State private var coordinator = TipJarCelebrationCoordinator.shared

    private let horizontalBias: CGFloat

    public init(horizontalBias: CGFloat = 0) {
        self.horizontalBias = min(1, max(-1, horizontalBias))
    }

    public var body: some View {
        Group {
            if let celebration = coordinator.activeCelebration {
                TipJarConfettiRain(
                    celebration: celebration,
                    horizontalBias: horizontalBias,
                    onFinished: { coordinator.finish(celebrationID: celebration.id) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TipJarConfettiRain: View {
    let celebration: TipJarCelebration
    let horizontalBias: CGFloat
    let onFinished: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if reduceMotion {
                Canvas { context, size in
                    draw(
                        in: context,
                        size: size,
                        elapsed: 0.8
                    )
                }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let elapsed = max(
                            0,
                            timeline.date.timeIntervalSince(celebration.startedAt)
                        )
                        draw(in: context, size: size, elapsed: elapsed)
                    }
                }
            }
        }
        .task(id: celebration.id) {
            do {
                try await Task.sleep(for: .seconds(TipJarCelebrationMetrics.duration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }

    private func draw(
        in baseContext: GraphicsContext,
        size: CGSize,
        elapsed: TimeInterval
    ) {
        guard size.width > 0, size.height > 0 else { return }

        for piece in celebration.pieces {
            let fallTime = max(0, elapsed - piece.delay)
            let y = (piece.startY + CGFloat(fallTime) * piece.speed) * size.height
            guard y >= -size.height * 0.12, y <= size.height * 1.14 else { continue }

            let fallProgress = min(1.2, max(0, CGFloat(fallTime) * piece.speed))
            let sway =
                Foundation.sin(
                    CGFloat(fallTime) * piece.swayFrequency + piece.phase
                ) * piece.sway * size.width
            let x =
                piece.x * size.width
                + sway
                + horizontalBias * piece.tiltInfluence * fallProgress * size.width

            let fadeIn = min(1, max(0, CGFloat((elapsed - piece.delay) / 0.18)))
            let normalizedHeight = y / size.height
            let fadeOut = min(1, max(0, (1.14 - normalizedHeight) / 0.22))
            let opacity = fadeIn * fadeOut
            guard opacity > 0 else { continue }

            var context = baseContext
            context.translateBy(x: x, y: y)
            context.rotate(
                by: .radians(
                    Double(piece.phase + CGFloat(fallTime) * piece.spin + horizontalBias * 0.35)
                ))

            let width = piece.isDot ? piece.size : piece.size * piece.aspect
            let height = piece.isDot ? piece.size : piece.size
            let rect = CGRect(
                x: -width / 2,
                y: -height / 2,
                width: width,
                height: height
            )
            let color = TipJarConfettiPalette.colors[piece.colorIndex].opacity(Double(opacity))
            if piece.isDot {
                context.fill(Path(ellipseIn: rect), with: .color(color))
            } else {
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(width, height) * 0.35),
                    with: .color(color)
                )
            }
        }
    }
}
