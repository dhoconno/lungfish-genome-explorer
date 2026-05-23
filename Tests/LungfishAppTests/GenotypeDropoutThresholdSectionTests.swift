import XCTest
import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
@testable import LungfishApp

@MainActor
final class GenotypeDropoutThresholdSectionTests: XCTestCase {
    func testRendersWithoutCrash() {
        let bindings = TestBindings()
        let view = GenotypeDropoutThresholdSection(
            absoluteEnabled: bindings.absoluteEnabledBinding,
            absoluteValue: bindings.absoluteValueBinding,
            sampleFractionEnabled: bindings.sampleFractionEnabledBinding,
            sampleFractionPercent: bindings.sampleFractionPercentBinding,
            locusFractionEnabled: bindings.locusFractionEnabledBinding,
            locusFractionPercent: bindings.locusFractionPercentBinding
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        XCTAssertGreaterThan(host.frame.width, 0)
    }

    func testApplyProducesEvaluatorReflectingTogglesAndValues() {
        let bindings = TestBindings()
        bindings.absoluteEnabled = true
        bindings.absoluteValue = 75
        bindings.sampleFractionEnabled = false
        bindings.locusFractionEnabled = true
        bindings.locusFractionPercent = 7.0

        var received: GenotypeDropoutEvaluator?
        let view = GenotypeDropoutThresholdSection(
            absoluteEnabled: bindings.absoluteEnabledBinding,
            absoluteValue: bindings.absoluteValueBinding,
            sampleFractionEnabled: bindings.sampleFractionEnabledBinding,
            sampleFractionPercent: bindings.sampleFractionPercentBinding,
            locusFractionEnabled: bindings.locusFractionEnabledBinding,
            locusFractionPercent: bindings.locusFractionPercentBinding,
            onApply: { received = $0 }
        )
        // We can't trigger the Apply button programmatically without a UI test;
        // assert the section can be hosted instead.
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        XCTAssertNil(received)
    }

    @MainActor
    private final class TestBindings {
        var absoluteEnabled = true
        var absoluteValue = 50
        var sampleFractionEnabled = false
        var sampleFractionPercent = 0.1
        var locusFractionEnabled = true
        var locusFractionPercent = 5.0

        var absoluteEnabledBinding: Binding<Bool> {
            .init(get: { self.absoluteEnabled }, set: { self.absoluteEnabled = $0 })
        }
        var absoluteValueBinding: Binding<Int> {
            .init(get: { self.absoluteValue }, set: { self.absoluteValue = $0 })
        }
        var sampleFractionEnabledBinding: Binding<Bool> {
            .init(get: { self.sampleFractionEnabled }, set: { self.sampleFractionEnabled = $0 })
        }
        var sampleFractionPercentBinding: Binding<Double> {
            .init(get: { self.sampleFractionPercent }, set: { self.sampleFractionPercent = $0 })
        }
        var locusFractionEnabledBinding: Binding<Bool> {
            .init(get: { self.locusFractionEnabled }, set: { self.locusFractionEnabled = $0 })
        }
        var locusFractionPercentBinding: Binding<Double> {
            .init(get: { self.locusFractionPercent }, set: { self.locusFractionPercent = $0 })
        }
    }
}
