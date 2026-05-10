# Advanced Tool Options Design

## Goal

Expose one advanced command-line options string for assembler, mapper, and viral variant caller workflows while keeping the built-in controls simple and preserving reproducibility in provenance.

## Decision

Use a shared shell-like tokenizer that turns a user-entered string into process arguments. The application and CLI pass the resulting `[String]` into existing request models where available, rather than storing a raw shell command or executing through a shell.

## Scope

- Assembly keeps curated toggles, but renames the arbitrary field to "Advanced Options" and adds a CLI `--advanced-options` string. Existing repeatable `--extra-arg` remains accepted for compatibility.
- Mapping replaces minimap2-specific score/seed/bandwidth CLI and dialog fields with one tool-neutral advanced options string. The existing `MappingRunRequest.advancedArguments`, command builders, and mapping provenance remain the execution path.
- Variant calling adds `advancedArguments` to `BundleVariantCallingRequest`, exposes it in the dialog and `variants call --advanced-options`, injects it into the selected caller command, and records it in caller parameters metadata plus the executed command line.

## Constraints

- Advanced options are intentionally unchecked for tool validity; users are responsible for tool-specific syntax.
- Arguments are passed to `Process` as an argument array. No shell evaluation, redirection, pipes, command substitution, or environment expansion is performed.
- Existing primary controls remain authoritative unless the user supplies conflicting advanced flags. Tool behavior decides conflicts.

## Testing

- Add parser tests for whitespace, quotes, and escapes.
- Add CLI parsing/reconstruction tests for assembly, mapping, and variants.
- Add workflow tests showing advanced arguments enter mapper, assembler, and variant caller command lines.
- Add UI state tests for variant request construction and source-text checks for dialog labels where direct SwiftUI interaction is not practical.
