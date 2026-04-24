#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BIN_DIR="${SCRIPT_DIR}/../.venv/bin"
BIN_DIR=${1:-"${DEFAULT_BIN_DIR}"}
GITHUB_REPO="npryce/adr-tools"

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
            ARCH=arm
            ;;
        arm64|aarch64|armv8l)
            ARCH=arm64
            ;;
        amd64)
            ARCH=amd64
            ;;
        x86_64)
            ARCH=amd64
            ;;
        *)
            fatal "Unsupported architecture ${ARCH}"
    esac
}

setup_tmp() {
    TMP_DIR=$(mktemp -d -t adr-install.XXXXXXXXXX)
    TMP_METADATA="${TMP_DIR}/adr.json"
    TMP_HASH="${TMP_DIR}/adr.hash"
    TMP_BIN="${TMP_DIR}/adr.tar.gz"
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

download_tarball() {
    ASSET_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${VERSION_ADR}"

    info "Downloading asset data ${ASSET_URL}"
    download "${TMP_HASH}" "${ASSET_URL}"
    TARBALL_URL=`jq .tarball_url -r "${TMP_HASH}"`
    info "Expected tarball URL: ${TARBALL_URL}"
    download "${TMP_BIN}" "${TARBALL_URL}"
}

get_release_version() {
    if [[ -n "${ADR_VERSION}" ]]; then
      SUFFIX_URL="tags/${ADR_VERSION}"
    else
      SUFFIX_URL="latest"
    fi

    METADATA_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/${SUFFIX_URL}"

    info "Downloading metadata ${METADATA_URL}"
    download "${TMP_METADATA}" "${METADATA_URL}"

    VERSION_ADR=$(grep '"tag_name":' "${TMP_METADATA}" | sed -E 's/.*"([^"]+)".*/\1/' )
    if [[ -n "${VERSION_ADR}" ]]; then
        info "Using ${VERSION_ADR} as release"
    else
        fatal "Unable to determine release version"
    fi
}

# Setup permissions and move binary
setup_binary() {
    info "Extracting tarball to ${TMP_DIR}"
    tar -xzvf "${TMP_BIN}" -C "${TMP_DIR}"
    info "Installing adr to ${BIN_DIR}"
    cp ${TMP_DIR}/npryce-adr-tools-*/src/* "${BIN_DIR}/"
}

{
    setup_verify_os
    setup_verify_arch
    verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
    setup_tmp
    get_release_version
    download_tarball
    setup_binary
}