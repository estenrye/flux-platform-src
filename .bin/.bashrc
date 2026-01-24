#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get the executable path from zsh environment variables if running in zsh
if [ -n "$ZSH_NAME" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
fi

if [ ! -f "$SCRIPT_DIR/../.venv/bin/activate" ]; then
    python3 -m venv --without-scm-ignore-files "$SCRIPT_DIR/../.venv"
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
    fi
    source "$SCRIPT_DIR/../.venv/bin/activate"
    pip3 install --upgrade pip
    pip3 install -r "$SCRIPT_DIR/requirements.txt"
    # ansible-galaxy install -r "$SCRIPT_DIR/../requirements.yml"
else
    if [ -f "$HOME/.bashrc" ]; then
        source "$HOME/.bashrc"
    fi
    source "$SCRIPT_DIR/../.venv/bin/activate"
    pip3 install --upgrade pip
    pip3 install -r "$SCRIPT_DIR/requirements.txt"
fi

# Install jq if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/jq" ]; then
    bash "$SCRIPT_DIR/install-jq.sh"
fi

# Install flux CLI if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/flux" ]; then
    bash "$SCRIPT_DIR/install-flux.sh"
fi

# Install age if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/age" ]; then
    bash "$SCRIPT_DIR/install-age.sh"
fi

# Install sops if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/sops" ]; then
    bash "$SCRIPT_DIR/install-sops.sh"
fi

# Install yq if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/yq" ]; then
    bash "$SCRIPT_DIR/install-yq.sh"
fi

# Install kustomize if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/kustomize" ]; then
    bash "$SCRIPT_DIR/install-kustomize.sh"
fi

# Install kubectl if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/kubectl" ]; then
    bash "$SCRIPT_DIR/install-kubectl.sh"
fi

# Install gh if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/gh" ]; then
    bash "$SCRIPT_DIR/install-gh.sh"
fi

# Install chainsaw if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/chainsaw" ]; then
    bash "$SCRIPT_DIR/install-chainsaw.sh"
fi

# Install saml2aws if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/saml2aws" ]; then
    bash "$SCRIPT_DIR/install-saml2aws.sh"
fi

# Install spotctl if not already installed
if [ ! -f "$SCRIPT_DIR/../.venv/bin/spotctl" ]; then
    bash "$SCRIPT_DIR/install-spotctl.sh"
fi