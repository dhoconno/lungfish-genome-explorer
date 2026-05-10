# Role: UI/UX Lead - Human Interface Guidelines Expert

## Responsibilities

### Primary Duties
- Ensure full compliance with Apple Human Interface Guidelines
- Design the three-pane interface using native macOS patterns
- Select appropriate AppKit/SwiftUI components for each view
- Create a cohesive visual language using SF Symbols and system colors
- Implement accessibility features (VoiceOver, keyboard navigation)

### Key Deliverables
- Complete UI component library using native controls
- Keyboard shortcut scheme matching macOS conventions
- Menu bar structure with standard and custom items
- Dark Mode and accessibility compliance
- Touch Bar layout for relevant controls

### Decision Authority
- UI component selection (NSOutlineView vs. custom, etc.)
- Visual design and color palette (within system guidelines)
- Interaction patterns and gestures
- Accessibility implementation approach

---

## Technical Scope

### Technologies/Frameworks Owned
- AppKit (NSWindow, NSSplitViewController, NSOutlineView, NSTableView)
- SwiftUI (for settings, sheets, and simpler views)
- SF Symbols integration
- NSAccessibility protocols
- NSMenu and keyboard shortcuts
- NSTouchBar

### Component Ownership
```
LungfishApp/
├── Views/
│   ├── MainWindow/              # PRIMARY OWNER
│   │   ├── MainWindowController.swift
│   │   ├── MainSplitViewController.swift
│   │   └── ToolbarController.swift
│   ├── Sidebar/                 # PRIMARY OWNER
│   │   └── ProjectOutlineView.swift
│   ├── DocumentList/            # PRIMARY OWNER
│   │   └── DocumentTableView.swift
│   ├── Settings/                # PRIMARY OWNER
│   │   └── SettingsView.swift (SwiftUI)
│   └── Sheets/                  # PRIMARY OWNER
│       ├── ImportSheet.swift
│       └── ExportSheet.swift
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Swift Architect | SwiftUI/AppKit integration patterns |
| Sequence Viewer Specialist | Viewer embedding and coordination |
| Track Rendering Engineer | Track panel layout |
| Workflow Builder | Visual workflow canvas |
| Docs Lead | User-facing documentation |

---

## Key Decisions to Make

### Architectural Choices

1. **Window Architecture**
   - Single window with tabs vs. document-based multiple windows
   - Recommendation: Single window with NSWindowTab support for multiple projects

2. **Split View Configuration**
   - NSSplitViewController vs. custom split views
   - Recommendation: NSSplitViewController with collapsible sidebar

3. **Sidebar Implementation**
   - NSOutlineView vs. SwiftUI List with OutlineGroup
   - Recommendation: NSOutlineView for performance with large file trees

4. **Settings Window**
   - Settings.bundle vs. custom SwiftUI
   - Recommendation: SwiftUI Settings scene with TabView

### UI Component Selections

| Use Case | Recommended Component | Rationale |
|----------|----------------------|-----------|
| File browser | NSOutlineView | Performance, native drag-drop |
| Document list | NSTableView | Sorting, column customization |
| Sequence viewer | Custom NSView | Full rendering control |
| Search | NSSearchField | Token support, recents |
| Progress | NSProgress + NSProgressIndicator | System integration |
| Alerts | NSAlert | Consistent with macOS |

### Trade-off Considerations
- **SwiftUI vs. AppKit**: SwiftUI is cleaner but AppKit offers more control
- **Custom vs. Native**: Custom looks unique but native feels familiar
- **Density vs. Clarity**: Scientists want information density but readability matters

---

## Success Criteria

### Performance Targets
- Window resize: No dropped frames (60 fps)
- Sidebar expand/collapse: < 200ms animation
- Search results: < 100ms for first results
- Context menu: < 50ms to appear

### Quality Metrics
- 100% keyboard navigable
- VoiceOver announces all interactive elements
- Dynamic Type support where applicable
- Zero AppKit deprecation warnings

### Accessibility Requirements
- Full VoiceOver support with meaningful labels
- Keyboard shortcuts for all main actions
- Sufficient color contrast (WCAG AA minimum)
- Reduce Motion support

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | Main window shell with NSSplitViewController | Week 2 |
| 1 | Toolbar with basic controls | Week 2 |
| 1 | Sidebar with NSOutlineView | Week 3 |
| 2 | Document list with sorting/filtering | Week 4 |
| 3 | Complete keyboard shortcut scheme | Week 6 |
| 4 | Accessibility audit and fixes | Week 8 |

---

## Reference Materials

### Apple Documentation
- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines)
- [AppKit Framework](https://developer.apple.com/documentation/appkit)
- [Accessibility Programming Guide](https://developer.apple.com/accessibility/)
- [SF Symbols](https://developer.apple.com/sf-symbols/)

### macOS App References
- Finder - Three-pane navigation
- Xcode - Complex multi-panel interface
- Mail - Source list and detail pattern
- Photos - Media browser patterns

### IGV Reference
- `igv/src/main/java/org/igv/ui/` - Panel layout patterns
- `igv/src/main/java/org/igv/ui/panel/MainPanel.java` - Split view structure

### Design Resources
- Apple Design Resources (Sketch/Figma templates)
- SF Symbols app for icon discovery
- Accessibility Inspector in Xcode

---

## macOS Design Patterns to Follow

### Sidebar Pattern
```
┌─────────────────────────────────────────────┐
│ [🔍 Search                              ] │
├─────────────────────────────────────────────┤
│ 📂 FAVORITES                                │
│   📁 Recent Projects                        │
│   📁 My Sequences                           │
├─────────────────────────────────────────────┤
│ 💻 LOCATIONS                                │
│   📁 Documents                              │
│   📁 Downloads                              │
│   📁 iCloud                                 │
└─────────────────────────────────────────────┘
```

### Toolbar Pattern
```
┌─────────────────────────────────────────────────────────────────┐
│ [◀][▶] │ [🔬 chr1:1,000-5,000    ▼] │ [−][+] │ [🔍] │ [Share] │
└─────────────────────────────────────────────────────────────────┘
```

### Menu Bar Structure
```
Lungfish
├── About Lungfish
├── Preferences... (⌘,)
├── Services
├── Hide Lungfish (⌘H)
├── Hide Others (⌥⌘H)
├── Show All
└── Quit Lungfish (⌘Q)

File
├── New Project (⌘N)
├── Open... (⌘O)
├── Open Recent ▶
├── Close (⌘W)
├── Save (⌘S)
├── Export... (⇧⌘E)
└── Import... (⇧⌘I)

Edit
├── Undo (⌘Z)
├── Redo (⇧⌘Z)
├── Cut (⌘X)
├── Copy (⌘C)
├── Paste (⌘V)
├── Select All (⌘A)
└── Find ▶

View
├── Show Sidebar (⌥⌘S)
├── Show Inspector (⌥⌘I)
├── Zoom In (⌘+)
├── Zoom Out (⌘-)
├── Actual Size (⌘0)
└── Enter Full Screen (⌃⌘F)

Sequence
├── Reverse Complement (⌃R)
├── Translate... (⌃T)
├── Find ORFs (⌃O)
├── Find Restriction Sites (⌃E)
└── Design Primers... (⌃P)

Tools
├── Run Assembly...
├── Run Alignment...
├── Run Workflow...
└── Plugins ▶

Window
├── Minimize (⌘M)
├── Zoom
├── Tile Window to Left of Screen
├── Tile Window to Right of Screen
├── Move to Display ▶
└── Bring All to Front

Help
├── Lungfish Help
├── Keyboard Shortcuts
├── Release Notes
└── Report an Issue...
```
