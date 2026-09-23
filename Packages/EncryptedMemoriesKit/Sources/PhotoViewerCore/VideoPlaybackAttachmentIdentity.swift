/// Identifies one concrete player attachment. A generation alone is insufficient when the same photo UID
/// is reopened after queued callbacks from its prior player have already reached the main actor.
public struct VideoPlaybackAttachmentIdentity: Equatable, Sendable {
    public let generation: UInt64
    private let playerID: ObjectIdentifier
    private let itemID: ObjectIdentifier

    public init(generation: UInt64, player: AnyObject, item: AnyObject) {
        self.generation = generation
        playerID = ObjectIdentifier(player)
        itemID = ObjectIdentifier(item)
    }

    public func matches(generation: UInt64, player: AnyObject, item: AnyObject) -> Bool {
        self.generation == generation
            && playerID == ObjectIdentifier(player)
            && itemID == ObjectIdentifier(item)
    }
}
