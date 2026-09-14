import Foundation

/// Aggregates the lifecycle phase of every UI scene of one account into a single execution opportunity.
///
/// One account runtime serves any number of windows. The runtime must not treat a window that moves to the
/// background as "the app went to the background" while another window is still active. This ledger keeps
/// the per-scene phases and answers with the most permissive opportunity: any active scene means foreground
/// active; otherwise any inactive scene means foreground inactive; only when every scene is in the
/// background (or no scene is connected) is background execution permitted. The OS background budget is a
/// separate limit that platform adapters continue to enforce.
public struct LibrarySceneActivityLedger: Equatable, Sendable {
    public enum ScenePhase: Int, Sendable, Comparable, Equatable {
        case active = 0
        case inactive = 1
        case background = 2

        public static func < (lhs: ScenePhase, rhs: ScenePhase) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private var phases: [String: ScenePhase] = [:]

    public init() {}

    public var sceneCount: Int { phases.count }
    public var isEmpty: Bool { phases.isEmpty }

    public func phase(of sceneID: String) -> ScenePhase? {
        phases[sceneID]
    }

    /// Records the phase of a scene and returns the aggregate opportunity after the update.
    @discardableResult
    public mutating func update(sceneID: String, phase: ScenePhase) -> LibraryExecutionOpportunity {
        phases[sceneID] = phase
        return opportunity
    }

    /// Forgets a disconnected scene and returns the aggregate opportunity after the removal.
    @discardableResult
    public mutating func remove(sceneID: String) -> LibraryExecutionOpportunity {
        phases.removeValue(forKey: sceneID)
        return opportunity
    }

    /// The account-wide execution opportunity implied by every connected scene.
    public var opportunity: LibraryExecutionOpportunity {
        guard let mostActive = phases.values.min() else { return .backgroundPermitted }
        switch mostActive {
        case .active: return .foregroundActive
        case .inactive: return .foregroundInactive
        case .background: return .backgroundPermitted
        }
    }
}
