#!/bin/bash
# build-app.sh - Builds Lungfish.app bundle from SPM executable
# Copyright (c) 2024 Lungfish Contributors
# SPDX-License-Identifier: MIT

set -e

# Configuration
APP_NAME="Lungfish"
BUNDLE_ID="org.lungfish.genome-browser"
VERSION="1.0.1"
BUILD_NUMBER="7"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_ROOT/.build/arm64-apple-macosx/release"
APP_DIR="$PROJECT_ROOT/build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Building Lungfish Genome Browser${NC}"
echo "=================================="

# Clean previous build
if [ -d "$APP_DIR" ]; then
    echo -e "${YELLOW}Cleaning previous build...${NC}"
    rm -rf "$APP_DIR"
fi

# Build release executable
echo -e "${GREEN}Building Apple Silicon release executable...${NC}"
cd "$PROJECT_ROOT"
swift build -c release --arch arm64

if [ ! -f "$BUILD_DIR/Lungfish" ]; then
    echo -e "${RED}Error: Build failed - executable not found${NC}"
    exit 1
fi

# Create bundle structure
echo -e "${GREEN}Creating app bundle structure...${NC}"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$BUILD_DIR/Lungfish" "$MACOS_DIR/"

# Create Info.plist
echo -e "${GREEN}Creating Info.plist...${NC}"
cat > "$CONTENTS_DIR/Info.plist" << 'EOF'
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
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>7</string>

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
