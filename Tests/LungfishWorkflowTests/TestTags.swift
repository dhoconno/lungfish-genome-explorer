// TestTags.swift - swift-testing Tag definitions for cross-cutting test surfaces.
//
// These tags let `swift test --filter-tag <name>` (and scripts/test-surface.sh --tag <name>)
// select tests by app surface regardless of which file or target they live in, which plain
// name-based `--filter` cannot do for scattered tests.
//
// NOTE: only swift-testing (`@Test`) tests can carry tags. The bulk of the suite is still
// XCTest; for those, use name-based filtering (scripts/test-surface.sh <name>). Adopt these
// tags incrementally: when you touch a swift-testing test that belongs to one of these
// surfaces, add `.tags(.<surface>)` to its `@Test`.
//
// Example:
//   @Test("parses VCF 4.x", .tags(.vcf)) func parsesVCF4() { ... }

import Testing

extension Tag {
    /// VCF / variant parsing, import, and the variant database.
    @Tag static var vcf: Self
    /// 12S amplicon matching (classifier, workflow, Hilo regressions).
    @Tag static var twelveS: Self
    /// MHC / genotype / haplotype definitions and results.
    @Tag static var mhc: Self
    /// Project sidebar (rendering, drag/drop import, deletion).
    @Tag static var sidebar: Self
    /// Build/release configuration and packaging.
    @Tag static var releaseConfig: Self
}
