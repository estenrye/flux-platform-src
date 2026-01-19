#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get the executable path from zsh environment variables if running in zsh
if [ -n "$ZSH_NAME" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${(%):-%x}")" && pwd)"
fi

if [ ! -f "$SCRIPT_DIR/../.venv/bin/activate" ]; then
    python3 -m venv "$SCRIPT_DIR/../.venv"
    source "$HOME/.bashrc"
    source "$SCRIPT_DIR/../.venv/bin/activate"
    pip3 install --upgrade pip
    pip3 install -r "$SCRIPT_DIR/../requirements.txt"
    # ansible-galaxy install -r "$SCRIPT_DIR/../requirements.yml"
else
    source "$HOME/.bashrc"
    source "$SCRIPT_DIR/../.venv/bin/activate"
fi
