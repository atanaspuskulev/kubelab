# 05 — Installing Helm via APT with Ansible

**Target:** `k8s-control-1` (Ubuntu 24.04, Kubernetes v1.37.2)  
**Status:** User reported APT migration completed; exact APT package version and final Ansible recap not provided  
**Scope:** Helm CLI installation only; Cilium installation is a separate stage.

## 1. Objective and design decision

Install and maintain the Helm CLI through a dedicated APT repository, managed by Ansible. Helm is a client of the Kubernetes API; it does **not** need to be installed on every worker node.


| Decision                                          | Rationale                                                            |
|---------------------------------------------------|----------------------------------------------------------------------|
| Separate Helm role/playbook                       | Single responsibility and independent execution                      |
| Target `k8s_servers`                              | CLI is needed on the administration/control-plane VM, not every node |
| Dedicated signed APT source                       | APT manages package installation and updates                         |
| Verify signing-key fingerprint                    | Detect an unexpected downloaded key before trusting it               |
| Pin an exact Debian package version (recommended) | Prevent unplanned version drift                                      |
| Remove old `/usr/local/bin/helm`                  | Avoid PATH shadowing the APT-managed `/usr/bin/helm`                 |

## 2. Repository layout

```text
ansible/
├── playbooks/k8s/install-helm.yml
└── roles/helm/
    ├── defaults/main.yml
    └── tasks/
        ├── main.yml
        ├── repository.yml
        └── install.yml
```

### Playbook: `playbooks/k8s/install-helm.yml`

```yaml
---
- name: Install Helm CLI on Kubernetes control plane
  hosts: k8s_servers
  become: true
  gather_facts: true

  roles:
    - helm
```

### Defaults: `roles/helm/defaults/main.yml`

```yaml
---
helm_apt_repo_url: "https://packages.buildkite.com/helm-linux/helm-debian/any/"
helm_apt_gpg_key_url: "https://packages.buildkite.com/helm-linux/helm-debian/gpgkey"
helm_apt_key_fingerprint: "DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6"
helm_apt_key_path: "/etc/apt/keyrings/helm.asc"
helm_old_binary_path: "/usr/local/bin/helm"
```

The fingerprint is the expected value supplied by the Helm APT installation instructions used for this migration. Verify it against the current upstream instructions when refreshing the repository configuration.

## 3. Install Helm and retire the old executable

`roles/helm/tasks/install.yml`:


The role installs the repository's selected version. For strict reproducibility, inspect the available **Debian package version**, then replace `name: helm` with `name: "helm={{ helm_apt_version }}"` and define that variable in defaults/main vars. An "hold" operation defined to APT in order to prevent accidental upgrades of Helm.

### Role entry point: `roles/helm/tasks/main.yml`

```yaml
---
- name: Configure Helm repository
  ansible.builtin.import_tasks: repository.yml

- name: Install Helm package
  ansible.builtin.import_tasks: install.yml
```

## 5. Execute and validate

From `kubelab/ansible`:

```bash
ansible-playbook -i inventories/host/hosts.yml \
  playbooks/k8s/install-helm.yml --syntax-check

ansible-lint roles/helm/

ansible-playbook -i inventories/host/hosts.yml \
  playbooks/k8s/install-helm.yml -K
```

On `k8s-control-1`:

```bash
command -v helm
which -a helm
helm version
helm list -A
apt-cache policy helm
dpkg -l helm
ls -l /usr/local/bin/helm /usr/bin/helm 2>&1
```

**Expected:** `helm` resolves to `/usr/bin/helm`; `dpkg` lists Helm as installed; `/usr/local/bin/helm` no longer exists. An empty `helm list -A` is normal before deploying Cilium or other Helm releases.

Run the playbook a second time to test idempotency:

```bash
ansible-playbook -i inventories/host/hosts.yml \
  playbooks/k8s/install-helm.yml -K
```

**Expected:** `changed=0` if nothing has changed, including repository metadata and prerequisites. The exact second-run recap has not been provided and is therefore not recorded as verified.
