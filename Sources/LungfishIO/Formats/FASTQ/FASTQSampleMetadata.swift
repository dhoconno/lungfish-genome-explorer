// FASTQSampleMetadata.swift - PHA4GE-aligned metadata for FASTQ datasets
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - SampleRole

/// Role of a sample in a batch analysis.
///
/// Controls contamination risk flagging and filtering defaults.
public enum SampleRole: String, Sendable, Codable, CaseIterable {
    case testSample = "test_sample"
    case negativeControl = "negative_control"
    case positiveControl = "positive_control"
    case environmentalControl = "environmental_control"
    case extractionBlank = "extraction_blank"

    /// Whether this role represents a control (not a test sample).
    public var isControl: Bool {
        self != .testSample
    }

    /// Human-readable display label.
    public var displayLabel: String {
        switch self {
        case .testSample: return "Clinical Sample"
        case .negativeControl: return "Negative Control"
        case .positiveControl: return "Positive Control"
        case .environmentalControl: return "Environmental Control"
        case .extractionBlank: return "Extraction Blank"
        }
    }
}

// MARK: - MetadataTemplate

/// Template controlling which metadata fields are shown and their grouping.
///
/// Each template corresponds to a sample type with domain-specific fields
/// drawn from PHA4GE contextual data specifications and expert recommendations.
public enum MetadataTemplate: String, Sendable, Codable, CaseIterable {
    /// Clinical pathogen sample (PHA4GE clinical/pathogen fields).
    case clinical
    /// Wastewater surveillance sample (PHA4GE wastewater fields).
    case wastewater
    /// Environmental air sampling.
    case airSample = "air_sample"
    /// General environmental sampling (soil, water, sediment).
    case environmental
    /// User-defined custom template (shows all fields).
    case custom

    /// Human-readable display label.
    public var displayLabel: String {
        switch self {
        case .clinical: return "Clinical Sample"
        case .wastewater: return "Wastewater"
        case .airSample: return "Air Sample"
        case .environmental: return "Environmental"
        case .custom: return "Custom"
        }
    }

    /// Template-specific field definitions beyond the common PHA4GE fields.
    ///
    /// Each entry is a (label, keyPath-name) pair. These fields are stored in
    /// `customFields` on the metadata struct but surfaced as first-class UI
    /// fields when the matching template is selected.
    public var templateFields: [(label: String, key: String)] {
        switch self {
        case .clinical:
            return [
                ("Specimen Source", "specimen_source"),
                ("Anatomical Site", "anatomical_site"),
                ("Patient Age", "patient_age"),
                ("Patient Sex", "patient_sex"),
                ("Symptom Onset Date", "symptom_onset_date"),
                ("Travel History", "travel_history"),
                ("Antimicrobial Resistance", "antimicrobial_resistance"),
                ("Hospitalization Status", "hospitalization_status"),
            ]
        case .wastewater:
            return [
                ("Collection Site Type", "collection_site_type"),
                ("Population Served", "population_served"),
                ("Flow Rate", "flow_rate"),
                ("Composite vs Grab", "composite_vs_grab"),
                ("Treatment Stage", "treatment_stage"),
                ("Catchment Area ID", "catchment_area_id"),
            ]
        case .airSample:
            return [
                ("Sampling Method", "sampling_method"),
                ("Flow Rate (L/min)", "flow_rate_lpm"),
                ("Sampling Duration (min)", "sampling_duration_minutes"),
                ("Indoor/Outdoor", "indoor_outdoor"),
                ("Ventilation Type", "ventilation_type"),
                ("Particle Size Fraction", "particle_size_fraction"),
                ("Temperature (\u{00B0}C)", "temperature_celsius"),
                ("Relative Humidity (%)", "relative_humidity_percent"),
                ("CO\u{2082} (ppm)", "co2_ppm"),
                ("Occupancy Count", "occupancy_count"),
            ]
        case .environmental:
            return [
                ("Biome", "biome"),
                ("Environmental Medium", "environmental_medium"),
                ("Depth (m)", "depth_meters"),
                ("Elevation (m)", "elevation_meters"),
                ("Environmental Feature", "environmental_feature"),
            ]
        case .custom:
            return []
        }
    }
}

// MARK: - FASTQSampleMetadata

/// PHA4GE-aligned metadata for a FASTQ dataset.
///
/// Maps to NCBI BioSample attributes for SRA submission interoperability.
/// All fields except `sampleName` are optional. Unknown fields are preserved
/// in `customFields` for round-trip fidelity.
public struct FASTQSampleMetadata: Sendable, Codable, Equatable {

    // --- Required ---
    /// Display name for the sample (maps to NCBI `sample_name`).
    public var sampleName: String

    // --- Recommended (PHA4GE Tier 1) ---
    /// Sample type / isolation source (maps to NCBI `isolation_source`).
    public var sampleType: String?

    /// Collection date in ISO 8601 format (YYYY-MM-DD, YYYY-MM, or YYYY).
    public var collectionDate: String?

    /// Geographic location in ISO 3166 format: "country:region:locality".
    public var geoLocName: String?

    /// Host organism (NCBI Taxonomy name, e.g., "Homo sapiens").
    public var host: String?

    /// Host disease or condition (free text or ICD-10).
    public var hostDisease: String?

    /// Purpose of sequencing: "Diagnostic", "Surveillance", "Research", etc.
    public var purposeOfSequencing: String?

    /// Sequencing instrument model (INSDC controlled vocabulary).
    public var sequencingInstrument: String?

    /// Library strategy: "WGS", "AMPLICON", "RNA-Seq", etc.
    public var libraryStrategy: String?

    /// Lab or institution that collected the sample.
    public var sampleCollectedBy: String?

    /// Target organism (NCBI Taxonomy name) or "metagenome".
    public var organism: String?

    // --- Batch context ---
    /// Role of this sample in the analysis batch.
    public var sampleRole: SampleRole

    /// Patient or subject identifier (may contain PHI).
    public var patientId: String?

    /// Sequencing run identifier.
    public var runId: String?

    /// Analysis batch identifier.
    public var batchId: String?

    /// Well position on sequencing plate (e.g., "A1", "H12").
    public var platePosition: String?

    // --- Template & notes ---
    /// Active metadata template controlling which domain-specific fields are shown.
    public var metadataTemplate: MetadataTemplate?

    /// Free-text notes field for the sample.
    public var notes: String?

    /// Filenames of attachments stored in the bundle's `attachments/` directory.
    public var attachments: [String]?

    // --- Extensibility ---
    /// Custom key-value fields not covered by the typed properties.
    /// Preserved during CSV round-trip for fields the user adds.
    public var customFields: [String: String]

    public init(sampleName: String) {
        self.sampleName = sampleName
        self.sampleRole = .testSample
        self.customFields = [:]
    }
}

// MARK: - CSV Column Mapping

extension FASTQSampleMetadata {

    /// Known column header aliases mapped to property names.
    /// The first alias in each group is the canonical CSV header.
    public static let columnMapping: [(csvHeaders: [String], keyPath: String)] = [
        (["sample_name", "name", "label"], "sampleName"),
        (["sample_type", "isolation_source"], "sampleType"),
        (["collection_date"], "collectionDate"),
        (["geo_loc_name", "geographic_location"], "geoLocName"),
        (["host"], "host"),
        (["host_disease"], "hostDisease"),
        (["purpose_of_sequencing"], "purposeOfSequencing"),
        (["instrument_model", "sequencing_instrument"], "sequencingInstrument"),
        (["library_strategy"], "libraryStrategy"),
        (["collected_by", "sample_collected_by"], "sampleCollectedBy"),
        (["organism"], "organism"),
        (["sample_role", "control_type"], "sampleRole"),
        (["patient_id", "subject_id"], "patientId"),
        (["run_id"], "runId"),
        (["batch_id"], "batchId"),
        (["plate_position", "well"], "platePosition"),
        (["metadata_template"], "metadataTemplate"),
        (["notes"], "notes"),
    ]

    /// Canonical CSV headers for all typed fields, in order.
    public static var canonicalHeaders: [String] {
        columnMapping.map { $0.csvHeaders[0] }
    }

    /// Sets a property value from a CSV column header (case-insensitive).
    /// Returns true if the header matched a known property, false if it should go to customFields.
    @discardableResult
    public mutating func setValue(_ value: String, forCSVHeader header: String) -> Bool {
        let normalized = header.lowercased().trimmingCharacters(in: .whitespaces)
        let trimmedValue = value.trimmingCharacters(in: .whitespaces)

        for mapping in Self.columnMapping {
            if mapping.csvHeaders.contains(normalized) {
                setProperty(mapping.keyPath, to: trimmedValue)
                return true
            }
        }

        // Unknown header goes to customFields
        if !trimmedValue.isEmpty {
            customFields[header] = trimmedValue
        }
        return false
    }

    /// Gets the value for a canonical CSV header.
    public func value(forCSVHeader header: String) -> String? {
        let normalized = header.lowercased().trimmingCharacters(in: .whitespaces)

        for mapping in Self.columnMapping {
            if mapping.csvHeaders.contains(normalized) {
                return getProperty(mapping.keyPath)
            }
        }
        return customFields[header]
    }

    // MARK: - Private Property Accessors

    private mutating func setProperty(_ keyPath: String, to value: String) {
        let v: String? = value.isEmpty ? nil : value
        switch keyPath {
        case "sampleName": sampleName = value.isEmpty ? sampleName : value
        case "sampleType": sampleType = v
        case "collectionDate": collectionDate = v
        case "geoLocName": geoLocName = v
        case "host": host = v
        case "hostDisease": hostDisease = v
        case "purposeOfSequencing": purposeOfSequencing = v
        case "sequencingInstrument": sequencingInstrument = v
        case "libraryStrategy": libraryStrategy = v
        case "sampleCollectedBy": sampleCollectedBy = v
        case "organism": organism = v
        case "sampleRole":
            if let role = SampleRole(rawValue: value) {
                sampleRole = role
            }
        case "patientId": patientId = v
        case "runId": runId = v
        case "batchId": batchId = v
        case "platePosition": platePosition = v
        case "metadataTemplate":
            if let tmpl = MetadataTemplate(rawValue: value) {
                metadataTemplate = tmpl
            }
        case "notes": notes = v
        default: break
        }
    }

    private func getProperty(_ keyPath: String) -> String? {
        switch keyPath {
        case "sampleName": return sampleName
        case "sampleType": return sampleType
        case "collectionDate": return collectionDate
        case "geoLocName": return geoLocName
        case "host": return host
        case "hostDisease": return hostDisease
        case "purposeOfSequencing": return purposeOfSequencing
        case "sequencingInstrument": return sequencingInstrument
        case "libraryStrategy": return libraryStrategy
        case "sampleCollectedBy": return sampleCollectedBy
        case "organism": return organism
        case "sampleRole": return sampleRole.rawValue
        case "patientId": return patientId
        case "runId": return runId
        case "batchId": return batchId
        case "platePosition": return platePosition
        case "metadataTemplate": return metadataTemplate?.rawValue
        case "notes": return notes
        default: return nil
        }
    }
}

// MARK: - Clone Support

extension FASTQSampleMetadata {

    /// Generic key/value representation used by analysis-level sample metadata resolution.
    ///
    /// This keeps the existing FASTQ metadata storage format intact while allowing
    /// result bundles to freeze one effective sample metadata record per sample.
    public var sampleMetadataRecord: [String: String] {
        var record: [String: String] = [:]
        for mapping in Self.columnMapping {
            let header = mapping.csvHeaders[0]
            if let value = value(forCSVHeader: header), !value.isEmpty {
                record[header] = value
            }
        }
        for (key, value) in customFields where !value.isEmpty {
            record[key] = value
        }
        return record
    }

    /// Creates a copy of this metadata with a new sample name, preserving all other fields.
    ///
    /// Used by the "Clone Metadata From..." action to copy metadata between samples.
    /// The `sampleName` is replaced; everything else (including custom fields,
    /// template, notes, and attachments list) is copied.
    public func cloned(withName newName: String) -> FASTQSampleMetadata {
        var copy = self
        copy.sampleName = newName
        // Do not clone attachments — those are bundle-specific files
        copy.attachments = nil
        return copy
    }
}

// MARK: - Attachment Management

extension FASTQSampleMetadata {

    /// Adds an attachment filename to the metadata.
    public mutating func addAttachment(_ filename: String) {
        if attachments == nil {
            attachments = [filename]
        } else if !(attachments?.contains(filename) ?? false) {
            attachments?.append(filename)
        }
    }

    /// Removes an attachment filename from the metadata.
    public mutating func removeAttachment(_ filename: String) {
        attachments?.removeAll { $0 == filename }
        if attachments?.isEmpty == true {
            attachments = nil
        }
    }
}

// MARK: - Legacy Conversion

extension FASTQSampleMetadata {

    /// Initializes from a legacy `FASTQBundleCSVMetadata` key-value store.
    public init(from legacy: FASTQBundleCSVMetadata, fallbackName: String = "Unknown") {
        // Start with fallback name
        self.init(sampleName: fallbackName)

        // If legacy is in key-value format, map keys directly
        if legacy.isKeyValue {
            for (key, value) in legacy.keyValuePairs {
                setValue(value, forCSVHeader: key)
            }
        } else {
            // Freeform: headers are column names, first data row has values
            guard let firstRow = legacy.rows.first else { return }
            for (index, header) in legacy.headers.enumerated() where index < firstRow.count {
                setValue(firstRow[index], forCSVHeader: header)
            }
        }

        // Ensure sampleName was set (check for the fallback)
        if sampleName == fallbackName {
            if let label = legacy.displayLabel {
                sampleName = label
            }
        }
    }

    /// Converts to a legacy `FASTQBundleCSVMetadata` for per-bundle serialization.
    ///
    /// Uses freeform multi-column format with PHA4GE headers.
    public func toLegacyCSV() -> FASTQBundleCSVMetadata {
        var headers: [String] = []
        var values: [String] = []

        // Add typed fields that have values
        for mapping in Self.columnMapping {
            if let val = getProperty(mapping.keyPath), !val.isEmpty {
                headers.append(mapping.csvHeaders[0])
                values.append(val)
            }
        }

        // Add custom fields
        for (key, value) in customFields.sorted(by: { $0.key < $1.key }) {
            headers.append(key)
            values.append(value)
        }

        return FASTQBundleCSVMetadata(headers: headers, rows: [values])
    }

    /// Serializes this metadata to CSV string (single-row, PHA4GE headers).
    public func toCSVString() -> String {
        let legacy = toLegacyCSV()
        return FASTQBundleCSVMetadata.serialize(metadata: legacy)
    }
}

// MARK: - Multi-Sample CSV Parsing

extension FASTQSampleMetadata {

    /// Parses a multi-row CSV into an array of sample metadata.
    ///
    /// Each row becomes one `FASTQSampleMetadata`. The `sample_name` column
    /// is required; rows without it use the provided fallback name generator.
    ///
    /// - Parameters:
    ///   - csv: The CSV string to parse.
    ///   - fallbackName: A closure that returns a fallback name for a given row index.
    /// - Returns: Array of parsed metadata, or nil if the CSV is unparseable.
    public static func parseMultiSampleCSV(
        _ csv: String,
        fallbackName: @Sendable (Int) -> String = { "Sample_\($0 + 1)" }
    ) -> [FASTQSampleMetadata]? {
        guard let parsed = FASTQBundleCSVMetadata.parse(csv: csv) else { return nil }
        guard !parsed.headers.isEmpty else { return nil }

        var results: [FASTQSampleMetadata] = []
        for (rowIndex, row) in parsed.rows.enumerated() {
            var meta = FASTQSampleMetadata(sampleName: fallbackName(rowIndex))
            for (colIndex, header) in parsed.headers.enumerated() where colIndex < row.count {
                meta.setValue(row[colIndex], forCSVHeader: header)
            }
            results.append(meta)
        }
        return results
    }

    /// Serializes an array of sample metadata to a multi-row CSV string.
    ///
    /// Produces a CSV with PHA4GE headers for all fields that have values
    /// in at least one sample, plus any custom fields.
    public static func serializeMultiSampleCSV(_ samples: [FASTQSampleMetadata]) -> String {
        guard !samples.isEmpty else { return "" }

        // Collect all headers that have values across any sample
        var orderedHeaders: [String] = []
        var headerSet: Set<String> = []

        // First pass: typed fields in canonical order
        for mapping in columnMapping {
            let header = mapping.csvHeaders[0]
            for sample in samples {
                if let val = sample.getProperty(mapping.keyPath), !val.isEmpty {
                    if headerSet.insert(header).inserted {
                        orderedHeaders.append(header)
                    }
                    break
                }
            }
        }

        // Second pass: custom fields (sorted)
        var allCustomKeys: Set<String> = []
        for sample in samples {
            allCustomKeys.formUnion(sample.customFields.keys)
        }
        for key in allCustomKeys.sorted() {
            if headerSet.insert(key).inserted {
                orderedHeaders.append(key)
            }
        }

        // Build CSV
        var lines: [String] = []
        lines.append(orderedHeaders.map { FASTQBundleCSVMetadata.escapeCSVField($0) }.joined(separator: ","))

        for sample in samples {
            let values = orderedHeaders.map { header -> String in
                if let val = sample.value(forCSVHeader: header) {
                    return FASTQBundleCSVMetadata.escapeCSVField(val)
                }
                return ""
            }
            lines.append(values.joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
