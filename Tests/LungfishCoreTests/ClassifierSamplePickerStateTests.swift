import Testing
@testable import LungfishCore

@Suite("ClassifierSamplePickerState")
struct ClassifierSamplePickerStateTests {

    @Test("Initializes with all samples selected")
    func initSelectsAll() {
        let state = ClassifierSamplePickerState(allSamples: Set(["A", "B", "C"]))
        #expect(state.selectedSamples == Set(["A", "B", "C"]))
    }

    @Test("Toggle removes selected sample")
    func toggleRemove() {
        let state = ClassifierSamplePickerState(allSamples: Set(["A", "B"]))
        state.selectedSamples.remove("A")
        #expect(state.selectedSamples == Set(["B"]))
    }

    @Test("Toggle adds deselected sample")
    func toggleAdd() {
        let state = ClassifierSamplePickerState(allSamples: Set(["A", "B"]))
        state.selectedSamples.remove("A")
        state.selectedSamples.insert("A")
        #expect(state.selectedSamples == Set(["A", "B"]))
    }
}
