#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BIN_DIR="${SCRIPT_DIR}/../.venv/bin"
BIN_DIR=${1:-"${DEFAULT_BIN_DIR}"}
GITHUB_REPO="stackrox/kube-linter"
TMP_PREFIX="kube-linter"

# Helper functions for logs
info() {
    echo '[INFO] ' "$@"
}

warn() {
    echo '[WARN] ' "$@" >&2
}

fatal() {
    echo '[ERROR] ' "$@" >&2
    exit 1
}

# Set os, fatal if operating system not supported
setup_verify_os() {
    if [[ -z "${OS}" ]]; then
        OS=$(uname)
    fi
    case ${OS} in
        Darwin)
            OS=darwin
            ;;
        Linux)
            OS=linux
            ;;
        *)
            fatal "Unsupported operating system ${OS}"
    esac
}

# Set arch, fatal if architecture not supported
setup_verify_arch() {
    if [[ -z "${ARCH}" ]]; then
        ARCH=$(uname -m)
    fi
    case ${ARCH} in
        arm|armv6l|armv7l)
            ARCH=""
            ;;
        arm64|aarch64|armv8l)
            ARCH="_arm64"
            ;;
        amd64)
            ARCH=""
            ;;
        x86_64)
            ARCH=""
            ;;
        *)
            fatal "Unsupported architecture ${ARCH}"
    esac
}

setup_tmp() {
    TMP_DIR=$(mktemp -d -t ${TMP_PREFIX}-install.XXXXXXXXXX)
    TMP_METADATA="${TMP_DIR}/${TMP_PREFIX}.json"
    TMP_HASH="${TMP_DIR}/${TMP_PREFIX}.hash"
    TMP_BIN="${TMP_DIR}/${TMP_PREFIX}.tar.gz"
    cleanup() {
        local code=$?
        set +e
        trap - EXIT
        rm -rf "${TMP_DIR}"
        exit ${code}
    }
    trap cleanup INT EXIT
}

# Verify existence of downloader executable
verify_downloader() {
    # Return failure if it doesn't exist or is no executable
    [[ -x "$(which "$1")" ]] || return 1

    # Set verified executable as our downloader program and return success
    DOWNLOADER=$1
    return 0
}

# Download from file from URL
download() {
    [[ $# -eq 2 ]] || fatal 'download needs exactly 2 arguments'

    case $DOWNLOADER in
        curl)
            curl -u user:$GITHUB_TOKEN -o "$1" -sfL "$2"
            ;;
        wget)
            wget --auth-no-challenge --user=user --password=$GITHUB_TOKEN -qO "$1" "$2"
            ;;
        *)
            fatal "Incorrect executable '${DOWNLOADER}'"
            ;;
    esac

    # Abort if download command failed
    [[ $? -eq 0 ]] || fatal 'Download failed'
}

# Find version from Github metadata
get_release_version() {
    if [[ -n "${KUBE_LINTER_VERSION}" ]]; then
      VERSION_KUBE_LINTER="${KUBE_LINTER_VERSION}"
    else
      info "Fetching latest kube-linter release version"
      download "${TMP_METADATA}" "https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
      VERSION_KUBE_LINTER=$(grep '"tag_name":' "${TMP_METADATA}" | sed -E 's/.*"([^"]+)".*/\1/')
    fi

    if [[ -n "${VERSION_KUBE_LINTER}" ]]; then
        info "Using ${VERSION_KUBE_LINTER} as release"
    else
        fatal "Unable to determine release version"
    fi
}

download_hash() {
    ASSET_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${VERSION_KUBE_LINTER}"

    info "Downloading hash ${ASSET_URL}"
    download "${TMP_HASH}" "${ASSET_URL}"

    HASH_EXPECTED=$(jq ".assets[] | select(.name == \"kube-linter-${OS}${ARCH}.tar.gz\") | .digest | split(\":\")[1]" -r "${TMP_HASH}")
    info "Expected hash: ${HASH_EXPECTED}"
}

# Download binary from Github URL
download_binary() {
    BIN_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION_KUBE_LINTER}/kube-linter-${OS}${ARCH}.tar.gz"
    info "Downloading binary ${BIN_URL}"
    download "${TMP_BIN}" "${BIN_URL}"
}

compute_sha256sum() {
  cmd=$(which sha256sum shasum | head -n 1)
  case $(basename "$cmd") in
    sha256sum)
      sha256sum "$1" | cut -f 1 -d ' '
      ;;
    shasum)
      shasum -a 256 "$1" | cut -f 1 -d ' '
      ;;
    *)
      fatal "Can not find sha256sum or shasum to compute checksum"
      ;;
  esac
}

# Verify downloaded binary hash
verify_binary() {
    info "Verifying binary download"
    HASH_BIN=$(compute_sha256sum "${TMP_BIN}")
    HASH_BIN=${HASH_BIN%%[[:blank:]]*}
    if [[ "${HASH_EXPECTED}" != "${HASH_BIN}" ]]; then
        fatal "Download sha256 does not match ${HASH_EXPECTED}, got ${HASH_BIN}"
    else
        info "Hash verification succeeded"
    fi
}

# Setup permissions and move binary to system directory
setup_binary() {
    info "Installing kube-linter to ${BIN_DIR}"
    
    # Create bin directory if it doesn't exist
    mkdir -p "${BIN_DIR}"
    
    # Extract binary from tar.gz
    tar -xzf "${TMP_BIN}" -C "${TMP_DIR}"
    
    # Move binary to destination
    mv "${TMP_DIR}/kube-linter" "${BIN_DIR}/kube-linter"
    chmod +x "${BIN_DIR}/kube-linter"
}

# --- add additional utility functions below ---

# main execution
{
    verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
    command -v jq >/dev/null 2>&1 || fatal 'jq is required but not installed'
    setup_verify_arch
    setup_verify_os
    setup_tmp
    get_release_version
    download_hash
    download_binary
    verify_binary
    setup_binary
}

info "Successfully installed kube-linter ${VERSION_KUBE_LINTER}"