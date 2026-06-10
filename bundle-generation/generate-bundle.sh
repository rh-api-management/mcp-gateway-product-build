#!/usr/bin/env bash
#
# Generate MCP Gateway bundle variants using yq
#
# This script takes the upstream MCP Gateway operator bundle and transforms it
# into downstream bundles for dev, stage, and prod environments.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
CONFIG="${SCRIPT_DIR}/mcp-gateway.yaml"
IMAGE_PULLSPECS_DIR="${SCRIPT_DIR}/image-pullspecs"
ANNOTATIONS_FILE="${SCRIPT_DIR}/bundle/metadata/annotations.yaml"

# Check dependencies
if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed"
    echo "Install: https://github.com/mikefarah/yq#install"
    exit 1
fi

# Verify config files exist
if [[ ! -f "$CONFIG" ]]; then
    echo "Error: config not found at $CONFIG"
    exit 1
fi

if [[ ! -d "$IMAGE_PULLSPECS_DIR" ]]; then
    echo "Error: Image pullspecs directory not found at $IMAGE_PULLSPECS_DIR"
    exit 1
fi

UPSTREAM_BUNDLE="${PROJECT_ROOT}/$(yq '.upstream_bundle' "$CONFIG")"

if [[ ! -d "$UPSTREAM_BUNDLE" ]]; then
    echo "Error: upstream bundle not found at ${UPSTREAM_BUNDLE}"
    echo "Make sure the mcp-gateway submodule is initialized: git submodule update --init"
    exit 1
fi

echo "========================================"
echo "Loading configuration from:"
echo "  Config:      $CONFIG"
echo "  Pullspecs:   $IMAGE_PULLSPECS_DIR/"
echo "========================================"

# Read image pullspecs from individual files
MCP_GATEWAY_IMAGE=$(yq '.image' "$IMAGE_PULLSPECS_DIR/mcp-gateway.yaml")
MCP_OPERATOR_IMAGE=$(yq '.image' "$IMAGE_PULLSPECS_DIR/mcp-gateway-operator.yaml")

echo ""
echo "Image pullspecs:"
echo "  mcp_gateway:          $MCP_GATEWAY_IMAGE"
echo "  mcp_gateway_operator: $MCP_OPERATOR_IMAGE"

# Extract SHAs from the images (if digest-pinned)
MCP_GATEWAY_SHA="${MCP_GATEWAY_IMAGE##*@}"
MCP_OPERATOR_SHA="${MCP_OPERATOR_IMAGE##*@}"

# Read configuration values
CSV_NAME=$(yq '.csv.name' "$CONFIG")
CSV_VERSION=$(yq '.csv.version' "$CONFIG")
DISPLAY_NAME=$(yq '.csv.displayName' "$CONFIG")
DESCRIPTION=$(yq '.csv.description' "$CONFIG")
ICON_BASE64=$(yq '.csv.icon[0].base64data' "$CONFIG")
ICON_MEDIATYPE=$(yq '.csv.icon[0].mediatype' "$CONFIG")
DOC_URL=$(yq '.links.documentation' "$CONFIG")
REPO_URL=$(yq '.links.repository' "$CONFIG")
VALID_SUBSCRIPTION=$(yq '.validSubscription' "$CONFIG")

echo ""
echo "Configuration:"
echo "  CSV name:     $CSV_NAME"
echo "  Version:      $CSV_VERSION"
echo "  Display name: $DISPLAY_NAME"

# Build registry mappings for each environment
get_mcp_gateway_image() {
    local env=$1
    if [[ "$env" == "dev" ]]; then
        echo "$MCP_GATEWAY_IMAGE"
    else
        local registry=$(yq ".registries.${env}.\"mcp-gateway\"" "$CONFIG")
        echo "${registry}@${MCP_GATEWAY_SHA}"
    fi
}

get_mcp_operator_image() {
    local env=$1
    if [[ "$env" == "dev" ]]; then
        echo "$MCP_OPERATOR_IMAGE"
    else
        local registry=$(yq ".registries.${env}.\"mcp-gateway-operator\"" "$CONFIG")
        echo "${registry}@${MCP_OPERATOR_SHA}"
    fi
}

# Generate bundle for each environment
for env in dev stage prod; do
    output_dir="${PROJECT_ROOT}/$(yq ".output.${env}" "$CONFIG")"
    manifests_dir="${output_dir}/manifests"
    metadata_dir="${output_dir}/metadata"

    echo ""
    echo "========================================"
    echo "Generating ${env} bundle"
    echo "Output: ${output_dir}"
    echo "========================================"

    # Clean and create output directories
    rm -rf "${output_dir}"
    mkdir -p "${manifests_dir}" "${metadata_dir}"

    # Copy manifests (CSV + CRDs) from upstream
    cp "${UPSTREAM_BUNDLE}/manifests/"*.yaml "${manifests_dir}/"

    # Use downstream annotations.yaml instead of upstream
    cp "${ANNOTATIONS_FILE}" "${metadata_dir}/annotations.yaml"

    # Generate dependencies.yaml from config
    if yq -e '.dependencies' "$CONFIG" &>/dev/null; then
        yq '{"dependencies": .dependencies}' "$CONFIG" > "${metadata_dir}/dependencies.yaml"
        echo "  Dependencies: generated"
    fi

    CSV_FILE="${manifests_dir}/mcp-gateway.clusterserviceversion.yaml"

    # Get the image references for this environment
    gateway_image=$(get_mcp_gateway_image "$env")
    operator_image=$(get_mcp_operator_image "$env")

    echo "  MCP Gateway:          ${gateway_image}"
    echo "  MCP Gateway Operator: ${operator_image}"

    # Update CSV: operator container image
    yq -i '(.spec.install.spec.deployments[] | select(.name == "mcp-gateway-controller") | .spec.template.spec.containers[] | select(.name == "mcp-controller") | .image) = "'"${operator_image}"'"' "${CSV_FILE}"

    # Update CSV: containerImage annotation
    yq -i '.metadata.annotations.containerImage = "'"${operator_image}"'"' "${CSV_FILE}"

    # Update CSV: RELATED_IMAGE_ROUTER_BROKER env var
    yq -i '(.spec.install.spec.deployments[] | select(.name == "mcp-gateway-controller") | .spec.template.spec.containers[] | select(.name == "mcp-controller") | .env[] | select(.name == "RELATED_IMAGE_ROUTER_BROKER") | .value) = "'"${gateway_image}"'"' "${CSV_FILE}"

    # Update CSV: relatedImages
    yq -i ".spec.relatedImages = [{\"image\": \"${gateway_image}\", \"name\": \"router-broker\"}, {\"image\": \"${operator_image}\", \"name\": \"controller\"}]" "${CSV_FILE}"

    # Update CSV: Add RHCL-specific feature annotations from config
    yq -i '.metadata.annotations["features.operators.openshift.io/disconnected"] = "'"$(yq '.features.disconnected' "$CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/fips-compliant"] = "'"$(yq '.features.fips-compliant' "$CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/proxy-aware"] = "'"$(yq '.features.proxy-aware' "$CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/tls-profiles"] = "'"$(yq '.features.tls-profiles' "$CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/token-auth-aws"] = "'"$(yq '.features.token-auth-aws' "$CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/token-auth-azure"] = "'"$(yq '.features.token-auth-azure' "$CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/token-auth-gcp"] = "'"$(yq '.features.token-auth-gcp' "$CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/cnf"] = "'"$(yq '.features.cnf' "$CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/cni"] = "'"$(yq '.features.cni' "$CONFIG")"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations["features.operators.openshift.io/csi"] = "'"$(yq '.features.csi' "$CONFIG")"'"' "${CSV_FILE}"

    # Update CSV: valid subscription
    yq -i '.metadata.annotations["operators.openshift.io/valid-subscription"] = "[\"'"${VALID_SUBSCRIPTION}"'\"]"' "${CSV_FILE}"

    # Update CSV: Add architecture labels from config
    for arch in $(yq '.architectures[]' "$CONFIG"); do
        yq -i ".metadata.labels[\"operatorframework.io/arch.${arch}\"] = \"supported\"" "${CSV_FILE}"
    done
    yq -i '.metadata.labels["operatorframework.io/os.linux"] = "supported"' "${CSV_FILE}"

    # Update CSV: Set name, display name, description, and icon
    yq -i ".metadata.name = \"${CSV_NAME}\"" "${CSV_FILE}"
    yq -i ".spec.version = \"${CSV_VERSION}\"" "${CSV_FILE}"
    yq -i ".spec.displayName = \"${DISPLAY_NAME}\"" "${CSV_FILE}"
    yq -i ".spec.description = \"${DESCRIPTION}\"" "${CSV_FILE}"
    yq -i ".spec.icon[0].base64data = \"${ICON_BASE64}\"" "${CSV_FILE}"
    yq -i ".spec.icon[0].mediatype = \"${ICON_MEDIATYPE}\"" "${CSV_FILE}"

    # Update CSV: Set documentation and repository links
    yq -i '.metadata.annotations.vendor = "Red Hat, Inc."' "${CSV_FILE}"
    yq -i '.metadata.annotations.repository = "'"${REPO_URL}"'"' "${CSV_FILE}"
    yq -i '.metadata.annotations.support = "Red Hat"' "${CSV_FILE}"
    yq -i ".spec.links[0].name = \"Documentation\"" "${CSV_FILE}"
    yq -i ".spec.links[0].url = \"${DOC_URL}\"" "${CSV_FILE}"
    yq -i ".spec.links[1].name = \"Repository\"" "${CSV_FILE}"
    yq -i ".spec.links[1].url = \"${REPO_URL}\"" "${CSV_FILE}"

    # Update CSV: Remove replaces and skipRange (managed in catalog repo)
    yq -i 'del(.spec.replaces)' "${CSV_FILE}"
    yq -i 'del(.spec.skipRange)' "${CSV_FILE}"

    echo "  Done!"
done

echo ""
echo "========================================"
echo "All bundles generated successfully!"
echo "========================================"
echo ""
echo "Output directories:"
echo "  - bundle/       (production)"
echo "  - bundle-dev/   (development)"
echo "  - bundle-stage/ (staging)"
echo ""
