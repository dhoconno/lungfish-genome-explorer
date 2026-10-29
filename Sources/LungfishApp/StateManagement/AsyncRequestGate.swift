import Foundation

public struct AsyncRequestToken<Identity: Hashable>: Equatable {
    public let generation: UInt64
    public let identity: Identity

    /// Rebuilds a token from its two parts, as a completion that carried
    /// them across threads does before it asks the gate whether it is current.
    public init(generation: UInt64, identity: Identity) {
        self.generation = generation
        self.identity = identity
    }
}

public struct AsyncRequestGate<Identity: Hashable> {
    private var generation: UInt64 = 0
    private var activeIdentity: Identity?

    public init() {}

    public mutating func begin(identity: Identity) -> AsyncRequestToken<Identity> {
        generation &+= 1
        activeIdentity = identity
        return AsyncRequestToken(generation: generation, identity: identity)
    }

    public mutating func invalidate() {
        generation &+= 1
        activeIdentity = nil
    }

    public func isCurrent(_ token: AsyncRequestToken<Identity>) -> Bool {
        token.generation == generation && activeIdentity == token.identity
    }

    public func isCurrent(_ token: AsyncRequestToken<Identity>, expectedIdentity: Identity) -> Bool {
        isCurrent(token) && token.identity == expectedIdentity
    }
}
