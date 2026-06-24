# LGE Zip Import Design

## Goal

When a user imports a ZIP-compressed Lungfish Genome Explorer object, Lungfish should transparently extract the archive, locate the contained LGE object, and pass that decompressed object through the existing import pipeline.

## Scope

The ZIP behavior is intentionally limited to archives that contain recognized LGE objects. Arbitrary ZIP archives should not be imported as loose files through the sidebar/file import pipeline. If a ZIP contains no recognized LGE object, or contains multiple top-level recognized LGE objects, import should fail with a clear error.

## Architecture

Add an app-level ZIP resolver that runs before sidebar import planning. It extracts candidate `.zip` files into a project-local temporary directory, validates the archive member paths, discovers one recognized LGE object, and replaces the original ZIP URL with the extracted object URL. Existing format-specific import code then handles the decompressed object.

For `.lungfishmhcref.zip`, this means the extracted `.lungfishmhcref` directory goes through `HaplotypeDefinitionCommandService.installMHCReferenceBundle`, preserving the normal project install and provenance behavior. The temporary extraction directory is removed after the import attempt. The original ZIP file on disk is never deleted or modified.

## Recognized Objects

The initial recognition set covers current directory bundle extensions handled by sidebar import:

- `.lungfishref`
- `.lungfishfastq`
- `.lungfishmhcref`
- `.lungfishmsa`
- `.lungfishtree`

## Error Handling

The resolver reports per-source failures through the existing `.sidebarFileDropCompleted` notification flow. It should not silently fall back to importing the ZIP file as a generic project file when the user selected a ZIP that is not an LGE object container.

## Testing

Unit tests cover successful `.lungfishmhcref.zip` resolution, cleanup of temporary extraction after the operation closes, rejection of non-LGE ZIP archives, and rejection of archives with multiple recognized LGE objects.
