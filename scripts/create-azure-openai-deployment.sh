#!/bin/bash
#
# create-azure-openai-deployment.sh - Create an Azure OpenAI model deployment.
#
# Usage:
#   scripts/create-azure-openai-deployment.sh \
#     --resource-group <group> \
#     --account-name <azure-openai-resource> \
#     --deployment-name <deployment> \
#     --model-name <model> \
#     --model-version <version>
#
# Common example:
#   scripts/create-azure-openai-deployment.sh \
#     -g lungfish-rg \
#     -n lungfish-ai \
#     --deployment-name gpt-5-mini \
#     --model-name gpt-5-mini \
#     --model-version 2025-08-07 \
#     --sku-name Standard \
#     --sku-capacity 1
#
# Environment fallbacks:
#   AZURE_OPENAI_RESOURCE_GROUP
#   AZURE_OPENAI_ACCOUNT_NAME
#   AZURE_OPENAI_DEPLOYMENT
#   AZURE_OPENAI_MODEL_NAME
#   AZURE_OPENAI_MODEL_VERSION
#   AZURE_SUBSCRIPTION

set -euo pipefail

usage() {
    sed -n '2,/^$/p' "$0" | sed '/^$/d; s/^# \{0,1\}//'
}

error() {
    echo "Error: $1" >&2
    echo "Run '$0 --help' for usage." >&2
    exit 64
}

shell_quote() {
    printf '%q' "$1"
}

print_command() {
    local arg
    for arg in "$@"; do
        shell_quote "$arg"
        printf ' '
    done | sed 's/ $//'
    printf '\n'
}

RESOURCE_GROUP="${AZURE_OPENAI_RESOURCE_GROUP:-}"
ACCOUNT_NAME="${AZURE_OPENAI_ACCOUNT_NAME:-}"
DEPLOYMENT_NAME="${AZURE_OPENAI_DEPLOYMENT:-}"
MODEL_NAME="${AZURE_OPENAI_MODEL_NAME:-}"
MODEL_VERSION="${AZURE_OPENAI_MODEL_VERSION:-}"
MODEL_FORMAT="OpenAI"
SKU_NAME="Standard"
SKU_CAPACITY="1"
SCALE_TYPE=""
SPILLOVER_DEPLOYMENT_NAME=""
SUBSCRIPTION="${AZURE_SUBSCRIPTION:-}"
MODEL_SOURCE=""
DRY_RUN=false
OUTPUT_FORMAT="json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--resource-group)
            RESOURCE_GROUP="${2:-}"
            shift 2
            ;;
        -n|--account-name|--name)
            ACCOUNT_NAME="${2:-}"
            shift 2
            ;;
        --deployment-name)
            DEPLOYMENT_NAME="${2:-}"
            shift 2
            ;;
        --model-name)
            MODEL_NAME="${2:-}"
            shift 2
            ;;
        --model-version)
            MODEL_VERSION="${2:-}"
            shift 2
            ;;
        --model-format)
            MODEL_FORMAT="${2:-}"
            shift 2
            ;;
        --model-source)
            MODEL_SOURCE="${2:-}"
            shift 2
            ;;
        --sku-name|--sku)
            SKU_NAME="${2:-}"
            shift 2
            ;;
        --sku-capacity|--capacity)
            SKU_CAPACITY="${2:-}"
            shift 2
            ;;
        --scale-type)
            SCALE_TYPE="${2:-}"
            shift 2
            ;;
        --spillover-deployment-name|--spillover-name)
            SPILLOVER_DEPLOYMENT_NAME="${2:-}"
            shift 2
            ;;
        --subscription)
            SUBSCRIPTION="${2:-}"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FORMAT="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "unknown option: $1"
            ;;
    esac
done

[ -n "$RESOURCE_GROUP" ] || error "--resource-group is required"
[ -n "$ACCOUNT_NAME" ] || error "--account-name is required"
[ -n "$MODEL_NAME" ] || error "--model-name is required"
[ -n "$MODEL_VERSION" ] || error "--model-version is required"

if [ -z "$DEPLOYMENT_NAME" ]; then
    DEPLOYMENT_NAME="$MODEL_NAME"
fi

[ -n "$DEPLOYMENT_NAME" ] || error "--deployment-name is required"
[ -n "$MODEL_FORMAT" ] || error "--model-format must not be empty"
[ -n "$SKU_NAME" ] || error "--sku-name must not be empty"
[ -n "$SKU_CAPACITY" ] || error "--sku-capacity must not be empty"

COMMAND=(
    az cognitiveservices account deployment create
    --resource-group "$RESOURCE_GROUP"
    --name "$ACCOUNT_NAME"
    --deployment-name "$DEPLOYMENT_NAME"
    --model-name "$MODEL_NAME"
    --model-version "$MODEL_VERSION"
    --model-format "$MODEL_FORMAT"
    --sku-name "$SKU_NAME"
    --sku-capacity "$SKU_CAPACITY"
)

if [ -n "$MODEL_SOURCE" ]; then
    COMMAND+=(--model-source "$MODEL_SOURCE")
fi

if [ -n "$SCALE_TYPE" ]; then
    COMMAND+=(--scale-type "$SCALE_TYPE")
fi

if [ -n "$SPILLOVER_DEPLOYMENT_NAME" ]; then
    COMMAND+=(--spillover-deployment-name "$SPILLOVER_DEPLOYMENT_NAME")
fi

if [ -n "$SUBSCRIPTION" ]; then
    COMMAND+=(--subscription "$SUBSCRIPTION")
fi

COMMAND+=(--output "$OUTPUT_FORMAT")

echo "Azure OpenAI deployment request:"
echo "  resource group:   $RESOURCE_GROUP"
echo "  account name:     $ACCOUNT_NAME"
echo "  deployment name:  $DEPLOYMENT_NAME"
echo "  model:            $MODEL_FORMAT / $MODEL_NAME / $MODEL_VERSION"
echo "  sku:              $SKU_NAME capacity $SKU_CAPACITY"
if [ -n "$SCALE_TYPE" ]; then
    echo "  scale type:       $SCALE_TYPE"
fi
if [ -n "$SUBSCRIPTION" ]; then
    echo "  subscription:     $SUBSCRIPTION"
fi
echo

if $DRY_RUN; then
    echo "Dry run. Command that would be executed:"
    print_command "${COMMAND[@]}"
    exit 0
fi

if ! command -v az >/dev/null 2>&1; then
    echo "Error: Azure CLI 'az' was not found in PATH." >&2
    echo "Install it from https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
    exit 127
fi

echo "Using Azure CLI:"
az version --query '"azure-cli"' --output tsv 2>/dev/null || az version
echo
echo "Executing:"
print_command "${COMMAND[@]}"
echo

"${COMMAND[@]}"
