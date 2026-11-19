#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IMAGE="ktmtrtr/qmmm-neb-us:latest"
IMAGE="${IMAGE:-$DEFAULT_IMAGE}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [IMAGE_TAG]

Run the container verification suite (scripts/verify_container.sh and
scripts/gmx_isolated.sh) against the built Docker image.

Arguments:
  IMAGE_TAG    Docker image tag to test (default: ${DEFAULT_IMAGE}, or \$IMAGE)

Options:
  -h, --help   Show this help message and exit
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ $# -gt 0 ]]; then
    IMAGE="$1"
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker command not found in PATH." >&2
    exit 1
fi

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "ERROR: Docker image '${IMAGE}' not found locally." >&2
    echo "Build it first or pass a valid image tag as an argument." >&2
    exit 1
fi

echo "Testing container image: ${IMAGE}"
echo "Using host scripts from: ${SCRIPT_DIR}"

docker run --rm \
    -v "${SCRIPT_DIR}/verify_container.sh:/opt/bin/verify_container.sh:ro" \
    -v "${SCRIPT_DIR}/gmx_isolated.sh:/opt/bin/gmx_isolated.sh:ro" \
    "${IMAGE}" \
    /opt/bin/verify_container.sh

echo "Container verification completed successfully for '${IMAGE}'."
