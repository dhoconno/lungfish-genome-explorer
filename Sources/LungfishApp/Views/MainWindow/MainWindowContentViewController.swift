// MainWindowContentViewController.swift - Main window content wrapper
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class MainWindowContentViewController: NSViewController {
    private let projectSession: ProjectSession
    let splitViewController: MainSplitViewController

    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.distribution = .fill
        return stack
    }()

    private let bannerView = ProjectLockWarningBannerView()

    init(projectSession: ProjectSession, splitViewController: MainSplitViewController) {
        self.projectSession = projectSession
        self.splitViewController = splitViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowContentViewController does not support storyboard initialization")
    }

    override func loadView() {
        view = NSView()
        view.addSubview(stackView)

        addChild(splitViewController)
        splitViewController.view.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(splitViewController.view)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: view.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        updateProjectLockWarningBanner()
    }

    func updateProjectLockWarningBanner(with state: ProjectOpenWarningState? = nil) {
        guard isViewLoaded else { return }

        let warningState = state ?? projectSession.openWarningState
        guard let presentation = ProjectLockWarningPresentation(state: warningState) else {
            removeBannerIfNeeded()
            return
        }

        bannerView.update(with: presentation)
        if bannerView.superview == nil {
            stackView.insertArrangedSubview(bannerView, at: 0)
        }
    }

    private func removeBannerIfNeeded() {
        guard bannerView.superview != nil else { return }
        stackView.removeArrangedSubview(bannerView)
        bannerView.removeFromSuperview()
    }
}
