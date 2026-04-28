import Foundation

public struct SelectionIdentityStore<ID: Hashable> {
    public private(set) var selectedIDs: Set<ID> = []

    public init() {}

    public mutating func select<S: Sequence>(_ ids: S) where S.Element == ID {
        selectedIDs = Set(ids)
    }

    public mutating func clear() {
        selectedIDs.removeAll()
    }

    public mutating func removeSelectionsNotVisible<S: Sequence>(in visibleIDs: S) where S.Element == ID {
        let visible = Set(visibleIDs)
        selectedIDs = selectedIDs.intersection(visible)
    }

    public func visibleIndexes(in visibleIDs: [ID]) -> IndexSet {
        var indexes = IndexSet()
        for (index, id) in visibleIDs.enumerated() where selectedIDs.contains(id) {
            indexes.insert(index)
        }
        return indexes
    }
}
