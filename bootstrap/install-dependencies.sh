#!/bin/bash

set -Eeuo pipefail

sudo apt update
sudo apt install -y \
    ansible \
    git \
    python3 \
    cloud-init

# Make sure, that Community General plugin is installed
# We need this, because of community.general.lvol
ansible-galaxy collection install community.general

# Needed by parsing the fstab, creating fs
ansible-galaxy collection install ansible.posix

# Request libvirt for Ansible
ansible-galaxy collection install community.libvirt

