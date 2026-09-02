// XCUIAccessibilityIdentifiers.swift - Stable accessibility identifiers for XCUI-addressable surfaces
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum SettingsAccessibilityID {
    static let window = "settings-window"
    static let root = "settings-root"

    static let storageForm = "settings-storage-form"
    static let storagePath = "settings-storage-path"
    static let storageBadge = "settings-storage-badge"
    static let storageStatus = "settings-storage-status"
    static let storageOperation = "settings-storage-operation"
    static let storageWarning = "settings-storage-warning"
    static let storagePreviousRoot = "settings-storage-previous-root"
    static let storageChangeLocationButton = "settings-storage-change-location-button"
    static let storageRevealButton = "settings-storage-reveal-button"
    static let storageUseDefaultButton = "settings-storage-use-default-button"
    static let storageCleanupButton = "settings-storage-cleanup-button"

    static let aiSearchToggle = "settings-ai-search-toggle"
    static let aiPreferredProviderPicker = "settings-ai-preferred-provider-picker"
    static let aiAnthropicKeyField = "settings-ai-anthropic-key-field"
    static let aiAnthropicModelPicker = "settings-ai-anthropic-model-picker"
    static let aiOpenAIKeyField = "settings-ai-openai-key-field"
    static let aiOpenAIModelPicker = "settings-ai-openai-model-picker"
    static let aiGeminiKeyField = "settings-ai-gemini-key-field"
    static let aiGeminiModelPicker = "settings-ai-gemini-model-picker"
    static let aiClearKeysButton = "settings-ai-clear-keys-button"
    static let aiRestoreDefaultsButton = "settings-ai-restore-defaults-button"
    static let aiErrorMessage = "settings-ai-error-message"
    static let experimentalFeaturesToggle = "settings-advanced-experimental-features-toggle"
    static let analystIdentityField = "settings-general-analyst-identity-field"
    static let contentTextSizePicker = "settings-appearance-content-text-size-picker"

    static func tab(_ tab: SettingsNavigationTab) -> String {
        switch tab {
        case .general:
            "settings-tab-general"
        case .appearance:
            "settings-tab-appearance"
        case .rendering:
            "settings-tab-rendering"
        case .storage:
            "settings-tab-storage"
        case .aiServices:
            "settings-tab-ai-services"
        case .advanced:
            "settings-tab-advanced"
        }
    }

    static func panel(_ tab: SettingsNavigationTab) -> String {
        switch tab {
        case .general:
            "settings-panel-general"
        case .appearance:
            "settings-panel-appearance"
        case .rendering:
            "settings-panel-rendering"
        case .storage:
            "settings-panel-storage"
        case .aiServices:
            "settings-panel-ai-services"
        case .advanced:
            "settings-panel-advanced"
        }
    }
}

enum InspectorAccessibilityID {
    static let genotypeContentTextSizeDecrease =
        "genotype-view-content-text-size-decrease"
    static let genotypeContentTextSizeValue =
        "genotype-view-content-text-size-value"
    static let genotypeContentTextSizeIncrease =
        "genotype-view-content-text-size-increase"
    static let genotypeContentTextSizeDefault =
        "genotype-view-content-text-size-default"
    static let genotypeVisibilityGroup = "genotype-view-visibility-group"
    static let genotypeVisibilityScope = "genotype-view-visibility-scope"
    static let genotypeVisibilityStatus = "genotype-view-visibility-status"
    static let genotypeVisibilityGuidance = "genotype-view-visibility-guidance"
    static let genotypeRowVisibilityMenu = "genotype-view-row-visibility-menu"
    static let genotypeHideSelectedRows = "genotype-view-hide-selected-rows"
    static let genotypeShowOnlySelectedRows = "genotype-view-show-only-selected-rows"
    static let genotypeShowAllRows = "genotype-view-show-all-rows"
    static let genotypeColumnVisibilityMenu = "genotype-view-column-visibility-menu"
    static let genotypeHideSelectedColumns = "genotype-view-hide-selected-columns"
    static let genotypeShowOnlySelectedColumns = "genotype-view-show-only-selected-columns"
    static let genotypeShowAllColumns = "genotype-view-show-all-columns"
    static let genotypeResetVisibility = "genotype-view-reset-visibility"
    static let analystIdentityLabel = "genotype-annotation-analyst-identity-label"
    static let analystIdentitySettingsButton = "genotype-annotation-analyst-identity-settings-button"
    static let reviewGroup = "genotype-annotation-review-group"
    static let reviewSelectionSummary = "genotype-annotation-review-selection-summary"
    static let reviewEvidenceSummary = "genotype-annotation-review-evidence-summary"
    static let reviewCurrentState = "genotype-annotation-review-current-state"
    static let reviewFalsePositiveButton = "genotype-annotation-review-false-positive-button"
    static let reviewFalseNegativeButton = "genotype-annotation-review-false-negative-button"
    static let reviewClearButton = "genotype-annotation-review-clear-button"
    static let reviewDisabledReason = "genotype-annotation-review-disabled-reason"
    static let commentCellCard = "genotype-annotation-comment-card-cell"
    static let commentAlleleRowCard = "genotype-annotation-comment-card-allele-row"
    static let commentSampleColumnCard = "genotype-annotation-comment-card-sample-column"
    static let commentCellField = "genotype-annotation-comment-field-cell"
    static let commentAlleleRowField = "genotype-annotation-comment-field-allele-row"
    static let commentSampleColumnField = "genotype-annotation-comment-field-sample-column"
    static let commentCellSaveButton = "genotype-annotation-comment-save-cell"
    static let commentAlleleRowSaveButton = "genotype-annotation-comment-save-allele-row"
    static let commentSampleColumnSaveButton = "genotype-annotation-comment-save-sample-column"
    static let commentCellBulkReplaceButton =
        "genotype-annotation-comment-bulk-replace-cell"
    static let commentAlleleRowBulkReplaceButton =
        "genotype-annotation-comment-bulk-replace-allele-row"
    static let commentSampleColumnBulkReplaceButton =
        "genotype-annotation-comment-bulk-replace-sample-column"
    static let commentCellRemoveButton = "genotype-annotation-comment-remove-cell"
    static let commentAlleleRowRemoveButton =
        "genotype-annotation-comment-remove-allele-row"
    static let commentSampleColumnRemoveButton =
        "genotype-annotation-comment-remove-sample-column"
    static let commentCellDisabledReason =
        "genotype-annotation-comment-disabled-reason-cell"
    static let commentAlleleRowDisabledReason =
        "genotype-annotation-comment-disabled-reason-allele-row"
    static let commentSampleColumnDisabledReason =
        "genotype-annotation-comment-disabled-reason-sample-column"
    static let appearanceDisclosure = "genotype-annotation-appearance-disclosure"
}

enum WorkflowBuilderAccessibilityID {
    static let experimentalBanner = "workflow-builder-experimental-banner"
}

enum WorkflowOperationsAccessibilityID {
    static let window = "workflow-operations-window"
}

enum ImportCenterAccessibilityID {
    static let window = "import-center-window"
    static let root = "import-center-root"
    static let header = "import-center-header"
    static let sidebar = "import-center-sidebar"
    static let cardList = "import-center-card-list"

    static func tab(_ tab: ImportCenterViewModel.Tab) -> String {
        switch tab {
        case .sequencingReads:
            "import-center-tab-sequencing-reads"
        case .alignments:
            "import-center-tab-alignments"
        case .variants:
            "import-center-tab-variants"
        case .classificationResults:
            "import-center-tab-classification-results"
        case .references:
            "import-center-tab-references"
        case .applicationExports:
            "import-center-tab-application-exports"
        }
    }

    static func cardID(_ id: String) -> String {
        "import-center-card-\(id)"
    }

    static func buttonID(_ id: String) -> String {
        "import-center-button-\(id)"
    }
}

enum MainWindowAccessibilityID {
    static let projectLockBanner = "main-window-project-lock-banner"
    static let projectLockBannerTitle = "main-window-project-lock-banner-title"
    static let projectLockBannerDetail = "main-window-project-lock-banner-detail"
}

enum MainMenuAccessibilityID {
    static let applicationMenu = "main-menu-application"
    static let fileMenu = "main-menu-file"
    static let editMenu = "main-menu-edit"
    static let viewMenu = "main-menu-view"
    static let sequenceMenu = "main-menu-sequence"
    static let toolsMenu = "main-menu-tools"
    static let operationsMenu = "main-menu-operations"
    static let windowMenu = "main-menu-window"
    static let helpMenu = "main-menu-help"

    static let about = "main-menu-about"
    static let checkForUpdates = "main-menu-check-for-updates"
    static let settings = "main-menu-settings"
    static let quit = "main-menu-quit"

    static let newProject = "file-menu-new-project"
    static let openProjectFolder = "file-menu-open-project-folder"
    static let openRecent = "file-menu-open-recent"
    static let importCenter = "file-menu-import-center"
    static let export = "file-menu-export"
    static let manageProjectStorage = "file-menu-manage-project-storage"

    static let focusViewer = "view-menu-focus-viewer"
    static let restoreSidePanes = "view-menu-restore-side-panes"
    static let contentTextSize = "view-menu-content-text-size"
    static let contentTextSizeLarger = "view-menu-content-text-size-larger"
    static let contentTextSizeSmaller = "view-menu-content-text-size-smaller"
    static let contentTextSizeDefault = "view-menu-content-text-size-default"

    static let callVariants = "tools-menu-call-variants"
    static let freyjaDemix = "tools-menu-freyja-demix"
    static let haplotypeDefinitions = "tools-menu-haplotype-definitions"
    static let workflowLibrary = "tools-menu-workflow-library"
    static let workflowBuilder = "tools-menu-workflow-builder"
    static let pluginManager = "tools-menu-plugin-manager"
    static let showOperationsPanel = "operations-menu-show-panel"
    static let newWindowForCurrentProject = "window-menu-new-window-current-project"
    static let setWindowSize = "window-menu-set-size"

    static let helpHome = "help-menu-lungfish-help"
    static let gettingStarted = "help-menu-getting-started"
    static let vcfGuide = "help-menu-vcf-variants-guide"
    static let aiGuide = "help-menu-ai-assistant-guide"
    static let onlineDocumentation = "help-menu-online-documentation"
    static let releaseNotes = "help-menu-release-notes"
    static let reportIssue = "help-menu-report-issue"
}

enum ProjectStorageAccessibilityID {
    static let sheet = "project-storage-sheet"
    static let root = "project-storage-root"
    static let title = "project-storage-title"
    static let outline = "project-storage-outline"
    static let summary = "project-storage-summary"
    static let status = "project-storage-status"
    static let progress = "project-storage-progress"
    static let cancelButton = "project-storage-cancel"
    static let cleanupButton = "project-storage-move-to-trash"
    static let retryScanButton = "project-storage-retry-scan"
    static let retryFailedButton = "project-storage-retry-failed"
    static let revealReceiptButton = "project-storage-reveal-receipt"
    static let revealTrashButton = "project-storage-reveal-trash"
    static let categoryCheckboxPrefix = "project-storage-category-"
    static let entryCheckboxPrefix = "project-storage-entry-"
    static let sidebarCommand = "project-storage-sidebar-command"
}

enum ViralReconAccessibilityID {
    static let root = "viral-recon-root"
    static let inputSummary = "viral-recon-input-summary"
    static let platformPicker = "viral-recon-platform-picker"
    static let primerPicker = "viral-recon-primer-picker"
    static let minimumMappedReadsStepper = "viral-recon-minimum-mapped-reads-stepper"
    static let readinessLabel = "viral-recon-readiness-label"
}
