import AppKit
import XCTest

/// Reads a table row's custom actions the way an accessibility client does.
///
/// AppKit answers `accessibilityRows()` with private `NSTableRow` proxies
/// whose children (`AXChildren`) are cell proxies. Only the cell proxies
/// forward `AXCustomActions`, to the cell view they stand for. Walking this
/// path from inside the process exercises the same forwarding the AX server
/// uses, so a passing assertion here means an external AX client sees the
/// actions too. The proxies are not `NSView`s and only speak the legacy
/// attribute API, hence the selector calls.
@MainActor
enum AccessibilityRowProbe {
    /// The AX row proxies of `table`, as AppKit hands them to the AX server.
    static func rowProxies(of table: NSTableView) -> [AnyObject] {
        let rows = (table.accessibilityRows() as NSArray?) ?? NSArray()
        return (0..<rows.count).map { rows.object(at: $0) as AnyObject }
    }

    /// The custom action names the row proxy itself reports.
    static func rowActionNames(_ rowProxy: AnyObject) -> [String] {
        actionNames(of: rowProxy)
    }

    /// The custom action names of each cell proxy under the row, in order.
    static func cellActionNames(_ rowProxy: AnyObject) -> [[String]] {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard rowProxy.responds(to: selector),
              let children = rowProxy.perform(selector, with: "AXChildren" as NSString)?.takeUnretainedValue() as? NSArray
        else { return [] }
        return (0..<children.count).map { actionNames(of: children.object(at: $0) as AnyObject) }
    }

    /// Runs the named custom action on the first cell proxy that offers it.
    static func performCellAction(named name: String, in rowProxy: AnyObject) -> Bool {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard let children = rowProxy.perform(selector, with: "AXChildren" as NSString)?.takeUnretainedValue() as? NSArray
        else { return false }
        for index in 0..<children.count {
            let child = children.object(at: index) as AnyObject
            if let action = actions(of: child).first(where: { $0.name == name }) {
                return action.handler?() ?? false
            }
        }
        return false
    }

    private static func actions(of element: AnyObject) -> [NSAccessibilityCustomAction] {
        let selector = NSSelectorFromString("accessibilityCustomActions")
        guard element.responds(to: selector),
              let array = element.perform(selector)?.takeUnretainedValue() as? NSArray
        else { return [] }
        return (0..<array.count).compactMap { array.object(at: $0) as? NSAccessibilityCustomAction }
    }

    private static func actionNames(of element: AnyObject) -> [String] {
        actions(of: element).map(\.name)
    }
}
