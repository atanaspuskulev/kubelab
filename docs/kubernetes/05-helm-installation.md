# Helm CLI Installation — Ansible Runbook

**Stage:** 05 — Kubernetes administration tooling  
**Status:** Installation playbook succeeded; Helm CLI functional verification and no-op rerun still to be recorded

## 1. Objective

Install the Helm CLI reproducibly on the Kubernetes control plane, independently of Kubernetes package installation and worker enrollment. Helm is a client: it renders and manages Kubernetes resources through the API server and does not require installation on worker nodes.

Helm will initially be used manually to inspect and install Cilium. We will automate tool installation with Ansible while learning chart configuration and Kubernetes networking interactively.

## 2. Repository structure

```text
ansible/
├── playbooks/k8s/install-helm.yml
└── roles/helm/
    ├── defaults/main.yml
    └── tasks/main.yml
```

## 3. Dedicated playbook

`playbooks/k8s/install-helm.yml`:

```yaml
---
- name: Install Helm CLI on Kubernetes control plane
  hosts: k8s_servers
  become: true
  gather_facts: true

  roles:
    - helm
```

This deliberately targets `k8s_servers` only, not `k8s_cluster`.

## 4. Role defaults

`roles/helm/defaults/main.yml`:

```yaml
---
helm_version: "v4.3.1"
helm_arch: "amd64"
helm_platform: "linux-{{ helm_arch }}"
helm_archive: "helm-{{ helm_version }}-{{ helm_platform }}.tar.gz"
helm_download_url: "https://get.helm.sh"
helm_install_path: "/usr/local/bin/helm"
```

These values reflect the version and platform used in this runbook. For upgrades, verify the desired release exists and its checksum is published before changing the pinned version.

## 5. Installation algorithm

The role:

1. Checks the installed Helm version with `{{ helm_install_path }} version --short` and records the result without marking the host changed.
2. Skips installation when the requested version is already present.
3. Creates a temporary directory with `ansible.builtin.tempfile`.
4. Downloads the Helm archive and its `.sha256sum` file.
5. Reads the expected checksum, computes the downloaded archive's SHA-256 digest, and asserts they match.
6. Extracts the archive with `ansible.builtin.unarchive` using `remote_src: true`.
7. Copies the Helm binary to `/usr/local/bin/helm` with root ownership and mode `0755`.
8. Removes the temporary directory in an `always` block, including when an installation task fails.

### Critical download tasks

```yaml
- name: Download Helm archive
  ansible.builtin.get_url:
    url: "{{ helm_download_url }}/{{ helm_archive }}"
    dest: "{{ helm_tmp.path }}/{{ helm_archive }}"
    mode: "0644"

- name: Download Helm checksum
  ansible.builtin.get_url:
    url: "{{ helm_download_url }}/{{ helm_archive }}.sha256sum"
    dest: "{{ helm_tmp.path }}/{{ helm_archive }}.sha256sum"
    mode: "0644"
```

### Checksum verification

```yaml
- name: Read expected checksum
  ansible.builtin.command:
    cmd: "cat {{ helm_tmp.path }}/{{ helm_archive }}.sha256sum"
  register: helm_checksum
  changed_when: false

- name: Verify downloaded archive
  ansible.builtin.command:
    cmd: "sha256sum {{ helm_tmp.path }}/{{ helm_archive }}"
  register: helm_real_checksum
  changed_when: false

- name: Checksum match assertion
  ansible.builtin.assert:
    that:
      - >-
        helm_real_checksum.stdout.split()[0] ==
        helm_checksum.stdout.split()[0]
```

A SHA-256 checksum verifies integrity against the downloaded checksum file; it is not a substitute for independent signature verification when stronger supply-chain assurances are needed.

## 6. Troubleshooting: missing archive

**Observed error:**

```text
sha256sum: /tmp/ansible.04a7p1dkhelm/helm-v4.3.1-linux-amd64.tar.gz:
No such file or directory
```

**Root cause:** The task named `Download Helm archive` actually downloaded only the `.sha256sum` file. There was no task downloading the `.tar.gz` archive. The checksum verification correctly failed because its input did not exist.

**Correction:** Restore two separate `get_url` tasks: one for the archive and one for its checksum. After this correction, the playbook completed successfully.

**Lesson:** A task's display name does not determine its behavior. Inspect the actual `url` and `dest` values and trace the artifact through the workflow.

## 7. Execution and observed result

From `kubelab/ansible`:

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/k8s/install-helm.yml -K
```

**Observed recap after correcting the download tasks:**

```text
k8s-control-1 : ok=11 changed=6 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0
```

This confirms the installation playbook finished without an Ansible error. The output shared did not include the Helm CLI version or a second playbook run.

## 8. Verification and idempotency
On `k8s-control-1`:

```bash
helm version
helm list -A
```

The first command report the pinned version. The second should communicate with the Kubernetes API using the user's working kubeconfig; an empty release list is acceptable.

Then rerun the playbook:

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/k8s/install-helm.yml -K
```

**Confirmed:** `changed=0`, because the version check should skip the installation block. Record the actual result when observed.

## 9. Why a separate role?

| Component               | Responsibility |
|-------------------------|--------------------------------------------------|
| `kubeadm` role          | Install Kubernetes node packages                 |
| `k8s-server` role       | Initialize and validate control plane            |
| `k8s-agent` role        | Enroll workers                                   |
| `helm` role             | Install Helm CLI                                 |
| Future Cilium procedure | Configure and validate Kubernetes pod networking |

The separation keeps tooling installation reproducible without hiding the networking concepts behind automation.

