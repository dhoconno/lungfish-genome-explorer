# SwiftUI Migration Plan — Expert Report

## Migration Order (by risk/reward)
1. **FASTQImportConfigSheet** — lowest risk, Form is most mature SwiftUI API, ~65% reduction
2. **OperationsPanelController** — low risk, List+ProgressView, validates SwiftUI-in-AppKit-panel pattern
3. **BarcodeScoutSheet** — medium risk, Table with inline editing needs careful testing
4. **FASTQChartViews + SparklineStrip** — highest risk, boxplot has no native Charts mark

## Shared Infrastructure Needed First
1. NSHostingController sheet presentation helper (reusable for all 4 migrations)
2. Keep ObservableObject/@Published for now, migrate to @Observable later
3. Shared formatters (formatCount, formatBytes, formatBases)
4. Chart copy-to-clipboard via ImageRenderer
5. Model Identifiable conformances

## Key Risks
- Boxplot chart has no native Swift Charts mark (use composed marks or Canvas)
- Table inline TextField editing in BarcodeScout needs verification
- Sparkline hover interaction uses NSTrackingArea → SwiftUI .onHover per subview

## Estimated Reductions
- FASTQImportConfigSheet: 433 → ~140 lines (65%)
- OperationsPanelController: 303 → ~95 lines (65%)
- BarcodeScoutSheet: 435 → ~200 lines (50%)
- FASTQChartViews + Sparklines: 1,001 → ~400 lines (60%)

## Status: DEFERRED to future session
These are valuable improvements but lower priority than the format/structure work completed.
