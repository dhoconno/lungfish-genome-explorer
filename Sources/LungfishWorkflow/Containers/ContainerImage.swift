// ContainerImage.swift - Container image model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: Workflow Integration Lead (Role 14)
// Advisor: Apple Containerization Expert (Role 21)

import Foundation

// MARK: - ContainerImage

/// Represents a container image that can be used to create containers.
///
/// `ContainerImage` provides a unified representation of OCI images across
/// different container runtimes. It includes the image reference, digest,
/// and local storage information.
///
/// ## Image References
///
/// Image references follow the OCI format: `[registry/][repository/]name[:tag][@digest]`
///
/// Examples:
/// - `ubuntu:22.04`
/// - `docker.io/library/ubuntu:22.04`
/// - `quay.io/biocontainers/bwa:0.7.17--h7132678_9`
/// - `ghcr.io/nextflow-io/nextflow:24.04.0`
///
/// ## Example Usage
///
/// ```swift
/// // Pull an image
/// let image = try await runtime.pullImage(reference: "biocontainers/bwa:0.7.17")
///
/// // Access image information
/// print("Pulled \(image.reference)")
/// print("Digest: \(image.digest ?? "unknown")")
/// print("Size: \(image.sizeBytes?.formattedBytes ?? "unknown")")
///
/// // Create a container from the image
/// let container = try await runtime.createContainer(
///     name: "bwa-container",
///     image: image,
///     config: config
/// )
/// ```
public struct ContainerImage: Sendable, Codable, Identifiable, Equatable {
    // MARK: - Properties

    /// Unique identifier for this image.
    ///
    /// This is typically the image digest if available, otherwise a generated UUID.
    public let id: String

    /// OCI image reference (e.g., "docker.io/library/ubuntu:22.04").
    public let reference: String

    /// Content-addressable digest of the image.
    ///
    /// Format: `sha256:abc123...`
    /// May be `nil` if the digest is not yet known.
    public let digest: String?

    /// Path to the local rootfs directory (for Apple Containerization).
    ///
    /// This is the extracted filesystem root that can be mounted into a VM.
    /// For Docker, this is typically `nil` as Docker manages its own storage.
    public let rootfsPath: URL?

    /// Size of the image in bytes.
    public let sizeBytes: UInt64?

    /// When the image was created.
    public let createdAt: Date?

    /// When the image was pulled locally.
    public let pulledAt: Date

    /// Labels attached to the image.
    public let labels: [String: String]

    /// The architecture this image was built for.
    public let architecture: String?

    /// The operating system this image was built for.
    public let os: String?

    /// The container runtime that owns this image.
    public let runtimeType: ContainerRuntimeType

    // MARK: - Initialization

    /// Creates a new container image.
    ///
    /// - Parameters:
    ///   - id: Unique identifier
    ///   - reference: OCI image reference
    ///   - digest: Content-addressable digest
    ///   - rootfsPath: Path to local rootfs (Apple Containerization only)
    ///   - sizeBytes: Image size in bytes
    ///   - createdAt: Image creation timestamp
    ///   - pulledAt: Local pull timestamp
    ///   - labels: Image labels
    ///   - architecture: Target architecture
    ///   - os: Target operating system
    ///   - runtimeType: Owning runtime type
    public init(
        id: String = UUID().uuidString,
        reference: String,
        digest: String? = nil,
        rootfsPath: URL? = nil,
        sizeBytes: UInt64? = nil,
        createdAt: Date? = nil,
        pulledAt: Date = Date(),
        labels: [String: String] = [:],
        architecture: String? = nil,
        os: String? = nil,
        runtimeType: ContainerRuntimeType
    ) {
        self.id = id
        self.reference = reference
        self.digest = digest
        self.rootfsPath = rootfsPath
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
        self.pulledAt = pulledAt
        self.labels = labels
        self.architecture = architecture
        self.os = os
        self.runtimeType = runtimeType
    }

    // MARK: - Computed Properties

    /// The image name without registry or tag.
    ///
    /// For "docker.io/library/ubuntu:22.04", returns "ubuntu"
    public var name: String {
        let components = reference.split(separator: "/")
        let lastComponent = String(components.last ?? Substring(reference))

        // Remove tag or digest
        if let colonIndex = lastComponent.firstIndex(of: ":") {
            return String(lastComponent[..<colonIndex])
        }
        if let atIndex = lastComponent.firstIndex(of: "@") {
            return String(lastComponent[..<atIndex])
        }
        return lastComponent
    }

    /// The image tag, if present.
    ///
    /// For "ubuntu:22.04", returns "22.04"
    /// For "ubuntu@sha256:abc", returns `nil`
    public var tag: String? {
        let components = reference.split(separator: "/")
        let lastComponent = String(components.last ?? Substring(reference))

        guard let colonIndex = lastComponent.firstIndex(of: ":") else {
            return nil
        }

        let afterColon = lastComponent.index(after: colonIndex)
        let tagPart = String(lastComponent[afterColon...])

        // Check if this is a digest rather than a tag
        if tagPart.hasPrefix("sha256:") || tagPart.hasPrefix("sha512:") {
            return nil
        }

        // Remove any trailing digest
        if let atIndex = tagPart.firstIndex(of: "@") {
            return String(tagPart[..<atIndex])
        }

        return tagPart
    }

    /// The registry hosting this image.
    ///
    /// For "docker.io/library/ubuntu:22.04", returns "docker.io"
    /// For "ubuntu:22.04", returns "docker.io" (default)
    public var registry: String {
        let components = reference.split(separator: "/")

        // If there's only one component, it's a Docker Hub library image
        if components.count == 1 {
            return "docker.io"
        }

        let first = String(components.first!)

        // Check if first component looks like a registry (contains a dot or colon)
        if first.contains(".") || first.contains(":") {
            return first
        }

        // Otherwise it's a Docker Hub user image
        return "docker.io"
    }

    /// The repository path within the registry.
    ///
    /// For "docker.io/library/ubuntu:22.04", returns "library/ubuntu"
    /// For "biocontainers/bwa:0.7.17", returns "biocontainers/bwa"
    public var repository: String {
        var components = reference.split(separator: "/").map(String.init)

        // Remove registry if present
        if let first = components.first,
           first.contains(".") || first.contains(":") {
            components.removeFirst()
        }

        // Remove tag/digest from last component
        if var last = components.last {
            if let colonIndex = last.firstIndex(of: ":") {
                last = String(last[..<colonIndex])
            }
            if let atIndex = last.firstIndex(of: "@") {
                last = String(last[..<atIndex])
            }
            components[components.count - 1] = last
        }

        // Single component means Docker Hub library
        if components.count == 1 {
            return "library/\(components[0])"
        }

        return components.joined(separator: "/")
    }

    /// The short display name for this image.
    ///
    /// Returns `name:tag` if tag is present, otherwise just `name`
    public var displayName: String {
        if let tag = tag {
            return "\(name):\(tag)"
        }
        return name
    }

    /// Whether this image has been pulled locally.
    public var isPulled: Bool {
        // Docker images are always "pulled" when we have them
        if runtimeType == .docker {
            return true
        }
        // Apple Containerization images need a rootfs path
        return rootfsPath != nil
    }

    // MARK: - Reference Parsing

    /// Parses an image reference into its components.
    ///
    /// - Parameter reference: The image reference string
    /// - Returns: A tuple of (registry, repository, tag, digest)
    public static func parseReference(_ reference: String) -> (
        registry: String,
        repository: String,
        tag: String?,
        digest: String?
    ) {
        // Create a temporary image to use its parsing logic
        let image = ContainerImage(reference: reference, runtimeType: .docker)
        return (image.registry, image.repository, image.tag, image.digest)
    }

    /// Normalizes an image reference to its full form.
    ///
    /// - Parameter reference: The input reference
    /// - Returns: Normalized reference (e.g., "docker.io/library/ubuntu:latest")
    public static func normalizeReference(_ reference: String) -> String {
        let (registry, repository, tag, digest) = parseReference(reference)

        var normalized = "\(registry)/\(repository)"

        if let tag = tag {
            normalized += ":\(tag)"
        } else if digest == nil {
            normalized += ":latest"
        }

        if let digest = digest {
            normalized += "@\(digest)"
        }

        return normalized
    }
}

// MARK: - ContainerImage + Hashable

extension ContainerImage: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - ContainerImage + CustomStringConvertible

extension ContainerImage: CustomStringConvertible {
    public var description: String {
        var parts = [reference]

        if let digest = digest {
            parts.append("digest: \(digest.prefix(19))...")
        }

        if let size = sizeBytes {
            parts.append("size: \(size.formattedBytes)")
        }

        return "ContainerImage(\(parts.joined(separator: ", ")))"
    }
}

// MARK: - ImagePullProgress

/// Progress information for image pull operations.
public struct ImagePullProgress: Sendable {
    /// The layer being downloaded.
    public let layer: String?

    /// Current bytes downloaded.
    public let currentBytes: UInt64

    /// Total bytes to download.
    public let totalBytes: UInt64

    /// Overall progress fraction (0.0 to 1.0).
    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0.0 }
        return Double(currentBytes) / Double(totalBytes)
    }

    /// Progress percentage (0 to 100).
    public var percentComplete: Int {
        Int(fractionCompleted * 100)
    }

    /// Formatted progress string.
    public var displayString: String {
        if let layer = layer {
            return "\(layer): \(currentBytes.formattedBytes) / \(totalBytes.formattedBytes) (\(percentComplete)%)"
        }
        return "\(currentBytes.formattedBytes) / \(totalBytes.formattedBytes) (\(percentComplete)%)"
    }

    /// Creates a new progress update.
    public init(layer: String? = nil, currentBytes: UInt64, totalBytes: UInt64) {
        self.layer = layer
        self.currentBytes = currentBytes
        self.totalBytes = totalBytes
    }

    /// Creates a completed progress.
    public static func completed(totalBytes: UInt64) -> ImagePullProgress {
        ImagePullProgress(currentBytes: totalBytes, totalBytes: totalBytes)
    }
}
