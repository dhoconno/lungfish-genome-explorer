import Foundation

public struct AsyncValidationSession<Input: Hashable, Output> {
    private var gate = AsyncRequestGate<Input>()

    public init() {}

    public mutating func begin(input: Input) -> AsyncRequestToken<Input> {
        gate.begin(identity: input)
    }

    public mutating func cancel() {
        gate.invalidate()
    }

    public func shouldAccept(resultFor token: AsyncRequestToken<Input>) -> Bool {
        gate.isCurrent(token)
    }
}
