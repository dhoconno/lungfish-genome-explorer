# Role: Sequence Viewer Specialist

## Responsibilities

### Primary Duties
- Develop the high-performance AppKit-based sequence viewer
- Implement base-level selection and editing interactions
- Create Metal shaders for GPU-accelerated rendering
- Build the tile-based caching system for smooth scrolling
- Handle text rendering for sequence bases at various zoom levels

### Key Deliverables
- Custom NSView subclass for sequence rendering
- Metal rendering pipeline for tracks and sequences
- Tile cache with LRU eviction
- Selection system (single base, range, multiple ranges)
- Edit mode with insertion/deletion/substitution support

### Decision Authority
- Rendering technology choices (Core Graphics vs. Metal)
- Tile size and caching strategy
- Selection model design
- Text rendering approach at different zoom levels

---

## Technical Scope

### Technologies/Frameworks Owned
- AppKit (NSView, NSEvent, NSGraphicsContext)
- Metal (for GPU rendering)
- Core Graphics (for fallback rendering)
- Core Text (for base letter rendering)
- Core Animation (for smooth transitions)

### Component Ownership
```
LungfishUI/
├── SequenceViewer/
│   ├── SequenceViewerView.swift         # PRIMARY OWNER
│   ├── SequenceRenderer.swift           # PRIMARY OWNER
│   ├── MetalSequenceRenderer.swift      # PRIMARY OWNER
│   ├── TileCache.swift                  # PRIMARY OWNER
│   ├── SelectionController.swift        # PRIMARY OWNER
│   └── EditController.swift             # PRIMARY OWNER
├── Rendering/
│   ├── ReferenceFrame.swift             # CO-OWNER with Track Engineer
│   └── RenderContext.swift              # CO-OWNER
└── Shaders/
    └── SequenceShaders.metal            # PRIMARY OWNER
```

### Interfaces with Other Roles
| Role | Interface Point |
|------|-----------------|
| Track Rendering Engineer | Coordinate system, render context |
| UI/UX Lead | Integration into main window |
| File Format Expert | Sequence data access |
| Version Control Specialist | Edit history |

---

## Key Decisions to Make

### Architectural Choices

1. **Rendering Backend**
   - Core Graphics only vs. Metal for GPU acceleration
   - Recommendation: Metal primary, Core Graphics fallback for compatibility

2. **Tile Strategy**
   - Following IGV: 700 pixels per tile
   - Tile at each zoom level or on-demand generation
   - Recommendation: On-demand with aggressive prefetching

3. **Text Rendering**
   - Core Text vs. attributed strings vs. texture atlas
   - Recommendation: Texture atlas for bases at zoom, Core Text for labels

4. **Selection Model**
   - Single selection vs. multi-selection
   - Contiguous vs. discontinuous ranges
   - Recommendation: Support discontinuous multi-selection (like text editors)

### Algorithm Selections

**Tile Cache Sizing**
```swift
// Based on IGV's ReferenceFrame.java
static let binsPerTile = 700  // pixels
static let maxZoom = 23
static let minBP = 40

// Cache size calculation
let visibleTiles = ceil(viewWidth / binsPerTile) + 2  // +2 for prefetch
let cacheSizePerZoom = visibleTiles * 3  // current + 2 adjacent
let totalCacheSize = cacheSizePerZoom * activeZoomLevels
```

**Zoom Level Calculation**
```swift
// From IGV ReferenceFrame.java line 716
func calculateZoom(start: Double, end: Double) -> Int {
    let windowLength = ceil(end) - start
    if windowLength >= chromosomeLength {
        return 0
    }
    let exactZoom = log2((Double(chromosomeLength) / windowLength) * (Double(widthInPixels) / Double(binsPerTile)))
    return Int(ceil(exactZoom))
}
```

### Trade-off Considerations
- **Quality vs. Performance**: Anti-aliased text vs. bitmap fonts
- **Memory vs. Responsiveness**: Larger cache vs. on-demand loading
- **Complexity vs. Features**: Simple selection vs. multi-cursor editing

---

## Success Criteria

### Performance Targets
- 60 fps during pan/zoom operations
- < 16ms frame time for rendering
- < 100ms to load and display a new region
- Smooth scrolling with no visible tile loading

### Quality Metrics
- Pixel-perfect base rendering at all zoom levels
- Correct color coding for A/T/G/C/N
- Accurate selection highlighting
- No visual artifacts during rapid navigation

### Rendering Requirements

**Zoom Levels and Display**
| Zoom Level | BP/Pixel | Display Mode |
|------------|----------|--------------|
| 0-5 | >1000 | Density plot only |
| 6-10 | 100-1000 | Colored bars |
| 11-15 | 10-100 | Thin letters or bars |
| 16-20 | 1-10 | Full letters |
| 21-23 | <1 | Full letters with spacing |

### Deliverable Milestones

| Phase | Deliverable | Timeline |
|-------|-------------|----------|
| 1 | Basic NSView with coordinate system | Week 3 |
| 1 | Core Graphics sequence rendering | Week 4 |
| 2 | Metal rendering pipeline | Week 6 |
| 2 | Tile cache implementation | Week 7 |
| 3 | Selection system | Week 8 |
| 3 | Edit mode | Week 10 |

---

## Reference Materials

### IGV Code References
- `igv/src/main/java/org/igv/ui/panel/ReferenceFrame.java` - Coordinate system
- `igv/src/main/java/org/igv/renderer/SequenceRenderer.java` - Base rendering
- `igv/src/main/java/org/igv/ui/panel/DataPanelPainter.java` - Tile painting

### Key IGV Parameters (from ReferenceFrame.java)
```java
public static int binsPerTile = 700;  // line 40
public int maxZoom = 23;               // line 60
protected static final int minBP = 40; // line 65
```

### Apple Documentation
- [Metal Best Practices](https://developer.apple.com/documentation/metal)
- [Core Graphics Drawing](https://developer.apple.com/documentation/coregraphics)
- [NSView Programming Guide](https://developer.apple.com/documentation/appkit/nsview)

### Geneious References
- Sequence viewer interaction patterns
- Selection highlighting approach

---

## Technical Specifications

### Metal Shader for Sequence Rendering
```metal
// SequenceShaders.metal

struct SequenceVertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    uint baseIndex [[attribute(2)]];  // 0=A, 1=C, 2=G, 3=T, 4=N
};

fragment float4 sequenceFragment(
    SequenceVertex in [[stage_in]],
    texture2d<float> baseAtlas [[texture(0)]]
) {
    constexpr sampler s(filter::linear);

    // Base colors: A=green, C=blue, G=black, T=red, N=gray
    constant float4 baseColors[5] = {
        float4(0.0, 0.8, 0.0, 1.0),  // A - green
        float4(0.0, 0.0, 1.0, 1.0),  // C - blue
        float4(0.0, 0.0, 0.0, 1.0),  // G - black (or orange)
        float4(1.0, 0.0, 0.0, 1.0),  // T - red
        float4(0.5, 0.5, 0.5, 1.0)   // N - gray
    };

    float4 texColor = baseAtlas.sample(s, in.texCoord);
    return texColor * baseColors[in.baseIndex];
}
```

### Selection Model
```swift
struct SequenceSelection: Equatable {
    var ranges: [Range<Int>]  // Multiple discontinuous ranges
    var anchor: Int?          // For shift-click extension
    var isEditing: Bool       // Edit mode active

    var isEmpty: Bool { ranges.isEmpty }
    var isSingleBase: Bool {
        ranges.count == 1 && ranges[0].count == 1
    }

    mutating func toggle(position: Int) {
        // Add or remove position from selection
    }

    mutating func extend(to position: Int) {
        // Extend from anchor to position
    }
}
```

### Coordinate Transformation
```swift
class ReferenceFrame {
    var chromosome: String
    var origin: Double       // Start position in bp
    var scale: Double        // bp per pixel
    var widthInPixels: Int

    func genomicPosition(for screenX: CGFloat) -> Double {
        origin + Double(screenX) * scale
    }

    func screenPosition(for genomicPos: Double) -> CGFloat {
        CGFloat((genomicPos - origin) / scale)
    }
}
```
