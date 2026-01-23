#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BIN_DIR="${SCRIPT_DIR}/../.venv/bin"
BIN_DIR=${1:-"${DEFAULT_BIN_DIR}"}
TMP_PREFIX="kubectl"

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

download_hash() {
    HASH_URL="https://dl.k8s.io/release/v${VERSION_KUBECTL}/bin/${OS}/${ARCH}/kubectl.sha256"

    info "Downloading hash ${HASH_URL}"
    download "${TMP_HASH}" "${HASH_URL}"

    HASH_EXPECTED=$(cat "${TMP_HASH}")
    info "Expected hash: ${HASH_EXPECTED}"
}

# Download binary from Github URL
download_binary() {
    BIN_URL="https://dl.k8s.io/release/v${VERSION_KUBECTL}/bin/${OS}/${ARCH}/kubectl"
    info "Downloading binary ${BIN_URL}"
    download "${TMP_BIN}" "${BIN_URL}"
}


get_release_version() {
    
    if [[ -n "${VERSION_KUBECTL}" ]]; then
      TAG_NAME="v${VERSION_KUBECTL}"
    else
      info "Fetching latest kubectl release version"
      download "${TMP_METADATA}" "https://dl.k8s.io/release/stable.txt"
      TAG_NAME=`cat "${TMP_METADATA}"`
      VERSION_KUBECTL=`cat "${TMP_METADATA}" | sed 's/^v//'`
    fi
    
    info "Found tag name: ${TAG_NAME}"

    if [[ -n "${VERSION_KUBECTL}" ]]; then
        info "Using ${VERSION_KUBECTL} as release"
    else
        fatal "Unable to determine release version"
    fi
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

# Setup permissions and move binary
setup_binary() {
    chmod 755 "${TMP_BIN}"
    info "Installing kubectl to ${BIN_DIR}/kubectl"
    
    local CMD_MOVE="mv -f \"${TMP_BIN}\" \"${BIN_DIR}/kubectl\""
    local CMD_LNK="ln -sf \"${BIN_DIR}/kubectl\" \"${BIN_DIR}/k\""
    if [[ -w "${BIN_DIR}" ]]; then
        eval "${CMD_MOVE}"
        eval "${CMD_LNK}"
    else
        eval "sudo ${CMD_MOVE}"
        eval "sudo ${CMD_LNK}"
    fi
}

{
    setup_verify_os
    setup_verify_arch
    verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
    setup_tmp
    get_release_version
    download_hash
    download_binary
    verify_binary
    setup_binary
}