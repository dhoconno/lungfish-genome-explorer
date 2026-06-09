// FASTQPBAAArtifactsSection.swift - Inspector section for saved FASTQ pbAA artifacts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import SwiftUI

public struct FASTQPBAAArtifactRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let sampleName: String
    public let createdAt: Date
    public let clusterCountText: String
    public let clusteredReadCountText: String
    public let guideDisplayPath: String
    public let artifactDirectoryPath: String
    public let passedConsensusFASTAPath: String
    public let provenancePath: String

    init(artifact: FASTQPBAAStoredArtifact) {
        self.id = artifact.manifest.id
        self.displayName = artifact.manifest.displayName
        self.sampleName = artifact.manifest.sampleName
        self.createdAt = artifact.manifest.createdAt
        self.clusterCountText = Self.countText(
            artifact.manifest.clusterCount,
            singular: "cluster",
            plural: "clusters"
        )
        self.clusteredReadCountText = Self.countText(
            artifact.manifest.clusteredReadCount,
            singular: "clustered read",
            plural: "clustered reads"
        )
        self.guideDisplayPath = artifact.manifest.signature.guide.displayPath
        self.artifactDirectoryPath = artifact.artifactDirectoryURL.path
        self.passedConsensusFASTAPath = artifact.passedConsensusFASTAURL.path
        self.provenancePath = artifact.provenanceURL.path
    }

    private static func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

@Observable
@MainActor
public final class FASTQPBAAArtifactsSectionViewModel {
    var isExpanded = true
    private(set) var bundleURL: URL?
    private(set) var artifacts: [FASTQPBAAArtifactRow] = []
    private(set) var loadError: String?

    var hasArtifacts: Bool {
        !artifacts.isEmpty
    }

    func load(from bundleURL: URL) {
        self.bundleURL = bundleURL.standardizedFileURL
        do {
            artifacts = try FASTQPBAAArtifactStore.artifacts(in: bundleURL)
                .map(FASTQPBAAArtifactRow.init)
            loadError = nil
        } catch {
            artifacts = []
            loadError = error.localizedDescription
        }
    }

    func clear() {
        bundleURL = nil
        artifacts = []
        loadError = nil
    }
}

public struct FASTQPBAAArtifactsSection: View {
    @Bindable var viewModel: FASTQPBAAArtifactsSectionViewModel

    public var body: some View {
        if viewModel.hasArtifacts || viewModel.loadError != nil {
            DisclosureGroup(isExpanded: $viewModel.isExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if let loadError = viewModel.loadError {
                        Text(loadError)
                            .font(.caption)
                            .foregroundStyle(Color.lungfishOrangeFallback)
                    }
                    ForEach(viewModel.artifacts) { artifact in
                        artifactRow(artifact)
                    }
                }
            } label: {
                HStack {
                    Text("pbAA Artifacts")
                        .font(.headline)
                    Spacer()
                    Text("\(viewModel.artifacts.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func artifactRow(_ artifact: FASTQPBAAArtifactRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(artifact.displayName)
                .font(.subheadline.weight(.medium))
            Text("\(artifact.clusterCountText), \(artifact.clusteredReadCountText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Guide: \(artifact.guideDisplayPath)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("Clusters: \(artifact.passedConsensusFASTAPath)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("Provenance: \(artifact.provenancePath)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
