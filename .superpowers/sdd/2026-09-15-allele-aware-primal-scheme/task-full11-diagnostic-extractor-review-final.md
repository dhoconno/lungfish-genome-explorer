# External specificity extractor v3: root review

Approved after reading v2→v3 diff and failure/binding tests. Four consumed panel artifacts must match the audit input inventory by contained relative path, SHA-256 and size. Available wrapper output records bind native/audit receipts and validation bytes while allowing relocation. Missing/deleted inputs and secondary inventory/stat failures retain the original error and a failed receipt. V2 remains immutable.

Independent verification: frozen matrix10 Python ran `test_selection_specificity_extractor_v3.py`: **10 passed in 0.12s**, exit 0. Verified the retained `concrete05-600-selection-diagnostic-v3-01/provenance.json`: success/exit0, 10.63671996 seconds, all three input/source/runtime stat invariants true, 11 receipt bindings, no secondary errors. Current script SHA-256 matches its retained identity: `073f698299a203a32816775fed557c35cc4793fcaa29546e8b0534e4e3d5fc1a`.

This approval covers bounded extraction of retained diagnostic evidence from completed, audited panels. It does not establish a feasible panel or authorize reading the active full11 database through this workflow.
