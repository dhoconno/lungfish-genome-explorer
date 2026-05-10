# Role: Track Rendering Engineer

## Responsibilities

### Primary Duties
- Implement the IGV-style track system with multiple track types
- Develop feature packing algorithms for annotations
- Create coverage visualization for alignment data
- Coordinate multi-track rendering and scrolling
- Build the track configuration and ordering UI

### Key Deliverables
- Track protocol and base implementations
- Feature track with row packing (IGV-style)
- Alignment track with coverage graph
- Coverage/signal track for BigWig data
- Variant track for VCF visualization
- Track configuration panel

### Decision Authority
- Track rendering strategies
- Feature packing algorithms
- Color schemes and visual representation
- Track height and density calculations

---

## Technical Scope

### Technologies/Frameworks Owned
- Core Graphics (track rendering)
- Metal (batch rendering for many features)
- Custom layout algorithms
- Color management

### Component Ownership
```
LungfishUI/
├── Tracks/
│   ├── Track.swift                    # PRIMARY OWNER - Protocol
│   ├── AbstractTrack.swift            # PRIMARY OWNER - Base class
│   ├── FeatureTrack.swift             # PRIMARY OWNER
│   ├── AlignmentTrack.swift           # PRIMARY OWNER
│   ├── CoverageTrack.swift            # PRIMARY OWNER
│   ├── VariantTrack.swift             # PRIMARY OWNER
│   └── TrackFactory.swift             # PRIMARY OWNER
├── Renderers/
│   ├── Renderer.swift                 # PRIMARY OWNER - Protocol
│   ├── FeatureRenderer.swift          # PRIMARY OWNER
│   ├── AlignmentRenderer.swift        # PRIMARY OWNER
│   ├── CoverageRenderer.swift         # PRIMARY OWNER
│   └── GeneRenderer.swift             # PRIMARY OWNER
├── Layout/
│   ├── FeaturePacker.swift            # PRIMARY OWNER
│   ├── RowPacker.swift                # PRIMARY OWNER
│   └── AlignmentPacker.swift          # PRIMARY OWNER
└── Rendering/
    ├── RenderContext.swift            # CO-OWNER with Sequence Viewer
    └── TrackPanel.swift               # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Sequence Viewer Specialist | Coordinate system, render context |
| File Format Expert | Data sources for tracks |
| UI/UX Lead | Track panel layout |
| Bioinformatics Architect | Feature data models |

---

## Key Decisions to Make

### Architectural Choices

1. **Track Rendering Strategy**
   - Immediate mode vs. retained mode
   - Recommendation: Retained mode with dirty rectangle tracking

2. **Feature Packing Algorithm**
   - First-fit vs. best-fit vs. next-fit
   - Recommendation: Interval tree with first-fit for O(log n) packing

3. **Display Modes**
   - Following IGV: collapsed, squished, expanded
   - Recommendation: Match IGV modes plus "auto" mode

4. **Color Schemes**
   - Hard-coded vs. theme-based vs. user-configurable
   - Recommendation: Theme-based with user override capability

### Algorithm Selections

**Feature Packing (Row Assignment)**
```swift
// Based on IGV's FeaturePacker pattern
class RowPacker {
    private var rows: [[PackedFeature]] = []

    func pack(features: [Feature], viewRange: Range<Int>) -> [[PackedFeature]] {
        rows.removeAll()

        for feature in features.sorted(by: { $0.start < $1.start }) {
            let row = findAvailableRow(for: feature)
            if row < rows.count {
                rows[row].append(PackedFeature(feature: feature, row: row))
            } else {
                rows.append([PackedFeature(feature: feature, row: row)])
            }
        }

        return rows
    }

    private func findAvailableRow(for feature: Feature) -> Int {
        for (index, row) in rows.enumerated() {
            if let last = row.last, last.end + minGap < feature.start {
                return index
            }
        }
        return rows.count
    }
}
```

**Coverage Calculation**
```swift
struct CoverageCalculator {
    func calculate(alignments: [Alignment], range: Range<Int>, binSize: Int) -> [Int] {
        var coverage = [Int](repeating: 0, count: (range.count + binSize - 1) / binSize)

        for alignment in alignments {
            for pos in alignment.start..<alignment.end {
                if range.contains(pos) {
                    let bin = (pos - range.lowerBound) / binSize
                    coverage[bin] += 1
                }
            }
        }

        return coverage
    }
}
```

### Trade-off Considerations
- **Accuracy vs. Speed**: Full feature rendering vs. density approximation at low zoom
- **Memory vs. Responsiveness**: Pre-packed features vs. on-demand packing
- **Flexibility vs. Consistency**: Customizable colors vs. standard color schemes

---

## Success Criteria

### Performance Targets
- Render 10,000 features in < 50ms
- Pack features into rows in < 10ms
- Coverage calculation for 1M reads in < 100ms
- Smooth scrolling with thousands of visible features

### Quality Metrics
- Correct overlap handling (no visual collisions)
- Accurate coverage calculation
- Consistent color application
- Proper handling of discontinuous features (e.g., exons)

### Track Types Required

| Track Type | Data Source | Display Elements |
|------------|-------------|------------------|
| Sequence | FASTA | Base letters, translation |
| Feature | GFF/GTF/BED | Boxes, arrows, labels |
| Gene | GFF/GenBank | Multi-level gene structure |
| Alignment | BAM/CRAM | Reads, pairs, coverage |
| Coverage | BigWig | Area/line graph |
| Variant | VCF | Markers, genotypes |

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | Track protocol and base class | Week 3 |
| 1 | Simple feature track | Week 4 |
| 2 | Feature packing algorithm | Week 5 |
| 2 | Alignment track with coverage | Week 6 |
| 3 | Gene track with multi-level display | Week 8 |
| 4 | Track configuration UI | Week 10 |

---

## Reference Materials

### IGV Code References
- `igv/src/main/java/org/igv/track/Track.java` - Track interface
- `igv/src/main/java/org/igv/track/FeatureTrack.java` - Feature track
- `igv/src/main/java/org/igv/renderer/IGVFeatureRenderer.java` - Feature rendering
- `igv/src/main/java/org/igv/sam/CoverageTrack.java` - Coverage calculation
- `igv/src/main/java/org/igv/sam/AlignmentPacker.java` - Read packing

### Key IGV Patterns
```java
// From Track.java
public enum DisplayMode {
    COLLAPSED, SQUISHED, EXPANDED
}

// From FeatureTrack - display mode heights
private int collapsedHeight = 25;
private int squishedHeight = 15;
private int expandedHeight = 35;
```

### Apple Documentation
- [Core Graphics Drawing](https://developer.apple.com/documentation/coregraphics)
- [NSBezierPath](https://developer.apple.com/documentation/appkit/nsbezierpath)
- [Color Management](https://developer.apple.com/documentation/appkit/color)

---

## Technical Specifications

### Track Protocol
```swift
protocol Track: AnyObject, Identifiable {
    var id: UUID { get }
    var name: String { get set }
    var height: CGFloat { get set }
    var isVisible: Bool { get set }
    var displayMode: DisplayMode { get set }

    var dataSource: any TrackDataSource { get }

    func isReady(for frame: ReferenceFrame) -> Bool
    func load(for frame: ReferenceFrame) async throws
    func render(context: RenderContext, rect: CGRect)
    func valueString(at position: GenomicPosition, y: CGFloat) -> String?
}

enum DisplayMode: String, CaseIterable {
    case collapsed
    case squished
    case expanded
    case auto

    var rowHeight: CGFloat {
        switch self {
        case .collapsed: return 25
        case .squished: return 12
        case .expanded: return 35
        case .auto: return 25
        }
    }
}
```

### Feature Rendering
```swift
struct FeatureRenderer {
    func render(features: [PackedFeature], context: RenderContext, rect: CGRect) {
        for packed in features {
            let y = rect.minY + CGFloat(packed.row) * rowHeight
            let x1 = context.frame.screenPosition(for: Double(packed.feature.start))
            let x2 = context.frame.screenPosition(for: Double(packed.feature.end))
            let featureRect = CGRect(x: x1, y: y, width: x2 - x1, height: featureHeight)

            // Draw feature box
            let color = colorForFeature(packed.feature)
            context.graphics.setFillColor(color.cgColor)
            context.graphics.fill(featureRect)

            // Draw arrow for strand
            if packed.feature.strand == .positive || packed.feature.strand == .negative {
                drawStrandArrow(context: context, rect: featureRect, strand: packed.feature.strand)
            }

            // Draw label if space permits
            if featureRect.width > 50 {
                drawLabel(packed.feature.name, in: featureRect, context: context)
            }
        }
    }
}
```

### Coverage Graph
```swift
struct CoverageRenderer {
    func render(coverage: [Int], context: RenderContext, rect: CGRect) {
        let maxCoverage = coverage.max() ?? 1
        let binWidth = rect.width / CGFloat(coverage.count)

        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))

        for (index, value) in coverage.enumerated() {
            let x = rect.minX + CGFloat(index) * binWidth
            let height = (CGFloat(value) / CGFloat(maxCoverage)) * rect.height
            let y = rect.maxY - height
            path.line(to: CGPoint(x: x, y: y))
        }

        path.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.close()

        NSColor.systemBlue.withAlphaComponent(0.5).setFill()
        path.fill()
    }
}
```
