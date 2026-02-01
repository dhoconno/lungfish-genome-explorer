# Expert Review Meeting #002 - UI Architecture Decision

**Date**: Phase 1, UI Architecture Review
**Chair**: UI/UX Lead (Role 02)
**Attendees**: Swift Architect (01), Sequence Viewer (03), Track Rendering (04), Bioinformatics Architect (05)
**Topic**: Optimal window layout for a genome browser following Apple HIG

---

## Background

The original plan proposed a "three-pane" layout. Before implementation, experts were asked to evaluate whether this is the optimal visual metaphor for a genome browser on macOS.

---

## Expert Perspectives

### UI/UX Lead (Role 02) - Chair

**Assessment**: The three-pane layout is appropriate but needs refinement to match modern macOS patterns.

**Reference Applications Analyzed**:

| App | Layout | Why It Works |
|-----|--------|--------------|
| **Finder** | Sidebar + Content + Preview | File navigation paradigm |
| **Xcode** | Navigator + Editor + Inspector | Development workflow |
| **Mail** | Mailboxes + Messages + Message View | Hierarchical content |
| **Photos** | Albums + Grid + Detail | Media browsing |
| **Final Cut Pro** | Browser + Timeline + Viewer | Complex content editing |

**Key Insight**: Genome browsers most closely resemble **Xcode** or **Final Cut Pro** - complex scientific tools requiring:
1. Navigation/project structure (sidebar)
2. Primary content view (sequence/tracks)
3. Contextual information (inspector)

**Recommendation**: Adopt a **flexible panel architecture** rather than rigid three-pane:

```
┌─────────────────────────────────────────────────────────────┐
│                         TOOLBAR                              │
│  Navigation  │  Coordinates  │  Zoom  │  Tools  │  Search   │
├──────────────┼───────────────────────────────────┬──────────┤
│              │                                   │          │
│   SIDEBAR    │         MAIN VIEWER               │ INSPECTOR│
│   (optional) │         (always visible)          │ (optional│
│              │                                   │          │
│  - Projects  │  ┌─────────────────────────────┐  │ - Info   │
│  - Files     │  │    Track Header Area        │  │ - Props  │
│  - Favorites │  ├─────────────────────────────┤  │ - Edit   │
│              │  │                             │  │          │
│              │  │    Sequence + Tracks        │  │          │
│              │  │                             │  │          │
│              │  └─────────────────────────────┘  │          │
│              │                                   │          │
├──────────────┴───────────────────────────────────┴──────────┤
│                      STATUS BAR                              │
│  Position │ Selection │ Coverage │ Memory │ Progress        │
└─────────────────────────────────────────────────────────────┘
```

**Critical Design Points**:
1. **Collapsible panels** - Sidebar and Inspector should be hideable (⌥⌘S, ⌥⌘I)
2. **Focus on viewer** - Sequence/track area should dominate when expanded
3. **Full-height sidebar** - Modern macOS style with vibrancy
4. **Toolbar tracking** - Toolbar sections should align with split view dividers

---

### Swift Architecture Lead (Role 01)

**Assessment**: Agree with flexible panels. Technology recommendation:

| Component | Technology | Rationale |
|-----------|------------|-----------|
| Window | `NSWindowController` | Full control, document-based architecture |
| Main Split | `NSSplitViewController` | Native divider tracking, collapsing |
| Sidebar | `NSOutlineView` | Performance with large file trees |
| Inspector | SwiftUI in `NSHostingView` | Modern UI, simpler state management |
| Viewer | Custom `NSView` | Full rendering control for Metal |
| Settings | SwiftUI `Settings` scene | Modern approach |

**Why NOT pure SwiftUI NavigationSplitView**:
1. The sequence viewer requires custom `NSView` for Metal rendering
2. `NSOutlineView` outperforms SwiftUI `List` for large hierarchies
3. More control over divider behavior and keyboard focus
4. Hybrid approach: AppKit structure, SwiftUI where beneficial

**Proposed Architecture**:
```swift
// Window hierarchy
MainWindowController: NSWindowController
    └── MainSplitViewController: NSSplitViewController
            ├── SidebarViewController (NSOutlineView)
            ├── ContentSplitViewController: NSSplitViewController
            │       ├── ViewerViewController (custom NSView)
            │       └── InspectorViewController (NSHostingView<InspectorView>)
            └── (optional detail for three-column)
```

---

### Sequence Viewer Specialist (Role 03)

**Assessment**: Layout works well for sequence viewing needs.

**Viewer Requirements**:
1. **Maximize horizontal space** - Genomic coordinates are inherently linear
2. **Vertical track stacking** - Multiple data types need vertical real estate
3. **Coordinate synchronization** - All tracks must share ReferenceFrame
4. **Fast navigation** - Toolbar controls + keyboard shortcuts

**Proposed Viewer Internal Structure**:
```
┌──────────────────────────────────────────────────────┐
│ Track Header │ Rule/Coordinate Bar                    │
│    Panel     │                                        │
├──────────────┼────────────────────────────────────────┤
│              │                                        │
│   Track      │         Track Content Area             │
│   Labels     │         (Metal-rendered)               │
│   (fixed     │                                        │
│    width)    │   - Reference sequence                 │
│              │   - Annotations                        │
│              │   - Alignments                         │
│              │   - Coverage                           │
│              │                                        │
├──────────────┴────────────────────────────────────────┤
│              Horizontal Scrollbar                      │
└───────────────────────────────────────────────────────┘
```

**Key Point**: The viewer itself has internal subdivisions (track header vs content), which is separate from the app-level three-pane layout.

---

### Track Rendering Engineer (Role 04)

**Assessment**: Support the flexible panel approach.

**Track Panel Considerations**:
1. **Resizable tracks** - Users should be able to drag track heights
2. **Collapsible tracks** - Individual tracks can collapse to headers only
3. **Track reordering** - Drag to reorder (like IGV)
4. **Grouped tracks** - Related tracks (e.g., gene + exons) can group

**IGV Comparison**:
- IGV uses a similar panel layout with sidebar (optional), main panel, and feature panel
- Our approach is consistent with established genome browser UX

---

### Bioinformatics Architect (Role 05)

**Assessment**: Layout supports scientific workflows well.

**Workflow Considerations**:
1. **Data loading**: Sidebar shows available files/sequences
2. **Visualization**: Main viewer shows aligned data
3. **Analysis**: Inspector shows selected feature details, metrics
4. **Export**: Toolbar/menu actions operate on selection

**Alternative Layouts Considered**:

| Layout | Pros | Cons |
|--------|------|------|
| Single pane (viewer only) | Maximum viewer space | No navigation/details |
| Two pane (sidebar + viewer) | Simple, common | Inspector useful for details |
| Three pane (proposed) | Full workflow support | More complex |
| Tabbed (like browsers) | Multiple sessions | Loses context switching ease |
| Floating palettes | Flexible positioning | Can obscure content, harder to manage |

**Verdict**: Three-pane with collapsible panels is the correct choice for a professional scientific application.

---

## Consensus Decision

### Approved Architecture: **Flexible Three-Panel Layout**

```
┌─────────────────────────────────────────────────────────────┐
│                    UNIFIED TOOLBAR                           │
│  [◀▶] │ [chr1: 1,234,567-1,235,000 ▼] │ [−][+] │ [⚙] [🔍]  │
├────────────┬────────────────────────────────────┬───────────┤
│            │                                    │           │
│  SIDEBAR   │         SEQUENCE VIEWER            │ INSPECTOR │
│  (toggle)  │         (always present)           │ (toggle)  │
│            │                                    │           │
│ ▾ Project  │ ┌────┬──────────────────────────┐  │ Selection │
│   └ seq1   │ │Ref │ ATCGATCGATCGATCGATCG... │  │ ────────  │
│   └ seq2   │ ├────┼──────────────────────────┤  │ chr1:1234 │
│ ▾ Tracks   │ │Gene│ ▬▬▬▬▬▬▬  ▬▬▬▬▬▬▬▬▬▬▬▬  │  │ Length: 5 │
│   └ genes  │ ├────┼──────────────────────────┤  │           │
│   └ reads  │ │Cov │ ████████████████████    │  │ Features  │
│            │ └────┴──────────────────────────┘  │ ────────  │
│            │                                    │ BRCA1     │
└────────────┴────────────────────────────────────┴───────────┘
```

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Framework | AppKit primary | Metal rendering, performance |
| Split Controller | `NSSplitViewController` | Native panel management |
| Sidebar Visibility | Collapsible (⌥⌘S) | User preference |
| Inspector Visibility | Collapsible (⌥⌘I) | User preference |
| Default State | Sidebar visible, Inspector hidden | Focus on viewer |
| Toolbar | Unified, split-tracking | Modern macOS style |
| Touch Bar | Support for zoom/navigation | Power user feature |

### Implementation Technologies

| Component | Technology |
|-----------|------------|
| Main Window | `NSWindowController` + `NSWindow` |
| Split Layout | `NSSplitViewController` (nested) |
| Sidebar | `NSViewController` + `NSOutlineView` |
| Viewer | Custom `NSViewController` + `NSView` subclass |
| Inspector | `NSHostingController` + SwiftUI |
| Toolbar | `NSToolbar` with `NSToolbarItem` |
| Status Bar | `NSView` with `NSTextField` components |
| Settings | SwiftUI `Settings` scene |

---

## Window Behavior Specifications

### Panel Widths
- **Sidebar**: 200-300px (default 220px), collapsible
- **Inspector**: 250-400px (default 280px), collapsible
- **Viewer**: Flexible (fills remaining space, minimum 400px)

### State Persistence
- Remember panel visibility state per window
- Remember panel widths
- Remember window size and position
- Store in UserDefaults

### Keyboard Shortcuts
| Shortcut | Action |
|----------|--------|
| ⌥⌘S | Toggle sidebar |
| ⌥⌘I | Toggle inspector |
| ⌥⌘0 | Show/hide both panels |
| ⌘1 | Focus sidebar |
| ⌘2 | Focus viewer |
| ⌘3 | Focus inspector |

### Window Tabs
- Support `NSWindowTabGroup` for multiple projects
- ⌘T to open new tab
- Merge/split windows

---

## Action Items

1. **Swift Architect**: Create `MainWindowController` and `MainSplitViewController` skeleton
2. **UI/UX Lead**: Define toolbar items and menu structure
3. **Sequence Viewer**: Implement placeholder `ViewerViewController`
4. **Track Rendering**: Define `ReferenceFrame` protocol

---

## Alternative Considered: Document-Based vs Project-Based

**Question**: Should each file be a separate document window, or should we have project windows containing multiple files?

**Decision**: **Project-based windows**
- A single window contains a project with multiple sequences
- More like Xcode than TextEdit
- Better for scientific workflows where files are related
- Still support window tabs for multiple projects

---

## References

- [Apple HIG - Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [WWDC 2020 - Adopt the new look of macOS](https://developer.apple.com/videos/play/wwdc2020/10104/)
- [NSSplitViewController Documentation](https://developer.apple.com/documentation/appkit/nssplitviewcontroller)
- [NavigationSplitView in SwiftUI](https://developer.apple.com/documentation/swiftui/navigationsplitview)
- [Xcode Window Architecture](https://developer.apple.com/xcode/)
- [IGV Desktop Application](https://igv.org/doc/desktop/)
- [JBrowse 2 Architecture](https://link.springer.com/article/10.1186/s13059-023-02914-z)

---

*Meeting concluded. All experts approve the flexible three-panel architecture with collapsible sidebar and inspector.*
