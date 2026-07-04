#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BIN_DIR="${SCRIPT_DIR}/../.venv/bin"
BIN_DIR=${1:-"${DEFAULT_BIN_DIR}"}
GITHUB_REPO="smallstep/cli"
TAG_PREFIX="v"
TMP_PREFIX="step"

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
    TMP_HASH="${TMP_DIR}/${TMP_PREFIX}.checksums"
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
    [[ -x "$(which "$1")" ]] || return 1
    DOWNLOADER=$1
    return 0
}

# Download a file from URL
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

    [[ $? -eq 0 ]] || fatal 'Download failed'
}

get_release_version() {
    if [[ -n "${VERSION_STEP}" ]]; then
        TAG_NAME="${TAG_PREFIX}${VERSION_STEP}"
    else
        info "Fetching latest step release version"
        download "${TMP_METADATA}" "https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
        TAG_NAME=$(jq -r '.tag_name' "${TMP_METADATA}")
        VERSION_STEP=$(jq -r '.tag_name | ltrimstr("'${TAG_PREFIX}'")' "${TMP_METADATA}")
    fi

    info "Found tag name: ${TAG_NAME}"

    if [[ -n "${VERSION_STEP}" ]]; then
        info "Using ${VERSION_STEP} as release"
    else
        fatal "Unable to determine release version"
    fi
}

download_hash() {
    HASH_URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG_NAME}/checksums.txt"
    ASSET_NAME="step_${OS}_${ARCH}.tar.gz"

    info "Downloading checksums ${HASH_URL}"
    download "${TMP_HASH}" "${HASH_URL}"

    HASH_EXPECTED=$(grep " ${ASSET_NAME}$" "${TMP_HASH}" | awk '{print $1}')
    [[ -n "${HASH_EXPECTED}" ]] || fatal "Could not find checksum for ${ASSET_NAME}"
    info "Expected hash: ${HASH_EXPECTED}"
}

download_binary() {
    BIN_URL="https://github.com/${GITHUB_REPO}/releases/download/${TAG_NAME}/step_${OS}_${ARCH}.tar.gz"
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

setup_binary() {
    info "Extracting step binary"
    tar -xzf "${TMP_BIN}" -C "${TMP_DIR}" "step_${OS}_${ARCH}/bin/step"

    chmod 755 "${TMP_DIR}/step_${OS}_${ARCH}/bin/step"
    info "Installing step to ${BIN_DIR}/step"

    local CMD_MOVE="mv -f \"${TMP_DIR}/step_${OS}_${ARCH}/bin/step\" \"${BIN_DIR}/step\""
    if [[ -w "${BIN_DIR}" ]]; then
        eval "${CMD_MOVE}"
    else
        eval "sudo ${CMD_MOVE}"
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
