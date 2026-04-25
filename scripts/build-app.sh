#!/bin/bash
# build-app.sh - Builds Lungfish.app bundle from SPM executable
# Copyright (c) 2024 Lungfish Contributors
# SPDX-License-Identifier: MIT

set -e

# Configuration
APP_NAME="Lungfish"
BUNDLE_ID="org.lungfish.genome-browser"
VERSION="0.4.0-alpha.3"
BUILD_NUMBER="1"
CONFIGURATION="release"
SKIP_BUILD=0

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") [--configuration release|debug] [--skip-build]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --configuration)
            if [ "$#" -lt 2 ]; then
                echo "Missing value for --configuration" >&2
                usage >&2
                exit 64
            fi
            CONFIGURATION="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
            shift 2
            ;;
        --debug)
            CONFIGURATION="debug"
            shift
            ;;
        --release)
            CONFIGURATION="release"
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

case "$CONFIGURATION" in
    release)
        BUILD_DIR="$PROJECT_ROOT/.build/arm64-apple-macosx/release"
        APP_DIR="$PROJECT_ROOT/build/$APP_NAME.app"
        BUILD_LABEL="release"
        ;;
    debug)
        BUILD_DIR="$PROJECT_ROOT/.build/arm64-apple-macosx/debug"
        APP_DIR="$PROJECT_ROOT/build/Debug/$APP_NAME.app"
        BUILD_LABEL="debug"
        ;;
    *)
        echo "Unsupported configuration: $CONFIGURATION" >&2
        usage >&2
        exit 64
        ;;
esac

CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo -e "${GREEN}Building Lungfish Genome Browser${NC}"
echo "=================================="
echo "Configuration: $BUILD_LABEL"

# Clean previous build
if [ -d "$APP_DIR" ]; then
    echo -e "${YELLOW}Cleaning previous build...${NC}"
    rm -rf "$APP_DIR"
fi

# Build executable
cd "$PROJECT_ROOT"
if [ "$SKIP_BUILD" -eq 1 ]; then
    echo -e "${YELLOW}Reusing existing Apple Silicon ${BUILD_LABEL} executable...${NC}"
else
    echo -e "${GREEN}Building Apple Silicon ${BUILD_LABEL} executable...${NC}"
    if [ "$CONFIGURATION" = "release" ]; then
        swift build -c release --arch arm64
    else
        swift build --arch arm64
    fi
fi

if [ ! -f "$BUILD_DIR/Lungfish" ]; then
    echo -e "${RED}Error: executable not found at $BUILD_DIR/Lungfish${NC}"
    echo -e "${RED}Run without --skip-build first to populate the SwiftPM cache.${NC}"
    exit 1
fi

# Create bundle structure
echo -e "${GREEN}Creating app bundle structure...${NC}"
mkdir -p "$(dirname "$APP_DIR")"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$BUILD_DIR/Lungfish" "$MACOS_DIR/"

CLI_SOURCE="$BUILD_DIR/lungfish-cli"
if [ -f "$CLI_SOURCE" ]; then
    echo -e "${GREEN}Copying bundled CLI...${NC}"
    /usr/bin/install -m 755 "$CLI_SOURCE" "$MACOS_DIR/lungfish-cli"
fi

echo -e "${GREEN}Copying SwiftPM resource bundles...${NC}"
while IFS= read -r -d '' bundle; do
    bundle_name="$(basename "$bundle")"
    case "$bundle_name" in
        *Tests.bundle)
            continue
            ;;
    esac
    cp -R "$bundle" "$RESOURCES_DIR/"
done < <(/usr/bin/find "$BUILD_DIR" -maxdepth 1 -type d -name '*.bundle' -print0)

# Create Info.plist
echo -e "${GREEN}Creating Info.plist...${NC}"
cat > "$CONTENTS_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Bundle Identification -->
    <key>CFBundleIdentifier</key>
    <string>org.lungfish.genome-browser</string>
    <key>CFBundleName</key>
    <string>Lungfish</string>
    <key>CFBundleDisplayName</key>
    <string>Lungfish Genome Browser</string>
    <key>CFBundleExecutable</key>
    <string>Lungfish</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleHelpBookFolder</key>
    <string>Lungfish.help</string>
    <key>CFBundleHelpBookName</key>
    <string>Lungfish Help</string>

    <!-- Version Information -->
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>

    <!-- macOS Requirements -->
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.medical</string>

    <!-- Icon -->
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>

    <!-- Document Types -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <!-- FASTA -->
        <dict>
            <key>CFBundleTypeName</key>
            <string>FASTA Sequence</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.lungfish.fasta</string>
            </array>
        </dict>
        <!-- FASTQ -->
        <dict>
            <key>CFBundleTypeName</key>
            <string>FASTQ Reads</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.lungfish.fastq</string>
            </array>
        </dict>
        <!-- GenBank -->
        <dict>
            <key>CFBundleTypeName</key>
            <string>GenBank File</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.lungfish.genbank</string>
            </array>
        </dict>
        <!-- GFF3 -->
        <dict>
            <key>CFBundleTypeName</key>
            <string>GFF3 Annotations</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.lungfish.gff3</string>
            </array>
        </dict>
        <!-- BAM -->
        <dict>
            <key>CFBundleTypeName</key>
            <string>BAM Alignment</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.lungfish.bam</string>
            </array>
        </dict>
        <!-- VCF -->
        <dict>
            <key>CFBundleTypeName</key>
            <string>VCF Variants</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.lungfish.vcf</string>
            </array>
        </dict>
    </array>

    <!-- Exported Type Declarations (Custom UTIs) -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <!-- FASTA -->
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.lungfish.fasta</string>
            <key>UTTypeDescription</key>
            <string>FASTA Sequence File</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>fa</string>
                    <string>fasta</string>
                    <string>fna</string>
                    <string>ffn</string>
                    <string>faa</string>
                </array>
            </dict>
        </dict>
        <!-- FASTQ -->
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.lungfish.fastq</string>
            <key>UTTypeDescription</key>
            <string>FASTQ Sequence Reads</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>fq</string>
                    <string>fastq</string>
                </array>
            </dict>
        </dict>
        <!-- GenBank -->
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.lungfish.genbank</string>
            <key>UTTypeDescription</key>
            <string>GenBank Sequence File</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>gb</string>
                    <string>gbk</string>
                    <string>genbank</string>
                </array>
            </dict>
        </dict>
        <!-- GFF3 -->
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.lungfish.gff3</string>
            <key>UTTypeDescription</key>
            <string>GFF3 Annotation File</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>gff</string>
                    <string>gff3</string>
                </array>
            </dict>
        </dict>
        <!-- BAM -->
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.lungfish.bam</string>
            <key>UTTypeDescription</key>
            <string>BAM Alignment File</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>bam</string>
                </array>
            </dict>
        </dict>
        <!-- VCF -->
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.lungfish.vcf</string>
            <key>UTTypeDescription</key>
            <string>VCF Variant File</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>vcf</string>
                </array>
            </dict>
        </dict>
    </array>

    <!-- URL Schemes -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>Lungfish URL</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>lungfish</string>
            </array>
        </dict>
    </array>

    <!-- Application Behavior -->
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <false/>

    <!-- Privacy Descriptions -->
    <key>NSDesktopFolderUsageDescription</key>
    <string>Lungfish needs access to read and write genome data files on your Desktop.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Lungfish needs access to read and write genome data files in your Documents folder.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Lungfish needs access to read genome data files you have downloaded.</string>

    <!-- Copyright -->
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2024 Lungfish Contributors. MIT License.</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Copy icon if exists
if [ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]; then
    echo -e "${GREEN}Copying app icon...${NC}"
    cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/"
else
    echo -e "${YELLOW}Warning: AppIcon.icns not found at $PROJECT_ROOT/Resources/AppIcon.icns${NC}"
    echo -e "${YELLOW}The app will use a generic icon until an icon is provided.${NC}"
fi

# Copy THIRD-PARTY-NOTICES into Resources
if [ -f "$PROJECT_ROOT/THIRD-PARTY-NOTICES" ]; then
    echo -e "${GREEN}Copying third-party notices...${NC}"
    cp "$PROJECT_ROOT/THIRD-PARTY-NOTICES" "$RESOURCES_DIR/"
fi

# Copy Help Book resources if available
HELP_BOOK_SRC="$PROJECT_ROOT/Sources/LungfishApp/Resources/HelpBook/Lungfish.help"
HELP_BOOK_DEST="$RESOURCES_DIR/Lungfish.help"
if [ -d "$HELP_BOOK_SRC" ]; then
    echo -e "${GREEN}Copying Help Book resources...${NC}"
    cp -R "$HELP_BOOK_SRC" "$HELP_BOOK_DEST"

    HELP_LOCALE_DIR="$HELP_BOOK_DEST/Contents/Resources/en.lproj"
    HELP_INDEX_PATH="$HELP_LOCALE_DIR/search.helpindex"
    if command -v hiutil >/dev/null 2>&1 && [ -d "$HELP_LOCALE_DIR" ]; then
        echo -e "${GREEN}Building Help Book search index...${NC}"
        hiutil -C -a -s en "$HELP_INDEX_PATH" "$HELP_LOCALE_DIR" >/dev/null 2>&1 || true
    fi
else
    echo -e "${YELLOW}Warning: Help Book bundle not found at $HELP_BOOK_SRC${NC}"
fi

WORKFLOW_BUNDLE_DIR="$RESOURCES_DIR/LungfishGenomeBrowser_LungfishWorkflow.bundle"
WORKFLOW_TOOLS_DIR="$WORKFLOW_BUNDLE_DIR/Tools"
if [ ! -d "$WORKFLOW_TOOLS_DIR" ]; then
    WORKFLOW_TOOLS_DIR="$WORKFLOW_BUNDLE_DIR/Contents/Resources/Tools"
fi
if [ -d "$WORKFLOW_TOOLS_DIR" ]; then
    if [ "$CONFIGURATION" = "release" ]; then
        echo -e "${GREEN}Sanitizing bundled executables and workflow tools...${NC}"
        /bin/bash "$PROJECT_ROOT/scripts/sanitize-bundled-tools.sh" "$MACOS_DIR" "$WORKFLOW_TOOLS_DIR"
    else
        echo -e "${GREEN}Sanitizing bundled workflow tools...${NC}"
        /bin/bash "$PROJECT_ROOT/scripts/sanitize-bundled-tools.sh" "$WORKFLOW_TOOLS_DIR"
    fi
fi

# Print success message
echo ""
echo -e "${GREEN}App bundle created successfully!${NC}"
echo "Location: $APP_DIR"
echo ""
echo "To run the app:"
echo "  open \"$APP_DIR\""
echo ""
echo "To code sign for distribution (requires Apple Developer ID):"
echo "  codesign --force --sign \"Developer ID Application: Your Name\" --options runtime \"$APP_DIR\""
echo ""
echo "To create a DMG for distribution:"
echo "  hdiutil create -volname \"Lungfish\" -srcfolder \"$APP_DIR\" -ov -format UDZO \"build/Lungfish.dmg\""
