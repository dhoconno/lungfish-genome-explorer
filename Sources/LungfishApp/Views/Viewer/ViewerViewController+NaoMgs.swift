// ViewerViewController+NaoMgs.swift - NAO-MGS result display extension
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import os.log

private let naoMgsDisplayLogger = Logger(subsystem: "com.lungfish", category: "NaoMgsDisplay")

// MARK: - ViewerViewController NAO-MGS Display Extension

extension ViewerViewController {

    /// Displays the NAO-MGS result viewer in place of the normal sequence viewer.
    ///
    /// Hides all other overlay views (FASTQ, VCF, FASTA, QuickLook, other
    /// metagenomics viewers) and adds the pre-configured
    /// `NaoMgsResultViewController` as a child view controller filling the
    /// content area.
    ///
    /// Follows the exact same child-VC pattern as ``displayTaxonomyResult(_:)``.
    ///
    /// - Parameter controller: A pre-configured `NaoMgsResultViewController`.
    public func displayNaoMgsResult(_ controller: NaoMgsResultViewController) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        contentMode = .metagenomics

        addChild(controller)

        // Wire BLAST verification callback.
        controller.onBlastVerification = { [weak self] summary, readCount, reads in
            guard let self else { return }
            let readSequences = reads.compactMap { hit -> (String, String, String)? in
                guard !hit.readSequence.isEmpty else { return nil }
                return (hit.seqId, hit.readSequence, hit.readQuality)
            }
            guard !readSequences.isEmpty else {
                naoMgsDisplayLogger.warning("BLAST verify for \(summary.name): no read sequences available")
                return
            }
            // Build FASTA from reads for BLAST submission
            var fasta = ""
            for (seqId, seq, _) in readSequences.prefix(min(50, readCount)) {
                fasta += ">\(seqId)\n\(seq)\n"
            }
            // Open NCBI BLAST web with the sequences
            let encodedFasta = fasta.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let blastURL = "https://blast.ncbi.nlm.nih.gov/Blast.cgi?PROGRAM=blastn&DATABASE=nt&QUERY=\(encodedFasta)"
            if let url = URL(string: blastURL) {
                NSWorkspace.shared.open(url)
            }
        }

        // Hide normal genomic viewer components (same pattern as Taxonomy/EsViritu/TaxTriage).
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let resultView = controller.view
        resultView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resultView)

        NSLayoutConstraint.activate([
            resultView.topAnchor.constraint(equalTo: view.topAnchor),
            resultView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            resultView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resultView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Hides the NAO-MGS result viewer if one is displayed and restores normal viewer components.
    public func hideNaoMgsView() {
        for child in children where child is NaoMgsResultViewController {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }

        // Restore normal viewer components (only if no other metagenomics viewer is active).
        // hideTaxonomyView / hideEsVirituView / hideTaxTriageView each restore these too,
        // so this guard prevents double-restore when switching between metagenomics results.
        guard taxonomyViewController == nil,
              esVirituViewController == nil,
              taxTriageViewController == nil else { return }

        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        headerView.isHidden = false
        statusBar.isHidden = false
        geneTabBarView.isHidden = (geneTabBarView.selectedGeneRegion == nil)
        annotationDrawerView?.isHidden = false
        fastqMetadataDrawerView?.isHidden = false
    }
}
