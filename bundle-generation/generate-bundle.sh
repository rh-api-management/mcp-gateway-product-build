#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${SCRIPT_DIR}/mcp-gateway.yaml"
IMAGE_PULLSPECS="${REPO_ROOT}/image-pullspecs.yaml"

# check for yq
if ! command -v yq &>/dev/null; then
    echo "error: yq is required. install it from https://github.com/mikefarah/yq"
    exit 1
fi

# validate config exists
if [ ! -f "$CONFIG" ]; then
    echo "error: config not found at ${CONFIG}"
    exit 1
fi

if [ ! -f "$IMAGE_PULLSPECS" ]; then
    echo "error: image pullspecs not found at ${IMAGE_PULLSPECS}"
    exit 1
fi

UPSTREAM_BUNDLE="${REPO_ROOT}/$(yq '.upstream_bundle' "$CONFIG")"
DOWNSTREAM_BUNDLE="${SCRIPT_DIR}/bundle"

if [ ! -d "$UPSTREAM_BUNDLE" ]; then
    echo "error: upstream bundle not found at ${UPSTREAM_BUNDLE}"
    echo "make sure the mcp-gateway-operator submodule is initialized: git submodule update --init"
    exit 1
fi

# load CSV metadata from config
CSV_NAME="$(yq '.csv.name' "$CONFIG")"
CSV_VERSION="$(yq '.csv.version' "$CONFIG")"
CSV_DISPLAY_NAME="$(yq '.csv.displayName' "$CONFIG")"
CSV_DESCRIPTION="$(yq '.csv.description' "$CONFIG")"
CHANNEL="$(yq '.channel' "$CONFIG")"

# load icon
ICON_BASE64="$(yq '.csv.icon[0].base64data' "$CONFIG")"
ICON_MEDIATYPE="$(yq '.csv.icon[0].mediatype' "$CONFIG")"

# load links
DOCS_URL="$(yq '.links.documentation' "$CONFIG")"
REPO_URL="$(yq '.links.repository' "$CONFIG")"

# load features
DISCONNECTED="$(yq '.features.disconnected' "$CONFIG")"
FIPS="$(yq '.features.fips_compliant' "$CONFIG")"
PROXY="$(yq '.features.proxy_aware' "$CONFIG")"

# read image pullspecs
MCP_GATEWAY_IMAGE="$(yq '.images.mcp_gateway' "$IMAGE_PULLSPECS")"
MCP_OPERATOR_IMAGE="$(yq '.images.mcp_gateway_operator' "$IMAGE_PULLSPECS")"

echo "========================================"
echo "generating bundles for ${CSV_NAME} (v${CSV_VERSION})"
echo ""
echo "image pullspecs:"
echo "  mcp_gateway:  ${MCP_GATEWAY_IMAGE}"
echo "  mcp_gateway_operator: ${MCP_OPERATOR_IMAGE}"
echo "========================================"
echo ""

# extract SHAs from the images (if digest-pinned)
MCP_GATEWAY_SHA="${MCP_GATEWAY_IMAGE##*@}"
MCP_OPERATOR_SHA="${MCP_OPERATOR_IMAGE##*@}"

# helper: get the image ref for a given component and environment
get_image() {
    local component=$1
    local env=$2
    local image sha registry

    if [ "$component" = "mcp-gateway" ]; then
        image="$MCP_GATEWAY_IMAGE"
        sha="$MCP_GATEWAY_SHA"
    else
        image="$MCP_OPERATOR_IMAGE"
        sha="$MCP_OPERATOR_SHA"
    fi

    if [ "$env" = "dev" ]; then
        echo "$image"
    else
        registry="$(yq ".registries.${env}.\"${component}\"" "$CONFIG")"
        echo "${registry}@${sha}"
    fi
}

for env in dev stage prod; do
    output_dir="${REPO_ROOT}/$(yq ".output.${env}" "$CONFIG")"

    echo "=== ${env} === (${output_dir})"

    # clean and copy from upstream
    rm -rf "${output_dir}"
    mkdir -p "${output_dir}/manifests" "${output_dir}/metadata"

    # copy manifests (CSV + CRDs) from upstream
    cp "${UPSTREAM_BUNDLE}"/manifests/*.yaml "${output_dir}/manifests/"

    # copy metadata from downstream override (annotations with Red Hat-specific values)
    cp "${DOWNSTREAM_BUNDLE}"/metadata/*.yaml "${output_dir}/metadata/"
    echo "  metadata: using downstream annotations"

    csv="${output_dir}/manifests/mcp-gateway.clusterserviceversion.yaml"

    # --- CSV metadata ---
    yq -i ".metadata.name = \"${CSV_NAME}\"" "$csv"
    yq -i ".spec.version = \"${CSV_VERSION}\"" "$csv"
    yq -i ".spec.displayName = \"${CSV_DISPLAY_NAME}\"" "$csv"
    yq -i ".spec.description = \"${CSV_DESCRIPTION}\"" "$csv"
    echo "  csv: ${CSV_NAME}"

    # --- icon ---
    yq -i ".spec.icon[0].base64data = \"${ICON_BASE64}\"" "$csv"
    yq -i ".spec.icon[0].mediatype = \"${ICON_MEDIATYPE}\"" "$csv"
    echo "  icon: replaced with RHCL product icon"

    # --- links ---
    yq -i ".spec.links[0].name = \"Documentation\"" "$csv"
    yq -i ".spec.links[0].url = \"${DOCS_URL}\"" "$csv"
    yq -i ".spec.links[1].name = \"Repository\"" "$csv"
    yq -i ".spec.links[1].url = \"${REPO_URL}\"" "$csv"

    # --- annotations ---
    yq -i '.metadata.annotations.vendor = "Red Hat, Inc."' "$csv"
    yq -i ".metadata.annotations.repository = \"${REPO_URL}\"" "$csv"
    yq -i '.metadata.annotations.support = "Red Hat"' "$csv"

    # feature annotations
    yq -i ".metadata.annotations.\"features.operators.openshift.io/disconnected\" = \"${DISCONNECTED}\"" "$csv"
    yq -i ".metadata.annotations.\"features.operators.openshift.io/fips-compliant\" = \"${FIPS}\"" "$csv"
    yq -i ".metadata.annotations.\"features.operators.openshift.io/proxy-aware\" = \"${PROXY}\"" "$csv"

    # architecture labels
    for arch in $(yq '.architectures[]' "$CONFIG"); do
        yq -i ".metadata.labels.\"operatorframework.io/arch.${arch}\" = \"supported\"" "$csv"
        yq -i ".metadata.labels.\"operatorframework.io/os.linux\" = \"supported\"" "$csv"
    done
    echo "  architectures: $(yq '.architectures | join(", ")' "$CONFIG")"

    # --- image references ---
    gateway_image="$(get_image mcp-gateway "$env")"
    operator_image="$(get_image mcp-gateway-operator "$env")"

    for image_key in mcp-gateway mcp-gateway-operator; do
        upstream_ref="$(yq ".upstream.\"${image_key}\"" "$CONFIG")"
        if [ "$image_key" = "mcp-gateway" ]; then
            target_ref="$gateway_image"
        else
            target_ref="$operator_image"
        fi

        echo "  ${image_key}: ${upstream_ref} -> ${target_ref}"
        sed -i'' -e "s|${upstream_ref}|${target_ref}|g" "$csv"
    done

    # update containerImage annotation
    yq -i ".metadata.annotations.containerImage = \"${operator_image}\"" "$csv"

    # ensure relatedImages has both entries
    yq -i ".spec.relatedImages = [{\"image\": \"${gateway_image}\", \"name\": \"router-broker\"}, {\"image\": \"${operator_image}\", \"name\": \"controller\"}]" "$csv"

    # --- cleanup upstream-only fields ---
    yq -i 'del(.spec.replaces)' "$csv"
    yq -i 'del(.spec.skipRange)' "$csv"

    echo "  done"
    echo ""
done

echo "bundle generation complete. review changes with:"
echo "  git diff bundle-dev/ bundle-stage/ bundle/"
