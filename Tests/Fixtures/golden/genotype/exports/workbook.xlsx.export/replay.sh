#!/bin/sh
replay_default_output='<RUN_ROOT>/genotype/exports/workbook.xlsx'
exec '<RUN_ROOT>/bin/lungfish-cli' 'genotype' 'export-xlsx' '--snapshot' '<RUN_ROOT>/genotype/exports/workbook.xlsx.export-<UUID-1>/snapshot.json' '--provenance-request' '<RUN_ROOT>/genotype/exports/workbook.xlsx.export-<UUID-1>/request.json' '--python' '/Users/dho/.lungfish-stable/conda/envs/openpyxl/bin/python' --output "${1:-$replay_default_output}"
