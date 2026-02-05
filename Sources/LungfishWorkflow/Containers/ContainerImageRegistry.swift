// ContainerImageRegistry.swift - Registry for managing container images
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - ContainerImageRegistry

/// Central registry for container images used by Lungfish.
///
/// The `ContainerImageRegistry` manages the catalog of available container images,
/// organizing them by category (core vs optional) and purpose. This enables:
///
/// - **Core Images**: Built-in tools essential for bundle creation (samtools, bcftools, etc.)
/// - **Optional Images**: Third-party tools for extended functionality (aligners, assemblers, etc.)
/// - **Custom Images**: User-provided OCI-compliant images
///
/// ## Architecture
///
/// The container system uses a layered approach:
///
/// 1. **Base VM Layer**: The vminit image provides the Linux kernel and init system
///    for Apple Containerization VMs. This is shared across all containers.
///
/// 2. **Tool Container Layer**: OCI-compliant images containing bioinformatics tools.
///    Each tool runs in its own container with the workspace mounted.
///
/// ## Image Sources
///
/// Images can come from:
/// - BioContainers (biocontainers/*)
/// - Docker Hub (library/*, user/*)
/// - GitHub Container Registry (ghcr.io/*)
/// - Custom registries
///
/// ## Example
///
/// ```swift
/// let registry = ContainerImageRegistry.shared
///
/// // Get all core images for bundle creation
/// let coreImages = registry.images(for: .core)
///
/// // Get a specific image
/// if let samtools = registry.image(id: "samtools") {
///     print("Using \(samtools.reference)")
/// }
///
/// // Register a custom image
/// try registry.register(
///     ContainerImageSpec(
///         id: "my-aligner",
///         name: "Custom Aligner",
///         reference: "myregistry.io/aligner:1.0",
///         category: .optional,
///         purpose: .alignment
///     )
/// )
/// ```
@available(macOS 26.0, *)
public actor ContainerImageRegistry {
    
    // MARK: - Singleton
    
    /// Shared instance of the image registry.
    public static let shared = ContainerImageRegistry()
    
    // MARK: - Properties
    
    private let logger = Logger(
        subsystem: "com.lungfish.workflow",
        category: "ContainerImageRegistry"
    )
    
    /// Registered images by ID.
    private var registeredImages: [String: ContainerImageSpec] = [:]
    
    /// Image availability status cache.
    private var availabilityCache: [String: ImageAvailability] = [:]
    
    // MARK: - Initialization
    
    private init() {
        // Register all default images
        for image in DefaultContainerImages.all {
            registeredImages[image.id] = image
        }
        let count = registeredImages.count
        logger.info("ContainerImageRegistry initialized with \(count) images")
    }
    
    // MARK: - Image Registration
    
    /// Registers a container image specification.
    ///
    /// - Parameter spec: The image specification to register
    /// - Throws: `ContainerImageError.imageAlreadyRegistered` if ID is taken
    public func register(_ spec: ContainerImageSpec) throws {
        guard registeredImages[spec.id] == nil else {
            throw ContainerImageError.imageAlreadyRegistered(spec.id)
        }
        registeredImages[spec.id] = spec
        logger.info("Registered image: \(spec.id) -> \(spec.reference)")
    }
    
    /// Updates an existing image specification.
    ///
    /// - Parameter spec: The updated specification
    /// - Throws: `ContainerImageError.imageNotFound` if ID doesn't exist
    public func update(_ spec: ContainerImageSpec) throws {
        guard registeredImages[spec.id] != nil else {
            throw ContainerImageError.imageNotFound(spec.id)
        }
        registeredImages[spec.id] = spec
        availabilityCache.removeValue(forKey: spec.id)
        logger.info("Updated image: \(spec.id)")
    }
    
    /// Removes an image registration.
    ///
    /// - Parameter id: The image ID to remove
    /// - Returns: The removed specification, or nil if not found
    @discardableResult
    public func remove(id: String) -> ContainerImageSpec? {
        let removed = registeredImages.removeValue(forKey: id)
        availabilityCache.removeValue(forKey: id)
        if removed != nil {
            logger.info("Removed image: \(id)")
        }
        return removed
    }
    
    // MARK: - Image Lookup
    
    /// Returns an image specification by ID.
    public func image(id: String) -> ContainerImageSpec? {
        registeredImages[id]
    }
    
    /// Returns all registered images.
    public func allImages() -> [ContainerImageSpec] {
        Array(registeredImages.values)
    }
    
    /// Returns images for a specific category.
    public func images(for category: ImageCategory) -> [ContainerImageSpec] {
        registeredImages.values.filter { $0.category == category }
    }
    
    /// Returns images for a specific purpose.
    public func images(for purpose: ImagePurpose) -> [ContainerImageSpec] {
        registeredImages.values.filter { $0.purpose == purpose }
    }
    
    /// Returns images that can process a given file extension.
    public func images(forExtension ext: String) -> [ContainerImageSpec] {
        let lowercasedExt = ext.lowercased()
        return registeredImages.values.filter { spec in
            spec.supportedExtensions.contains(lowercasedExt)
        }
    }
    
    // MARK: - Availability Tracking
    
    /// Updates the availability status for an image.
    public func setAvailability(_ availability: ImageAvailability, for imageId: String) {
        availabilityCache[imageId] = availability
    }
    
    /// Returns the cached availability status for an image.
    public func availability(for imageId: String) -> ImageAvailability? {
        availabilityCache[imageId]
    }
    
    /// Returns all images that are currently available (pulled).
    public func availableImages() -> [ContainerImageSpec] {
        registeredImages.values.filter { spec in
            availabilityCache[spec.id]?.isAvailable == true
        }
    }
    
    /// Returns core images required for bundle creation.
    public func bundleCreationImages() -> [ContainerImageSpec] {
        images(for: .core).filter { spec in
            [.indexing, .conversion, .compression].contains(spec.purpose)
        }
    }
}

// MARK: - ContainerImageSpec

/// Specification for a container image.
///
/// This describes a container image that can be used for executing bioinformatics tools.
/// Each image has a unique ID, a reference for pulling, and metadata about its purpose.
public struct ContainerImageSpec: Codable, Sendable, Identifiable, Equatable {
    
    /// Unique identifier for this image (e.g., "samtools", "bcftools").
    public let id: String
    
    /// Human-readable name.
    public let name: String
    
    /// Description of what tools/functionality this image provides.
    public let description: String
    
    /// OCI image reference (e.g., "docker.io/condaforge/mambaforge:latest").
    ///
    /// For arm64 support on Apple Silicon, prefer multi-arch images like mambaforge.
    public let reference: String
    
    /// Optional setup commands to run when the container starts.
    ///
    /// These commands are executed before the main tool command and can be used
    /// to install tools dynamically. This is useful when using a base image like
    /// mambaforge where tools need to be installed via conda/mamba.
    ///
    /// Example: `[["mamba", "install", "-y", "-c", "bioconda", "samtools=1.18"]]`
    public let setupCommands: [[String]]?
    
    /// Image category (core vs optional).
    public let category: ImageCategory
    
    /// Primary purpose of this image.
    public let purpose: ImagePurpose
    
    /// Version of the tool(s) in this image.
    public let version: String?
    
    /// File extensions this image can process.
    public let supportedExtensions: [String]
    
    /// Estimated size of the image in bytes.
    public let estimatedSizeBytes: UInt64?
    
    /// URL to documentation.
    public let documentationURL: URL?
    
    /// Whether this image requires special entitlements.
    public let requiresEntitlements: Bool
    
    /// Creates a new container image specification.
    public init(
        id: String,
        name: String,
        description: String,
        reference: String,
        category: ImageCategory,
        purpose: ImagePurpose,
        version: String? = nil,
        supportedExtensions: [String] = [],
        estimatedSizeBytes: UInt64? = nil,
        documentationURL: URL? = nil,
        requiresEntitlements: Bool = false,
        setupCommands: [[String]]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.reference = reference
        self.category = category
        self.purpose = purpose
        self.version = version
        self.supportedExtensions = supportedExtensions
        self.estimatedSizeBytes = estimatedSizeBytes
        self.documentationURL = documentationURL
        self.requiresEntitlements = requiresEntitlements
        self.setupCommands = setupCommands
    }
}

// MARK: - ImageCategory

/// Categories for container images.
public enum ImageCategory: String, Codable, Sendable, CaseIterable {
    /// Core images essential for basic Lungfish functionality.
    /// These are required for reference bundle creation.
    case core
    
    /// Optional images for extended functionality.
    /// Users can choose to download these as needed.
    case optional
    
    /// User-provided custom images.
    case custom
    
    /// Display name for the category.
    public var displayName: String {
        switch self {
        case .core: return "Core"
        case .optional: return "Optional"
        case .custom: return "Custom"
        }
    }
}

// MARK: - ImagePurpose

/// Primary purpose/function of a container image.
public enum ImagePurpose: String, Codable, Sendable, CaseIterable {
    /// File indexing (FASTA index, BAM index, etc.)
    case indexing
    
    /// Format conversion (VCF to BCF, BED to BigBed, etc.)
    case conversion
    
    /// File compression (bgzip, etc.)
    case compression
    
    /// Sequence alignment
    case alignment
    
    /// Variant calling
    case variantCalling
    
    /// Sequence assembly
    case assembly
    
    /// Quality control
    case qualityControl
    
    /// Annotation
    case annotation
    
    /// Visualization
    case visualization
    
    /// General purpose / multiple functions
    case general
    
    /// Display name.
    public var displayName: String {
        switch self {
        case .indexing: return "Indexing"
        case .conversion: return "Conversion"
        case .compression: return "Compression"
        case .alignment: return "Alignment"
        case .variantCalling: return "Variant Calling"
        case .assembly: return "Assembly"
        case .qualityControl: return "Quality Control"
        case .annotation: return "Annotation"
        case .visualization: return "Visualization"
        case .general: return "General"
        }
    }
}

// MARK: - ImageAvailability

/// Availability status for a container image.
public struct ImageAvailability: Sendable {
    /// Whether the image is available locally.
    public let isAvailable: Bool
    
    /// Size of the local image in bytes.
    public let localSizeBytes: UInt64?
    
    /// When the image was pulled.
    public let pulledAt: Date?
    
    /// Image digest for verification.
    public let digest: String?
    
    /// Creates a new availability status.
    public init(
        isAvailable: Bool,
        localSizeBytes: UInt64? = nil,
        pulledAt: Date? = nil,
        digest: String? = nil
    ) {
        self.isAvailable = isAvailable
        self.localSizeBytes = localSizeBytes
        self.pulledAt = pulledAt
        self.digest = digest
    }
    
    /// Status for an unavailable image.
    public static let unavailable = ImageAvailability(isAvailable: false)
}

// MARK: - ContainerImageError

/// Errors related to container image operations.
public enum ContainerImageError: Error, LocalizedError {
    case imageNotFound(String)
    case imageAlreadyRegistered(String)
    case pullFailed(String, String)
    case invalidReference(String)
    
    public var errorDescription: String? {
        switch self {
        case .imageNotFound(let id):
            return "Container image not found: \(id)"
        case .imageAlreadyRegistered(let id):
            return "Container image already registered: \(id)"
        case .pullFailed(let reference, let reason):
            return "Failed to pull image \(reference): \(reason)"
        case .invalidReference(let reference):
            return "Invalid image reference: \(reference)"
        }
    }
}
