#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BIN_DIR="${SCRIPT_DIR}/../.venv/bin"
BIN_DIR=${1:-"${DEFAULT_BIN_DIR}"}
GITHUB_REPO="projectcalico/calico"
TMP_PREFIX="calicoctl"
CALICO_KUSTOMIZATION="${SCRIPT_DIR}/../applications/calico/base/kustomization.yaml"

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
        amd64|x86_64)
            ARCH=amd64
            ;;
        *)
            fatal "Unsupported architecture ${ARCH}"
    esac
}

setup_tmp() {
    TMP_DIR=$(mktemp -d -t ${TMP_PREFIX}-install.XXXXXXXXXX)
    TMP_HASH="${TMP_DIR}/${TMP_PREFIX}.json"
    TMP_BIN="${TMP_DIR}/${TMP_PREFIX}"
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

# Download from file from URL, retrying transient failures (e.g. curl error 92, HTTP/2 stream reset)
download() {
    [[ $# -eq 2 ]] || fatal 'download needs exactly 2 arguments'

    local attempt rc
    for attempt in 1 2 3; do
        rc=0
        case $DOWNLOADER in
            curl)
                curl -u user:$GITHUB_TOKEN -o "$1" -sfL "$2" || rc=$?
                ;;
            wget)
                wget --auth-no-challenge --user=user --password=$GITHUB_TOKEN -qO "$1" "$2" || rc=$?
                ;;
            *)
                fatal "Incorrect executable '${DOWNLOADER}'"
                ;;
        esac
        [[ ${rc} -eq 0 ]] && return 0
        warn "Download attempt ${attempt} failed (exit ${rc}), retrying"
        sleep 2
    done

    fatal 'Download failed'
}

# calicoctl must match the Calico version the cluster runs: a newer client can
# refuse to talk to (or misread) an older datastore. Default to the tigera-operator
# chart version pinned in applications/calico/base, override with VERSION_CALICOCTL.
get_release_version() {
    if [[ -z "${VERSION_CALICOCTL}" ]]; then
        [[ -f "${CALICO_KUSTOMIZATION}" ]] || fatal "Set VERSION_CALICOCTL: ${CALICO_KUSTOMIZATION} not found"
        VERSION_CALICOCTL=$(grep -E '^[[:space:]]+version:[[:space:]]*v[0-9]' "${CALICO_KUSTOMIZATION}" | head -n 1 | awk '{print $2}')
    fi

    [[ -n "${VERSION_CALICOCTL}" ]] || fatal "Unable to determine calicoctl version"
    # Release tags are v-prefixed
    VERSION_CALICOCTL="v${VERSION_CALICOCTL#v}"
    info "Using calicoctl ${VERSION_CALICOCTL}"
}

# The release API publishes a sha256 digest per asset
download_hash() {
    ASSET_NAME="calicoctl-${OS}-${ARCH}"
    ASSET_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${VERSION_CALICOCTL}"

    info "Downloading hash ${ASSET_URL}"
    download "${TMP_HASH}" "${ASSET_URL}"

    HASH_EXPECTED=$(jq ".assets[] | select(.name == \"${ASSET_NAME}\") | .digest | split(\":\")[1]" -r "${TMP_HASH}")
    [[ -n "${HASH_EXPECTED}" && "${HASH_EXPECTED}" != "null" ]] || fatal "No ${ASSET_NAME} asset found for ${VERSION_CALICOCTL}"
    info "Expected hash: ${HASH_EXPECTED}"
}

# Download binary from Github URL
download_binary() {
    BIN_URL="https://github.com/${GITHUB_REPO}/releases/download/${VERSION_CALICOCTL}/${ASSET_NAME}"
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

# Setup permissions and move binary
setup_binary() {
    chmod 755 "${TMP_BIN}"
    info "Installing calicoctl to ${BIN_DIR}/calicoctl"
    mkdir -p "${BIN_DIR}" 2>/dev/null || true

    local CMD_MOVE="mv -f \"${TMP_BIN}\" \"${BIN_DIR}/calicoctl\""
    if [[ -w "${BIN_DIR}" ]]; then
        eval "${CMD_MOVE}"
    else
        eval "sudo ${CMD_MOVE}"
    fi
}

# Installed client version, empty if calicoctl is absent or unreadable
installed_version() {
    "${BIN_DIR}/calicoctl" version 2>/dev/null | awk '/Client Version/ {print $3}' | head -n 1
}

{
    get_release_version
    if [ -x "${BIN_DIR}/calicoctl" ]; then
        INSTALLED=$(installed_version)
        if [[ "v${INSTALLED#v}" == "${VERSION_CALICOCTL}" ]]; then
            info "calicoctl ${VERSION_CALICOCTL} already installed at ${BIN_DIR}/calicoctl, skipping"
            exit 0
        fi
        warn "calicoctl at ${BIN_DIR}/calicoctl is '${INSTALLED:-unknown}', replacing with ${VERSION_CALICOCTL}"
    fi
    setup_verify_os
    setup_verify_arch
    verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
    setup_tmp
    download_hash
    download_binary
    verify_binary
    setup_binary
}
