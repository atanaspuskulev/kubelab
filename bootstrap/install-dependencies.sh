#!/bin/bash

set -Eeuo pipefail

sudo apt update
sudo apt install -y \
    ansible \
    git \
    python3
