// axdrive: play a timed list of accessibility steps against one app, in the background.
// It uses only AX actions (press, select, custom actions, menu items), so the app never
// needs to be frontmost and the step timing does not depend on whoever launched it.
//
//   swiftc -O -parse-as-library -o screencasts/.bin/axdrive screencasts/_shared/capture/axdrive.swift
//   axdrive --pid <pid> steps.json
//   axdrive --pid <pid> --dump [maxDepth]      print the AX tree of the main window
//   axdrive --pid <pid> steps.json --record <windowID> <out.mov> <seconds>
//        resolves the steps, starts wincap (next to this binary), then plays the steps
//
// steps.json is a list of objects, run in order:
//   {"wait": 1.5}
//   {"press": {"role": "AXButton", "title": "Zoom In"}}          first match, depth-first
//   {"menu": ["View", "Provenance Inspector"]}                    menu bar path
//   {"row": {"table": 1, "index": 3}}                             select row 3 of the Nth AXTable (1-based)
//   {"rowAction": {"table": 1, "index": 3, "action": "Zoom to Variant"}}
//   {"focus": {"role": "AXTextField", "title": "Position"}}
//   {"value": {"role": "AXTextField", "title": "Position", "text": "chr1:1-100"}}
//   {"confirm": {"role": "AXTextField", "title": "Position"}}      AXConfirm (Return in a field)
//   {"focusTable": {"table": 1}}                                  make the Nth AXTable take keyboard focus
//   {"key": "return"}  {"key": "cmd+opt+v"}                        keystroke posted to the app's process only
// Matching is on AXTitle, AXDescription or AXIdentifier (substring, case-insensitive).

import AppKit
import ApplicationServices
import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("axdrive: \(msg)\n".utf8))
    exit(1)
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}

func str(_ el: AXUIElement, _ name: String) -> String { attr(el, name) as? String ?? "" }

func children(_ el: AXUIElement) -> [AXUIElement] { attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

func matches(_ el: AXUIElement, role: String?, title: String?) -> Bool {
    if let role, str(el, kAXRoleAttribute) != role { return false }
    guard let title, !title.isEmpty else { return true }
    let needle = title.lowercased()
    return [kAXTitleAttribute, kAXDescriptionAttribute, "AXIdentifier"].contains { str(el, $0).lowercased().contains(needle) }
}

func find(in root: AXUIElement, role: String?, title: String?, nth: Int = 1, depth: Int = 60) -> AXUIElement? {
    var seen = 0
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    while !stack.isEmpty {
        let (el, d) = stack.removeFirst()
        if matches(el, role: role, title: title) {
            seen += 1
            if seen == nth { return el }
        }
        // Tables and outlines can hold thousands of rows. Rows are reached through row() instead.
        let r = str(el, kAXRoleAttribute)
        if d < depth, r != "AXTable", r != "AXOutline" { stack.append(contentsOf: children(el).map { ($0, d + 1) }) }
    }
    return nil
}

func mainWindow(_ app: AXUIElement) -> AXUIElement {
    if let w = attr(app, kAXMainWindowAttribute) { return w as! AXUIElement }
    if let ws = attr(app, kAXWindowsAttribute) as? [AXUIElement], let w = ws.first { return w }
    fail("no window")
}

func dump(_ el: AXUIElement, depth: Int, max: Int) {
    let pad = String(repeating: "  ", count: depth)
    let bits = [str(el, kAXRoleAttribute), str(el, kAXTitleAttribute), str(el, kAXDescriptionAttribute), str(el, "AXIdentifier")]
    print(pad + bits.filter { !$0.isEmpty }.joined(separator: " | "))
    let r = str(el, kAXRoleAttribute)
    if r == "AXTable" || r == "AXOutline" {
        print(pad + "  (\((attr(el, kAXRowsAttribute) as? [AXUIElement])?.count ?? 0) rows)")
        return
    }
    if depth < max { children(el).forEach { dump($0, depth: depth + 1, max: max) } }
}

// Walking the whole tree costs seconds on a busy window, so every lookup is resolved
// once (in the prepare pass, before any timing matters) and reused.
nonisolated(unsafe) var cache: [String: AXUIElement] = [:]

func element(_ spec: [String: Any], _ win: AXUIElement) -> AXUIElement {
    let role = spec["role"] as? String, title = spec["title"] as? String, nth = spec["nth"] as? Int ?? 1
    let key = "\(role ?? "*")|\(title ?? "*")|\(nth)"
    if let hit = cache[key] { return hit }
    guard let el = find(in: win, role: role, title: title, nth: nth) else {
        fail("no element role=\(role ?? "*") title=\(title ?? "*")")
    }
    cache[key] = el
    return el
}

func table(_ spec: [String: Any], _ win: AXUIElement) -> AXUIElement {
    element(["role": "AXTable", "title": spec["title"] as? String ?? "", "nth": spec["table"] as? Int ?? 1], win)
}

/// The Nth row currently on screen (1-based). Off-screen rows are not realised views.
func row(_ spec: [String: Any], _ win: AXUIElement) -> AXUIElement {
    let t = table(spec, win)
    let rows = attr(t, "AXVisibleRows") as? [AXUIElement] ?? []
    let i = (spec["index"] as? Int ?? 1) - 1
    guard rows.indices.contains(i) else { fail("table shows \(rows.count) rows, wanted \(i + 1)") }
    return rows[i]
}

let keyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 76, "tab": 48, "space": 49, "escape": 53, "delete": 51,
    "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46,
    "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
]

/// Posts a key chord straight to one process, so it reaches that app's key window
/// without bringing the app forward or touching whatever the user is typing into.
func postKey(_ chord: String, pid: pid_t) {
    var parts = chord.lowercased().split(separator: "+").map(String.init)
    guard let keyName = parts.popLast(), let code = keyCodes[keyName] else { fail("unknown key \(chord)") }
    var flags: CGEventFlags = []
    for m in parts {
        switch m {
        case "cmd": flags.insert(.maskCommand)
        case "opt", "alt": flags.insert(.maskAlternate)
        case "shift": flags.insert(.maskShift)
        case "ctrl": flags.insert(.maskControl)
        default: fail("unknown modifier \(m)")
        }
    }
    let src = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { fail("key event") }
        ev.flags = flags
        ev.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.02)
    }
}

func check(_ err: AXError, _ what: String) {
    if err != .success { fail("\(what) failed (AXError \(err.rawValue))") }
}

/// Resolves every element the steps name, so the timed pass only performs actions.
func prepare(_ app: AXUIElement, _ steps: [[String: Any]]) {
    let win = mainWindow(app)
    for step in steps {
        for key in ["press", "focus", "value", "confirm"] { if let s = step[key] as? [String: Any] { _ = element(s, win) } }
        for key in ["row", "rowAction", "focusTable"] { if let s = step[key] as? [String: Any] { _ = table(s, win) } }
    }
}

func run(pid: pid_t, steps: [[String: Any]], record: [String]?) {
    let app = AXUIElementCreateApplication(pid)
    let t = Date()
    prepare(app, steps)
    FileHandle.standardError.write(Data(String(format: "axdrive: prepared in %.1fs\n", Date().timeIntervalSince(t)).utf8))
    var recorder: Process?
    if let record {
        let wincap = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("wincap")
        let p = Process()
        p.executableURL = wincap
        p.arguments = ["--window", record[0], "--out", record[1], "--seconds", record[2]]
        do { try p.run() } catch { fail("could not start wincap: \(error)") }
        recorder = p
        Thread.sleep(forTimeInterval: 1.0) // let the stream deliver its first frames
    }
    defer { recorder?.waitUntilExit() }
    let win = mainWindow(app)
    for (n, step) in steps.enumerated() {
        let t0 = Date()
        if let s = step["wait"] as? Double {
            Thread.sleep(forTimeInterval: s)
        } else if let spec = step["press"] as? [String: Any] {
            check(AXUIElementPerformAction(element(spec, win), kAXPressAction as CFString), "press")
        } else if let path = step["menu"] as? [String] {
            guard var node = attr(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { fail("no menu bar") }
            for (i, title) in path.enumerated() {
                guard let next = find(in: node, role: i == 0 ? "AXMenuBarItem" : "AXMenuItem", title: title, depth: 3) else { fail("no menu item \(title)") }
                node = next
            }
            check(AXUIElementPerformAction(node, kAXPressAction as CFString), "menu")
        } else if let spec = step["row"] as? [String: Any] {
            check(AXUIElementSetAttributeValue(table(spec, win), kAXSelectedRowsAttribute as CFString, [row(spec, win)] as CFArray), "select row")
        } else if let spec = step["rowAction"] as? [String: Any] {
            let r = row(spec, win)
            var names: CFArray?
            AXUIElementCopyActionNames(r, &names)
            let wanted = (spec["action"] as? String ?? "").lowercased()
            guard let name = (names as? [String])?.first(where: { $0.lowercased().contains(wanted) }) else {
                fail("row has no action \(wanted); has \(names as? [String] ?? [])")
            }
            check(AXUIElementPerformAction(r, name as CFString), "row action")
        } else if let spec = step["focus"] as? [String: Any] {
            check(AXUIElementSetAttributeValue(element(spec, win), kAXFocusedAttribute as CFString, kCFBooleanTrue), "focus")
        } else if let spec = step["value"] as? [String: Any] {
            check(AXUIElementSetAttributeValue(element(spec, win), kAXValueAttribute as CFString, (spec["text"] as? String ?? "") as CFString), "set value")
        } else if let spec = step["confirm"] as? [String: Any] {
            check(AXUIElementPerformAction(element(spec, win), kAXConfirmAction as CFString), "confirm")
        } else if let spec = step["focusTable"] as? [String: Any] {
            check(AXUIElementSetAttributeValue(table(spec, win), kAXFocusedAttribute as CFString, kCFBooleanTrue), "focus table")
        } else if let chord = step["key"] as? String {
            postKey(chord, pid: pid)
        } else {
            fail("unknown step \(step)")
        }
        print(String(format: "%2d  %.2fs  %@", n, Date().timeIntervalSince(t0), String(describing: step)))
    }
}

@main
struct AXDrive {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard AXIsProcessTrusted() else { fail("this process is not trusted for accessibility") }
        guard let p = args.firstIndex(of: "--pid"), p + 1 < args.count, let pid = pid_t(args[p + 1]) else { fail("need --pid") }
        args.removeSubrange(p...p + 1)
        if let d = args.firstIndex(of: "--dump") {
            let max = d + 1 < args.count ? Int(args[d + 1]) ?? 12 : 12
            dump(mainWindow(AXUIElementCreateApplication(pid)), depth: 0, max: max)
            return
        }
        var record: [String]?
        if let r = args.firstIndex(of: "--record"), r + 3 < args.count {
            record = Array(args[r + 1...r + 3])
            args.removeSubrange(r...r + 3)
        }
        guard let file = args.first, let data = FileManager.default.contents(atPath: file),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { fail("need a steps.json list") }
        run(pid: pid, steps: steps, record: record)
    }
}
