// GATKVariantCallPinExpectations.swift - What the GATK call leaves in a bundle at the base
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M1. Recorded from the base with LUNGFISH_RECORD_PINS_DIR, one fact a line, the
// bundle's path masked. The stand-in GATK answers, so every value here comes from the executor, the attach
// service and the request the dialog builds.

extension GATKVariantCallPinTests {
    static let expectedFacts = #"""
    gatk.commands = ["gatk HaplotypeCaller -R <bundle>/genome/reference.fa -I <bundle>/alignments/sample.bam -O <bundle>/variants/gatk/vc-pin-track.vcf --sample-ploidy 2 --max-alternate-alleles 6 --pcr-indel-model CONSERVATIVE --native-pair-hmm-threads 4 --standard-min-confidence-threshold-for-calling 30.0 --min-base-quality-score 20"]
    gatk.cliCommandLine = nil
    exec.file = <bundle>/variants/gatk/.lungfish-provenance.json
    exec.envelope.status = completed
    exec.envelope.argv = ["gatk", "HaplotypeCaller", "-R", "<bundle>/genome/reference.fa", "-I", "<bundle>/alignments/sample.bam", "-O", "<bundle>/variants/gatk/vc-pin-track.vcf", "--sample-ploidy", "2", "--max-alternate-alleles", "6", "--pcr-indel-model", "CONSERVATIVE", "--native-pair-hmm-threads", "4", "--standard-min-confidence-threshold-for-calling", "30.0", "--min-base-quality-score", "20"]
    exec.envelope.reproducibleCommand = gatk HaplotypeCaller -R <bundle>/genome/reference.fa -I <bundle>/alignments/sample.bam -O <bundle>/variants/gatk/vc-pin-track.vcf --sample-ploidy 2 --max-alternate-alleles 6 --pcr-indel-model CONSERVATIVE --native-pair-hmm-threads 4 --standard-min-confidence-threshold-for-calling 30.0 --min-base-quality-score 20
    exec.name = GATK HaplotypeCaller
    exec.stepCount = 1
    exec.step0.tool = gatk-haplotype-caller 4.6.1.0
    exec.step0.command = ["gatk", "HaplotypeCaller", "-R", "<bundle>/genome/reference.fa", "-I", "<bundle>/alignments/sample.bam", "-O", "<bundle>/variants/gatk/vc-pin-track.vcf", "--sample-ploidy", "2", "--max-alternate-alleles", "6", "--pcr-indel-model", "CONSERVATIVE", "--native-pair-hmm-threads", "4", "--standard-min-confidence-threshold-for-calling", "30.0", "--min-base-quality-score", "20"]
    exec.step0.exitCode = 0
    exec.step0.inputs = ["<bundle>/genome/reference.fa", "<bundle>/alignments/sample.bam"]
    exec.step0.outputs = ["<bundle>/variants/gatk/vc-pin-track.vcf", "<bundle>/variants/gatk/vc-pin-track.vcf.idx"]
    exec.parameter.condaEnvironment = /opt/lungfish/envs/gatk-core
    exec.parameter.default.emitReferenceConfidence = GVCF
    exec.parameter.default.extraArguments = []
    exec.parameter.default.maxAlternateAlleles = 6
    exec.parameter.default.nativePairHMMThreads = 4
    exec.parameter.default.pcrIndelModel = CONSERVATIVE
    exec.parameter.default.ploidy = 2
    exec.parameter.default.standardMinConfidenceThresholdForCalling = 30.0
    exec.parameter.option.emitReferenceConfidence = NONE
    exec.parameter.option.extraArguments = ["--min-base-quality-score","20"]
    exec.parameter.option.maxAlternateAlleles = 6
    exec.parameter.option.nativePairHMMThreads = 4
    exec.parameter.option.pcrIndelModel = CONSERVATIVE
    exec.parameter.option.ploidy = 2
    exec.parameter.option.standardMinConfidenceThresholdForCalling = 30.0
    exec.parameter.packID = gatk-core
    exec.parameter.shellCommand = gatk HaplotypeCaller -R <bundle>/genome/reference.fa -I <bundle>/alignments/sample.bam -O <bundle>/variants/gatk/vc-pin-track.vcf --sample-ploidy 2 --max-alternate-alleles 6 --pcr-indel-model CONSERVATIVE --native-pair-hmm-threads 4 --standard-min-confidence-threshold-for-calling 30.0 --min-base-quality-score 20
    exec.parameter.shellCommands = [gatk HaplotypeCaller -R <bundle>/genome/reference.fa -I <bundle>/alignments/sample.bam -O <bundle>/variants/gatk/vc-pin-track.vcf --sample-ploidy 2 --max-alternate-alleles 6 --pcr-indel-model CONSERVATIVE --native-pair-hmm-threads 4 --standard-min-confidence-threshold-for-calling 30.0 --min-base-quality-score 20]
    exec.parameter.toolEnvironment = gatk-core
    exec.parameter.toolExecutable = gatk
    attach.file = <bundle>/variants/gatk/vc-pin-track.lungfish-provenance.json
    attach.envelope.status = completed
    attach.envelope.argv = ["Lungfish Genome Explorer", "gatk-attach", "--bundle", "<bundle>", "--alignment-track", "aln-1", "--vcf", "<bundle>/variants/gatk/vc-pin-track.vcf", "--output-track", "vc-pin-track", "--name", "Sample BAM • GATK HaplotypeCaller", "--import-semantics", "standard", "--import-profile", "auto"]
    attach.name = GATK HaplotypeCaller bundle attachment
    attach.stepCount = 1
    attach.step0.tool = lungfish gatk bundle attach
    attach.step0.command = ["Lungfish Genome Explorer", "gatk-attach", "--bundle", "<bundle>", "--alignment-track", "aln-1", "--vcf", "<bundle>/variants/gatk/vc-pin-track.vcf", "--output-track", "vc-pin-track", "--name", "Sample BAM • GATK HaplotypeCaller", "--import-semantics", "standard", "--import-profile", "auto"]
    attach.step0.inputs = ["<bundle>/variants/gatk/vc-pin-track.vcf", "<bundle>/variants/gatk/vc-pin-track.vcf.idx", "<bundle>/variants/gatk/.lungfish-provenance.json"]
    attach.step0.outputs = ["<bundle>/variants/gatk/vc-pin-track.vcf", "<bundle>/variants/gatk/vc-pin-track.vcf.idx", "<bundle>/variants/gatk/vc-pin-track.db", "<bundle>/manifest.json"]
    attach.parameter.alignmentTrackID = aln-1
    attach.parameter.alignmentTrackName = Sample BAM
    attach.parameter.bundleIdentifier = sample-bundle
    attach.parameter.bundleName = Sample
    attach.parameter.bundlePath = <bundle>
    attach.parameter.condaEnvironment = /opt/lungfish/envs/gatk-core
    attach.parameter.default.emitReferenceConfidence = GVCF
    attach.parameter.default.extraArguments = []
    attach.parameter.default.maxAlternateAlleles = 6
    attach.parameter.default.nativePairHMMThreads = 4
    attach.parameter.default.pcrIndelModel = CONSERVATIVE
    attach.parameter.default.ploidy = 2
    attach.parameter.default.standardMinConfidenceThresholdForCalling = 30.0
    attach.parameter.importProfile = auto
    attach.parameter.importSemantics = standard
    attach.parameter.option.emitReferenceConfidence = NONE
    attach.parameter.option.extraArguments = ["--min-base-quality-score","20"]
    attach.parameter.option.maxAlternateAlleles = 6
    attach.parameter.option.nativePairHMMThreads = 4
    attach.parameter.option.pcrIndelModel = CONSERVATIVE
    attach.parameter.option.ploidy = 2
    attach.parameter.option.standardMinConfidenceThresholdForCalling = 30.0
    attach.parameter.outputTrackID = vc-pin-track
    attach.parameter.outputTrackName = Sample BAM • GATK HaplotypeCaller
    attach.parameter.shellCommand = gatk HaplotypeCaller -R <bundle>/genome/reference.fa -I <bundle>/alignments/sample.bam -O <bundle>/variants/gatk/vc-pin-track.vcf --sample-ploidy 2 --max-alternate-alleles 6 --pcr-indel-model CONSERVATIVE --native-pair-hmm-threads 4 --standard-min-confidence-threshold-for-calling 30.0 --min-base-quality-score 20
    attach.parameter.sourceExecutionProvenance = <bundle>/variants/gatk/.lungfish-provenance.json
    attach.parameter.variantCaller = gatk-haplotype-caller
    attach.parameter.variantCallerVersion = 4.6.1.0
    attach.parameter.variantCount = 1
    track = id:vc-pin-track name:Sample BAM • GATK HaplotypeCaller description:GATK HaplotypeCaller variants from Sample BAM
    track.paths = variants/gatk/vc-pin-track.vcf | variants/gatk/vc-pin-track.vcf.idx | variants/gatk/vc-pin-track.db
    track.kind = mixed count:1 source:GATK HaplotypeCaller version:4.6.1.0
    db.variant_caller = gatk-haplotype-caller
    db.variant_caller_version = 4.6.1.0
    db.variant_caller_command_line = gatk HaplotypeCaller -R <bundle>/genome/reference.fa -I <bundle>/alignments/sample.bam -O <bundle>/variants/gatk/vc-pin-track.vcf --sample-ploidy 2 --max-alternate-alleles 6 --pcr-indel-model CONSERVATIVE --native-pair-hmm-threads 4 --standard-min-confidence-threshold-for-calling 30.0 --min-base-quality-score 20
    db.source_alignment_track_id = aln-1
    db.source_alignment_track_name = Sample BAM
    db.source_alignment_relative_path = alignments/sample.bam
    db.artifact_vcf_path = variants/gatk/vc-pin-track.vcf
    db.artifact_index_path = variants/gatk/vc-pin-track.vcf.idx
    db.artifact_database_path = variants/gatk/vc-pin-track.db
    db.workflow_provenance_path = variants/gatk/vc-pin-track.lungfish-provenance.json
    db.call_semantics = standard
    db.source_execution_provenance = <bundle>/variants/gatk/.lungfish-provenance.json
    manifest.variants = ["vc-pin-track"]
    folder.variants/gatk = [".lungfish-provenance.json", "vc-pin-track.db", "vc-pin-track.lungfish-provenance.json", "vc-pin-track.vcf", "vc-pin-track.vcf.idx"]
    """#
}
