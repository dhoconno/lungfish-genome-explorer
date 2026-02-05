#!/bin/bash
# Build multi-arch container images for Lungfish bioinformatics tools
# These images support both arm64 (Apple Silicon) and amd64

set -e

REGISTRY="${REGISTRY:-ghcr.io/lungfish}"
VERSION="${VERSION:-1.0.0}"

# Build and push samtools image (includes bcftools)
echo "Building samtools image..."
docker buildx build \
    --platform linux/arm64,linux/amd64 \
    --tag "${REGISTRY}/samtools:${VERSION}" \
    --tag "${REGISTRY}/samtools:latest" \
    --file Dockerfile.samtools \
    --push \
    .

# Build and push htslib image (bgzip, tabix)
echo "Building htslib image..."
docker buildx build \
    --platform linux/arm64,linux/amd64 \
    --tag "${REGISTRY}/htslib:${VERSION}" \
    --tag "${REGISTRY}/htslib:latest" \
    --file Dockerfile.htslib \
    --push \
    .

# Build and push UCSC tools image
echo "Building UCSC tools image..."
docker buildx build \
    --platform linux/arm64,linux/amd64 \
    --tag "${REGISTRY}/ucsc-tools:${VERSION}" \
    --tag "${REGISTRY}/ucsc-tools:latest" \
    --file Dockerfile.ucsc-tools \
    --push \
    .

echo "All images built and pushed successfully!"
echo ""
echo "Images available:"
echo "  ${REGISTRY}/samtools:${VERSION}"
echo "  ${REGISTRY}/htslib:${VERSION}"
echo "  ${REGISTRY}/ucsc-tools:${VERSION}"
