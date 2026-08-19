#!/usr/bin/env bash
#
# Fetch the Savont regression fixture: a small, public Oxford Nanopore
# full-length 16S amplicon run from the ENA FASTQ CDN.
#
# Savont's output contract for full-length MHC genotyping is item 2 on the
# dependency sweep's known-risk checklist, but the check has had no real ONT
# input to run against: SavontClusteringIntegrationTests skips unless
# LUNGFISH_SAVONT_TEST_INPUT points at a FASTQ. This script fetches that FASTQ
# so the tier 3 manual verification in docs/release/dependency-sweep.md has a
# concrete, reproducible recipe.
#
# The fixture is downloaded, never committed. It lands in a cache directory
# outside the repository so repeated sweeps reuse one copy.
#
# Why a plain HTTPS fetch instead of sra-tools:
#   The ENA mirrors every SRA run as a gzipped FASTQ under a stable URL, so a
#   single curl gets the reads with no toolchain at all. sra-tools is pinned
#   build-only in the manifest and has no arm64 story, so requiring prefetch or
#   fasterq-dump here would make the Savont check depend on the one tool most
#   likely to be unavailable on the machine running the sweep.
#
# Why this accession (SRR31764993):
#   Oxford Nanopore MinION, AMPLICON strategy, full-length 16S rRNA (~1.45 kb),
#   from a synthetic/mock metagenome so the amplicon pool has genuinely
#   distinct members for Savont to cluster. 14.8 MB compressed and roughly ten
#   seconds to fetch. 97.9% of its reads fall inside Savont's default
#   1100-2000 bp window, and it is modern enough chemistry (82.8% Q20) to clear
#   Savont 0.6.3's consensus quality gate. Public, no login, no controlled
#   access.
#
#   A non-primate amplicon was chosen deliberately. Human HLA class I ONT
#   amplicon runs exist and are small (PRJNA434212, ~4.1 kb amplicons, 4-14 MB),
#   which would match the MHC genotyping domain more closely, but every such
#   run predates high-accuracy ONT chemistry: SRR6729382 clusters fine and then
#   loses all 38 consensuses to Savont 0.6.3's low-quality filter, yielding zero
#   ASVs. A fixture that produces no clusters cannot witness an output-contract
#   regression, so read accuracy won over taxonomic proximity. See
#   docs/release/dependency-sweep.md for the full comparison.
#
# Usage:
#   bash scripts/deps/fetch-savont-fixture.sh [--dest DIR] [--force] [--verify-only]
#
# Exit codes:
#   0   the fixture is present at --dest and its checksum matches
#   1   download failed, or the downloaded file failed checksum verification
#   64  bad arguments
#   66  a required external tool (curl, shasum) was not found

set -euo pipefail

# The accession and its expected bytes. These are recorded, not derived: the
# whole point of the checksum is to notice if the remote content changes, so
# reading the expected value from the remote would defeat it.
accession="SRR31764993"
fixture_url="https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR317/093/SRR31764993/SRR31764993_1.fastq.gz"
expected_sha256="d6e6ce7945d1965848cd36d1ccac6583bfe0e7292b2c02b122c8e2393fe35732"
expected_md5="5faa45002beffae3649e6aee28a4d9c8"
expected_bytes=14809727

# Default cache lives outside the repository so the FASTQ is never a candidate
# for accidental commit, and so repeated sweeps share one download.
default_dest="${HOME}/.cache/lungfish-deps/savont-fixture"

dest="${LUNGFISH_SAVONT_FIXTURE_DIR:-${default_dest}}"
force=0
verify_only=0

usage() {
    cat <<'EOF'
usage: fetch-savont-fixture.sh [--dest DIR] [--force] [--verify-only]

Fetch the Savont regression fixture (ENA run SRR31764993, Oxford Nanopore
full-length 16S amplicon, ~14.8 MB) into a cache directory outside the repo.
Idempotent: if the file is already present and its SHA-256 matches, nothing is
downloaded and the script exits 0.

Options:
  --dest DIR      directory to hold the fixture
                  (default: $LUNGFISH_SAVONT_FIXTURE_DIR, else
                  ~/.cache/lungfish-deps/savont-fixture)
  --force         re-download even if a matching file is already present
  --verify-only   verify an existing file and exit; never download
  -h, --help      print this help and exit 0

On success the last line of stdout is the absolute path to the FASTQ, so it can
be captured directly:

  export LUNGFISH_SAVONT_TEST_INPUT="$(bash scripts/deps/fetch-savont-fixture.sh | tail -1)"

Then run the integration test against it:

  LUNGFISH_SAVONT_TEST_INPUT="$LUNGFISH_SAVONT_TEST_INPUT" \
  LUNGFISH_CONDA_ROOT="$HOME/.lungfish-verify/conda" \
    swift test --filter SavontClusteringIntegrationTests
EOF
}

require_value() {
    local flag="$1" remaining="$2"
    if [[ ${remaining} -lt 2 ]]; then
        echo "${flag} requires a value" >&2
        usage >&2
        exit 64
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)
            require_value "$1" $#
            dest="$2"
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        --verify-only)
            verify_only=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

for tool in curl shasum; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "error: required tool not found: ${tool}" >&2
        exit 66
    fi
done

dest="$(python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "${dest}")"
fixture_path="${dest}/${accession}.fastq.gz"

# Report to stderr so stdout carries only the fixture path, which lets callers
# capture it with a plain command substitution.
log() { echo "$*" >&2; }

actual_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

# Returns 0 when the file at $1 is present and matches both the expected size
# and the expected digest. Size is checked first because it is the cheap way to
# catch a truncated download before hashing 15 MB.
matches_expected() {
    local path="$1"
    [[ -f "${path}" ]] || return 1
    local size
    size="$(/usr/bin/stat -f %z "${path}" 2>/dev/null || stat -c %s "${path}" 2>/dev/null || echo 0)"
    if [[ "${size}" != "${expected_bytes}" ]]; then
        log "size mismatch: expected ${expected_bytes} bytes, found ${size}"
        return 1
    fi
    local digest
    digest="$(actual_sha256 "${path}")"
    if [[ "${digest}" != "${expected_sha256}" ]]; then
        log "sha256 mismatch: expected ${expected_sha256}, found ${digest}"
        return 1
    fi
    return 0
}

if [[ ${verify_only} -eq 1 ]]; then
    if matches_expected "${fixture_path}"; then
        log "fixture verified: ${fixture_path}"
        echo "${fixture_path}"
        exit 0
    fi
    log "error: fixture missing or checksum mismatch: ${fixture_path}"
    exit 1
fi

if [[ ${force} -eq 0 ]] && matches_expected "${fixture_path}"; then
    log "fixture already present and verified: ${fixture_path}"
    echo "${fixture_path}"
    exit 0
fi

mkdir -p "${dest}"

# Download to a temporary sibling and move into place only after the checksum
# passes, so an interrupted or corrupted fetch can never leave a file that the
# idempotent path above would later accept as valid.
tmp_path="${fixture_path}.partial.$$"
cleanup() { rm -f "${tmp_path}"; }
trap cleanup EXIT

log "fetching ${accession} from ${fixture_url}"
if ! curl -fsSL --max-time 600 --retry 3 --retry-delay 2 -o "${tmp_path}" "${fixture_url}"; then
    log "error: download failed. The ENA FASTQ CDN may be unreachable, or the"
    log "       run may have been withdrawn. Check:"
    log "       https://www.ebi.ac.uk/ena/browser/view/${accession}"
    exit 1
fi

if ! matches_expected "${tmp_path}"; then
    log "error: downloaded file failed checksum verification; not installing it."
    log "       Expected sha256 ${expected_sha256} for ${accession}."
    log "       If ENA legitimately republished this run, re-verify the accession"
    log "       and update the recorded checksum in this script deliberately."
    exit 1
fi

mv -f "${tmp_path}" "${fixture_path}"
trap - EXIT

log "fixture downloaded and verified: ${fixture_path}"
echo "${fixture_path}"
