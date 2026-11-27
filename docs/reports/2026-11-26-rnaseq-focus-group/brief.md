You are taking part in a simulated focus group about the RNA-seq features of Lungfish Genome Explorer (LGE), a macOS app for bench scientists. The source is at /Users/dho/lge/lungfish-genome-explorer (read only; do not edit or build anything).

You cannot click through the app, so reconstruct what a first-time user would SEE: read the user-visible strings and flow in these places (labels, button titles, help text, sheet titles, menu items, error messages, tooltips), and the user manual chapter:
- docs/user-manual/chapters/11-rna-seq/ (all files)
- Sources/LungfishApp/Views/FASTQ/FASTQOperationRNASeqQuantPane.swift, FASTQOperationsCatalog.swift, FASTQOperationToolPanes.swift (grep RNA)
- Sources/LungfishApp/Views/WorkflowOperations/RNASeqWorkflowPanes.swift, WorkflowOperationHelp.swift, WorkflowOperationDialogState+RNASeq.swift
- Sources/LungfishApp/Views/ImportCenter/RNASeq*.swift and ImportCenterViewModel+RNASeq*.swift
- Sources/LungfishRNASeqUI/ (result views)
- How references (genomes, annotations, indexes) are installed elsewhere in the app: grep -ril "install" Sources/LungfishApp/Views | grep -i -E "reference|database|genome" and look at that flow, and whether an RNA-seq run can use it.
- Sources/LungfishApp/App/MainMenu*.swift for where RNA-seq appears in menus.

Your persona:
PERSONA

Task: try, in your head, to go from "I have FASTQ files from an RNA-seq experiment" (bulk: e.g. 6 samples, 2 conditions; and, if your persona would, single-cell 10x) to "I have gene counts / a differential-expression style answer or a cell map", entirely inside the app. Narrate it in first person as your persona, step by step, quoting the exact on-screen words that confuse you (with file:line). Note where you would get stuck or give up, which words you do not understand, what you expected to find and where, and what is missing (for example pre-configured references such as human GRCh38 + GENCODE, mouse GRCm39, installable like other references).

End with:
1. Top 5 problems, worst first, each with the exact words and file:line.
2. Top 5 changes that would make this straightforward for you, concrete (wording, a missing step, a default, a preset reference).
3. One sentence: could you finish an analysis today without help? yes/no and why.
Keep the report under 900 words. Write plain prose and lists, no tables.
