// VariantEditPinExpectations.swift - The recorded dumps VariantEditPinTests compares
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Recorded at the base of lane A43 (2.10), before the services moved to LungfishWorkflow, by running
// VariantEditPinTests with LUNGFISH_RECORD_PINS_DIR set. A moved value shows in the diff of this file.

enum VariantEditPinExpectations {
    static let all: [String: String] = [
        "delete-all-record": #"""
files
.lungfish-provenance.json
.mutation-inputs/<UUID>/0-variants.db
.mutation-inputs/<UUID>/recovery-manifest.json
manifest.json
provenance/bundle.lungfish-provenance.json
provenance/variants.db.lungfish-provenance.json
variants.db
record
argv[0] = Lungfish Genome Explorer
argv[1] = variant
argv[2] = delete
argv[3] = --bundle
argv[4] = <ROOT>/reference.lungfishref
argv[5] = --scope
argv[6] = all
exitStatus = 0
files[0].format = unknown
files[0].originPath = <ROOT>/reference.lungfishref/variants.db
files[0].path = <ROOT>/reference.lungfishref/.mutation-inputs/<UUID>/0-variants.db
files[0].role = input
files[1].format = json
files[1].path = <ROOT>/reference.lungfishref/manifest.json
files[1].role = input
files[2].format = unknown
files[2].path = <ROOT>/reference.lungfishref/variants.db
files[2].role = output
options.defaults.provenanceRequired.type = boolean
options.defaults.provenanceRequired.value = 1
options.defaults.rollbackOnFailure.type = boolean
options.defaults.rollbackOnFailure.value = 1
options.explicit.bundle.type = file
options.explicit.bundle.value = <ROOT>/reference.lungfishref
options.explicit.scope.type = string
options.explicit.scope.value = all
options.explicit.tracks.type = dictionary
options.explicit.tracks.value.trackA.type = string
options.explicit.tracks.value.trackA.value = Variants
options.resolvedDefaults.deletedCountsByDatabase.type = dictionary
options.resolvedDefaults.deletedCountsByDatabase.value.<ROOT>/reference.lungfishref/variants.db.type = integer
options.resolvedDefaults.deletedCountsByDatabase.value.<ROOT>/reference.lungfishref/variants.db.value = 3
options.resolvedDefaults.deletedCountsByTrack.type = dictionary
options.resolvedDefaults.deletedCountsByTrack.value.trackA.type = integer
options.resolvedDefaults.deletedCountsByTrack.value.trackA.value = 3
options.resolvedDefaults.targetCount.type = integer
options.resolvedDefaults.targetCount.value = 1
options.resolvedDefaults.totalDeleted.type = integer
options.resolvedDefaults.totalDeleted.value = 3
output.format = unknown
output.path = <ROOT>/reference.lungfishref/variants.db
output.role = output
outputs[0].format = unknown
outputs[0].path = <ROOT>/reference.lungfishref/variants.db
outputs[0].role = output
reproducibleCommand = 'Lungfish Genome Explorer' variant delete --bundle <ROOT>/reference.lungfishref --scope all
schemaVersion = 2
status = completed
steps[0].argv[0] = Lungfish Genome Explorer
steps[0].argv[1] = variant
steps[0].argv[2] = delete
steps[0].argv[3] = --bundle
steps[0].argv[4] = <ROOT>/reference.lungfishref
steps[0].argv[5] = --scope
steps[0].argv[6] = all
steps[0].dependsOn = []
steps[0].exitStatus = 0
steps[0].inputs[0].format = json
steps[0].inputs[0].path = <ROOT>/reference.lungfishref/manifest.json
steps[0].inputs[0].role = input
steps[0].inputs[1].format = unknown
steps[0].inputs[1].originPath = <ROOT>/reference.lungfishref/variants.db
steps[0].inputs[1].path = <ROOT>/reference.lungfishref/.mutation-inputs/<UUID>/0-variants.db
steps[0].inputs[1].role = input
steps[0].outputs[0].format = unknown
steps[0].outputs[0].path = <ROOT>/reference.lungfishref/variants.db
steps[0].outputs[0].role = output
steps[0].reproducibleCommand = 'Lungfish Genome Explorer' variant delete --bundle <ROOT>/reference.lungfishref --scope all
steps[0].toolName = Lungfish Genome Explorer
steps[0].toolVersion = Lungfish <version>
tool.kind = gui
tool.name = Lungfish Genome Explorer
tool.version = Lungfish <version>
toolName = Lungfish Genome Explorer
toolVersion = Lungfish <version>
workflowName = Variant deletion
workflowVersion = Lungfish <version>
"""#,
        "delete-all-rows": #"""
table _tok_indel
table _tok_pass
1
2
3
table _tok_qual30
1
2
3
table _tok_snv
1
2
3
table db_metadata
idx_idx_genotypes_sample\#tcreated
idx_idx_genotypes_variant\#tcreated
idx_idx_samples_name\#tcreated
idx_idx_variant_info_key\#tcreated
idx_idx_variant_info_key_value\#tcreated
idx_idx_variants_id\#tcreated
idx_idx_variants_region\#tcreated
idx_idx_variants_type\#tcreated
import_partition_mode\#tsingle-pass
import_profile\#tfast
import_semantics\#tstandard
import_source\#treference.vcf
import_state\#tcomplete
import_variant_count\#t3
omit_homref\#ttrue
schema_version\#t3
table genotypes
table samples
SAMPLE_A\#tSAMPLE_A\#treference.vcf\#t{}
SAMPLE_B\#tSAMPLE_B\#treference.vcf\#t{}
table variant_info
table variant_info_defs
table variants
"""#,
        "metadata-import-record": #"""
files
.lungfish-provenance.json
.mutation-inputs/<UUID>/0-variants.db
.mutation-inputs/<UUID>/metadata-metadata.tsv
.mutation-inputs/<UUID>/recovery-manifest.json
manifest.json
provenance/bundle.lungfish-provenance.json
provenance/variants.db.lungfish-provenance.json
variants.db
record
argv[0] = Lungfish Genome Explorer
argv[1] = variant-sample-metadata
argv[2] = import
argv[3] = --metadata
argv[4] = <ROOT>/metadata.tsv
argv[5] = --bundle
argv[6] = <ROOT>/reference.lungfishref
argv[7] = --format
argv[8] = tsv
exitStatus = 0
files[0].format = text
files[0].originPath = <ROOT>/metadata.tsv
files[0].path = <ROOT>/reference.lungfishref/.mutation-inputs/<UUID>/metadata-metadata.tsv
files[0].role = input
files[1].format = unknown
files[1].originPath = <ROOT>/reference.lungfishref/variants.db
files[1].path = <ROOT>/reference.lungfishref/.mutation-inputs/<UUID>/0-variants.db
files[1].role = input
files[2].format = json
files[2].path = <ROOT>/reference.lungfishref/manifest.json
files[2].role = input
files[3].format = unknown
files[3].path = <ROOT>/reference.lungfishref/variants.db
files[3].role = output
options.defaults.provenanceRequired.type = boolean
options.defaults.provenanceRequired.value = 1
options.defaults.rollbackOnFailure.type = boolean
options.defaults.rollbackOnFailure.value = 1
options.explicit.bundle.type = file
options.explicit.bundle.value = <ROOT>/reference.lungfishref
options.explicit.format.type = string
options.explicit.format.value = tsv
options.explicit.metadata.type = file
options.explicit.metadata.value = <ROOT>/metadata.tsv
options.explicit.targets.type = dictionary
options.explicit.targets.value.<ROOT>/reference.lungfishref/variants.db.type = string
options.explicit.targets.value.<ROOT>/reference.lungfishref/variants.db.value = trackA
options.resolvedDefaults.targetCount.type = integer
options.resolvedDefaults.targetCount.value = 1
options.resolvedDefaults.totalUpdated.type = integer
options.resolvedDefaults.totalUpdated.value = 2
options.resolvedDefaults.updatedCounts.type = dictionary
options.resolvedDefaults.updatedCounts.value.<ROOT>/reference.lungfishref/variants.db.type = integer
options.resolvedDefaults.updatedCounts.value.<ROOT>/reference.lungfishref/variants.db.value = 2
output.format = unknown
output.path = <ROOT>/reference.lungfishref/variants.db
output.role = output
outputs[0].format = unknown
outputs[0].path = <ROOT>/reference.lungfishref/variants.db
outputs[0].role = output
reproducibleCommand = 'Lungfish Genome Explorer' variant-sample-metadata import --metadata <ROOT>/metadata.tsv --bundle <ROOT>/reference.lungfishref --format tsv
schemaVersion = 2
status = completed
steps[0].argv[0] = Lungfish Genome Explorer
steps[0].argv[1] = variant-sample-metadata
steps[0].argv[2] = import
steps[0].argv[3] = --metadata
steps[0].argv[4] = <ROOT>/metadata.tsv
steps[0].argv[5] = --bundle
steps[0].argv[6] = <ROOT>/reference.lungfishref
steps[0].argv[7] = --format
steps[0].argv[8] = tsv
steps[0].dependsOn = []
steps[0].exitStatus = 0
steps[0].inputs[0].format = text
steps[0].inputs[0].originPath = <ROOT>/metadata.tsv
steps[0].inputs[0].path = <ROOT>/reference.lungfishref/.mutation-inputs/<UUID>/metadata-metadata.tsv
steps[0].inputs[0].role = input
steps[0].inputs[1].format = json
steps[0].inputs[1].path = <ROOT>/reference.lungfishref/manifest.json
steps[0].inputs[1].role = input
steps[0].inputs[2].format = unknown
steps[0].inputs[2].originPath = <ROOT>/reference.lungfishref/variants.db
steps[0].inputs[2].path = <ROOT>/reference.lungfishref/.mutation-inputs/<UUID>/0-variants.db
steps[0].inputs[2].role = input
steps[0].outputs[0].format = unknown
steps[0].outputs[0].path = <ROOT>/reference.lungfishref/variants.db
steps[0].outputs[0].role = output
steps[0].reproducibleCommand = 'Lungfish Genome Explorer' variant-sample-metadata import --metadata <ROOT>/metadata.tsv --bundle <ROOT>/reference.lungfishref --format tsv
steps[0].toolName = Lungfish Genome Explorer
steps[0].toolVersion = Lungfish <version>
tool.kind = gui
tool.name = Lungfish Genome Explorer
tool.version = Lungfish <version>
toolName = Lungfish Genome Explorer
toolVersion = Lungfish <version>
workflowName = Variant sample metadata import
workflowVersion = Lungfish <version>
"""#,
        "metadata-import-rows": #"""
table _tok_indel
table _tok_pass
1
2
3
table _tok_qual30
1
2
3
table _tok_snv
1
2
3
table db_metadata
idx_idx_genotypes_sample\#tcreated
idx_idx_genotypes_variant\#tcreated
idx_idx_samples_name\#tcreated
idx_idx_variant_info_key\#tcreated
idx_idx_variant_info_key_value\#tcreated
idx_idx_variants_id\#tcreated
idx_idx_variants_region\#tcreated
idx_idx_variants_type\#tcreated
import_partition_mode\#tsingle-pass
import_profile\#tfast
import_semantics\#tstandard
import_source\#treference.vcf
import_state\#tcomplete
import_variant_count\#t3
omit_homref\#ttrue
schema_version\#t3
table genotypes
1\#tSAMPLE_A\#t0/1\#t0\#t1\#t0\#tNULL\#tNULL\#tNULL\#tNULL
2\#tSAMPLE_A\#t0/1\#t0\#t1\#t0\#tNULL\#tNULL\#tNULL\#tNULL
2\#tSAMPLE_B\#t1/1\#t1\#t1\#t0\#tNULL\#tNULL\#tNULL\#tNULL
3\#tSAMPLE_B\#t0/1\#t0\#t1\#t0\#tNULL\#tNULL\#tNULL\#tNULL
table samples
SAMPLE_A\#tSAMPLE_A\#treference.vcf\#t{"animal":"macaque","cohort":"treated"}
SAMPLE_B\#tSAMPLE_B\#treference.vcf\#t{"animal":"macaque","cohort":"control"}
table variant_info
1\#tDP\#t10
2\#tDP\#t12
3\#tDP\#t8
table variant_info_defs
table variants
1\#tchr1\#t99\#t100\#tchr1_100\#tA\#tG\#tSNP\#t50.0\#tPASS\#tNULL\#t2
2\#tchr1\#t199\#t200\#tchr1_200\#tC\#tT\#tSNP\#t50.0\#tPASS\#tNULL\#t2
3\#tchr2\#t299\#t300\#tchr2_300\#tG\#tA\#tSNP\#t40.0\#tPASS\#tNULL\#t2
"""#,
        "selected-deletion-record": #"""
files
.lungfish-provenance.json
.mutation-inputs/<UUID>/0-variants.db
.mutation-inputs/<UUID>/recovery-manifest.json
manifest.json
provenance/bundle.lungfish-provenance.json
provenance/variants.db.lungfish-provenance.json
variants.db
record
argv[0] = Lungfish Genome Explorer
argv[10] = 2
argv[1] = variant
argv[2] = delete
argv[3] = --bundle
argv[4] = <ROOT>/reference.lungfishref
argv[5] = --scope
argv[6] = selected
argv[7] = --track-id
argv[8] = trackA
argv[9] = --variant-ids
exitStatus = 0
files[0].format = unknown
files[0].originPath = <ROOT>/reference.lungfishref/variants.db
files[0].path = <ROOT>/reference.lungfishref/.mutation-inputs/<UUID>/0-variants.db
files[0].role = input
files[1].format = json
files[1].path = <ROOT>/reference.lungfishref/manifest.json
files[1].role = input
files[2].format = unknown
files[2].path = <ROOT>/reference.lungfishref/variants.db
files[2].role = output
options.defaults.provenanceRequired.type = boolean
options.defaults.provenanceRequired.value = 1
options.defaults.rollbackOnFailure.type = boolean
options.defaults.rollbackOnFailure.value = 1
options.explicit.bundle.type = file
options.explicit.bundle.value = <ROOT>/reference.lungfishref
options.explicit.scope.type = string
options.explicit.scope.value = selected
options.explicit.tracks.type = dictionary
options.explicit.tracks.value.trackA.type = string
options.explicit.tracks.value.trackA.value = Variants
options.explicit.variantIdsByTrack.type = dictionary
options.explicit.variantIdsByTrack.value.trackA.type = array
options.explicit.variantIdsByTrack.value.trackA.value[0].type = integer
options.explicit.variantIdsByTrack.value.trackA.value[0].value = 2
options.resolvedDefaults.deletedCountsByDatabase.type = dictionary
options.resolvedDefaults.deletedCountsByDatabase.value.<ROOT>/reference.lungfishref/variants.db.type = integer
options.resolvedDefaults.deletedCountsByDatabase.value.<ROOT>/reference.lungfishref/variants.db.value = 1
options.resolvedDefaults.deletedCountsByTrack.type = dictionary
options.resolvedDefaults.deletedCountsByTrack.value.trackA.type = integer
options.resolvedDefaults.deletedCountsByTrack.value.trackA.value = 1
options.resolvedDefaults.targetCount.type = integer
options.resolvedDefaults.targetCount.value = 1
options.resolvedDefaults.totalDeleted.type = integer
options.resolvedDefaults.totalDeleted.value = 1
output.format = unknown
output.path = <ROOT>/reference.lungfishref/variants.db
output.role = output
outputs[0].format = unknown
outputs[0].path = <ROOT>/reference.lungfishref/variants.db
outputs[0].role = output
reproducibleCommand = 'Lungfish Genome Explorer' variant delete --bundle <ROOT>/reference.lungfishref --scope selected --track-id trackA --variant-ids 2
schemaVersion = 2
status = completed
steps[0].argv[0] = Lungfish Genome Explorer
steps[0].argv[10] = 2
steps[0].argv[1] = variant
steps[0].argv[2] = delete
steps[0].argv[3] = --bundle
steps[0].argv[4] = <ROOT>/reference.lungfishref
steps[0].argv[5] = --scope
steps[0].argv[6] = selected
steps[0].argv[7] = --track-id
steps[0].argv[8] = trackA
steps[0].argv[9] = --variant-ids
steps[0].dependsOn = []
steps[0].exitStatus = 0
steps[0].inputs[0].format = json
steps[0].inputs[0].path = <ROOT>/reference.lungfishref/manifest.json
steps[0].inputs[0].role = input
steps[0].inputs[1].format = unknown
steps[0].inputs[1].originPath = <ROOT>/reference.lungfishref/variants.db
steps[0].inputs[1].path = <ROOT>/reference.lungfishref/.mutation-inputs/<UUID>/0-variants.db
steps[0].inputs[1].role = input
steps[0].outputs[0].format = unknown
steps[0].outputs[0].path = <ROOT>/reference.lungfishref/variants.db
steps[0].outputs[0].role = output
steps[0].reproducibleCommand = 'Lungfish Genome Explorer' variant delete --bundle <ROOT>/reference.lungfishref --scope selected --track-id trackA --variant-ids 2
steps[0].toolName = Lungfish Genome Explorer
steps[0].toolVersion = Lungfish <version>
tool.kind = gui
tool.name = Lungfish Genome Explorer
tool.version = Lungfish <version>
toolName = Lungfish Genome Explorer
toolVersion = Lungfish <version>
workflowName = Variant deletion
workflowVersion = Lungfish <version>
"""#,
        "selected-deletion-rows": #"""
table _tok_indel
table _tok_pass
1
2
3
table _tok_qual30
1
2
3
table _tok_snv
1
2
3
table db_metadata
idx_idx_genotypes_sample\#tcreated
idx_idx_genotypes_variant\#tcreated
idx_idx_samples_name\#tcreated
idx_idx_variant_info_key\#tcreated
idx_idx_variant_info_key_value\#tcreated
idx_idx_variants_id\#tcreated
idx_idx_variants_region\#tcreated
idx_idx_variants_type\#tcreated
import_partition_mode\#tsingle-pass
import_profile\#tfast
import_semantics\#tstandard
import_source\#treference.vcf
import_state\#tcomplete
import_variant_count\#t3
omit_homref\#ttrue
schema_version\#t3
table genotypes
1\#tSAMPLE_A\#t0/1\#t0\#t1\#t0\#tNULL\#tNULL\#tNULL\#tNULL
3\#tSAMPLE_B\#t0/1\#t0\#t1\#t0\#tNULL\#tNULL\#tNULL\#tNULL
table samples
SAMPLE_A\#tSAMPLE_A\#treference.vcf\#t{}
SAMPLE_B\#tSAMPLE_B\#treference.vcf\#t{}
table variant_info
1\#tDP\#t10
3\#tDP\#t8
table variant_info_defs
table variants
1\#tchr1\#t99\#t100\#tchr1_100\#tA\#tG\#tSNP\#t50.0\#tPASS\#tNULL\#t2
3\#tchr2\#t299\#t300\#tchr2_300\#tG\#tA\#tSNP\#t40.0\#tPASS\#tNULL\#t2
"""#,
    ]
}
