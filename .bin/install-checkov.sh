#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${SCRIPT_DIR}/.."
DEFAULT_BIN_DIR="${WORKSPACE_DIR}/.venv/bin"
BIN_DIR=${1:-"${DEFAULT_BIN_DIR}"}
CHECKOV_VENV_DIR="${WORKSPACE_DIR}/.venv-checkov"
# Resolved by find_venv_python once the venv exists; the interpreter name
# inside a venv depends on how it was created (python3, python, python3.14, ...).
CHECKOV_PYTHON_BIN=""
CHECKOV_EXECUTABLE="${CHECKOV_VENV_DIR}/bin/checkov"

# Helper functions for logs
info() {
    echo '[INFO] ' "$@"
}

fatal() {
    echo '[ERROR] ' "$@" >&2
    exit 1
}

get_bootstrap_python() {
    if [[ -x "${DEFAULT_BIN_DIR}/python3" ]]; then
        BOOTSTRAP_PYTHON="${DEFAULT_BIN_DIR}/python3"
    elif command -v python3 >/dev/null 2>&1; then
        BOOTSTRAP_PYTHON="$(command -v python3)"
    elif command -v python >/dev/null 2>&1; then
        BOOTSTRAP_PYTHON="$(command -v python)"
    else
        fatal 'python3 is required to create the checkov virtual environment'
    fi
}

# Sets CHECKOV_PYTHON_BIN to the first working interpreter in the venv, or
# returns non-zero if there is none (missing, or a dangling symlink).
find_venv_python() {
    local candidate
    CHECKOV_PYTHON_BIN=""
    for candidate in "${CHECKOV_VENV_DIR}"/bin/python3 "${CHECKOV_VENV_DIR}"/bin/python "${CHECKOV_VENV_DIR}"/bin/python3.[0-9]*; do
        if [[ -x "${candidate}" ]] && "${candidate}" -c 'import sys' >/dev/null 2>&1; then
            CHECKOV_PYTHON_BIN="${candidate}"
            return 0
        fi
    done
    return 1
}

setup_checkov_venv() {
    if ! find_venv_python; then
        info "Creating isolated checkov virtual environment at ${CHECKOV_VENV_DIR}"
        "${BOOTSTRAP_PYTHON}" -m venv --clear "${CHECKOV_VENV_DIR}"
        find_venv_python || fatal "no working python interpreter found in ${CHECKOV_VENV_DIR}/bin"
    fi
    info "Using ${CHECKOV_PYTHON_BIN}"

    info 'Upgrading pip in isolated checkov virtual environment'
    "${CHECKOV_PYTHON_BIN}" -m pip install --upgrade pip
}

install_checkov() {
    if [[ -n "${CHECKOV_VERSION}" ]]; then
        info "Installing checkov==${CHECKOV_VERSION} via pip"
        "${CHECKOV_PYTHON_BIN}" -m pip install --upgrade "checkov==${CHECKOV_VERSION}"
    else
        info "Installing latest checkov via pip"
        "${CHECKOV_PYTHON_BIN}" -m pip install --upgrade checkov
    fi
}

install_wrapper() {
    mkdir -p "${BIN_DIR}"

    cat > "${BIN_DIR}/checkov" <<EOF
#!/usr/bin/env bash
set -e

CHECKOV_PYTHON_BIN="${CHECKOV_PYTHON_BIN}"
CHECKOV_EXECUTABLE="${CHECKOV_EXECUTABLE}"

if [[ ! -x "\${CHECKOV_EXECUTABLE}" ]]; then
    echo '[ERROR] checkov executable not found at '"\${CHECKOV_EXECUTABLE}" >&2
    exit 1
fi

# Use certifi CA bundle from the isolated environment if SSL_CERT_FILE is unset.
if [[ -z "\${SSL_CERT_FILE}" && -x "\${CHECKOV_PYTHON_BIN}" ]]; then
    CERT_PATH="\$("\${CHECKOV_PYTHON_BIN}" -c "import certifi; print(certifi.where())" 2>/dev/null || true)"
    if [[ -n "\${CERT_PATH}" ]]; then
        export SSL_CERT_FILE="\${CERT_PATH}"
    fi
fi

exec "\${CHECKOV_EXECUTABLE}" "\$@"
EOF

    chmod +x "${BIN_DIR}/checkov"
}

{
    get_bootstrap_python
    setup_checkov_venv
    install_checkov
    install_wrapper
    "${BIN_DIR}/checkov" --version >/dev/null 2>&1 || fatal 'checkov wrapper validation failed'
    info "Installed $("${BIN_DIR}/checkov" --version 2>/dev/null | head -n 1)"
}
