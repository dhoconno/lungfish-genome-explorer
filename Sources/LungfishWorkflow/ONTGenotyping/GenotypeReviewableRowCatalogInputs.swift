import Darwin
import CryptoKit
import Foundation
import LungfishIO

public struct GenotypeReviewableRowCatalogInputs: Sendable {
    public let referenceRecords: [MHCReferenceRecord]
    public let authoritativeSamples: [String]
    public let calls: [ONTGenotypeSharedCall]
    public let candidates: [GenotypeReviewableRowCandidate]
    public let inputDescriptors: [ProvenanceFileDescriptor]
    public let workflowName: String
    public let workflowVersion: String
    public let toolVersion: String
    public let argv: [String]
    public let userVisibleOptions: [String: ParameterValue]
    public let resolvedDefaults: [String: ParameterValue]
    public let runtimeIdentity: ProvenanceRuntimeIdentity

    public init(
        referenceRecords: [MHCReferenceRecord],
        authoritativeSamples: [String],
        calls: [ONTGenotypeSharedCall],
        candidates: [GenotypeReviewableRowCandidate] = [],
        inputDescriptors: [ProvenanceFileDescriptor],
        workflowName: String,
        workflowVersion: String,
        toolVersion: String,
        argv: [String],
        userVisibleOptions: [String: ParameterValue],
        resolvedDefaults: [String: ParameterValue],
        runtimeIdentity: ProvenanceRuntimeIdentity
    ) {
        self.referenceRecords = referenceRecords
        self.authoritativeSamples = authoritativeSamples
        self.calls = calls
        self.candidates = candidates
        self.inputDescriptors = inputDescriptors
        self.workflowName = workflowName
        self.workflowVersion = workflowVersion
        self.toolVersion = toolVersion
        self.argv = argv
        self.userVisibleOptions = userVisibleOptions
        self.resolvedDefaults = resolvedDefaults
        self.runtimeIdentity = runtimeIdentity
    }
}
