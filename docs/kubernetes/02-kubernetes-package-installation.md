# Kubernetes Package Installation — Ansible Runbook

**Project:** `kubelab`  
**Environment:** Ubuntu 24.04 virtual machines on KVM/libvirt
**Recorded:** 18 November 2026
**Status:** `kubeadm` verified as **v1.37.2** on all three VMs; control-plane initialization not yet performed.

## 1. Purpose and scope

This runbook records installation of Kubernetes node packages (`kubeadm`, `kubelet`, `kubectl`) using Ansible, plus the repository-signing and APT-index failures encountered during rollout. It describes the **package-installation milestone**, not a functioning Kubernetes cluster.

## 2. Environment

| Node            | Address      | Role                 |
|-----------------|--------------|----------------------|
| `k8s-control-1` | `10.20.0.10` | Future control plane |
| `k8s-worker-1`  | `10.20.0.11` | Future worker        |
| `k8s-worker-2`  | `10.20.0.12` | Future worker        |

All three nodes are Ubuntu 24.04 guests provisioned on the `kubelab` KVM/libvirt host. Their libvirt network is `k8s-lab` (`10.20.0.0/24`). Earlier Ansible preparation configured operating-system prerequisites and containerd.

The Ansible inventory group `k8s_cluster` targets the three **guest VMs**, not the hypervisor. The Kubernetes minor version is supplied through `inventories/host/group_vars/k8s_cluster.yml`:

```yaml
kubernetes_version: "v1.37"
```

> The version selects the Kubernetes package repository. The observed installed `kubeadm` patch version was `v1.37.2`.

## 3. Repository layout

```text
ansible/
├── inventories/host/
│   ├── hosts.yml
│   └── group_vars/k8s_cluster.yml
├── playbooks/
│   └── k8s/
│       └── kubernetes-install.yml
└── roles/
    └── kubeadm/
        └── tasks/
            ├── main.yml
            ├── repository.yml
            └── install.yml
```

The role's `main.yml` imports the repository setup and package installation tasks. During troubleshooting, an explicit APT-index refresh was added **between** those imports:

```yaml
---
- name: Configure Kubernetes APT repository
  ansible.builtin.import_tasks: repository.yml

- name: Refresh APT package indexes
  ansible.builtin.apt:
    update_cache: true
    cache_valid_time: 0

- name: Install Kubernetes
  ansible.builtin.import_tasks: install.yml
```

`import_tasks` expands these task files in a fixed order. The playbook must target `hosts: k8s_cluster` and run privileged tasks with `become: true`.

## 4. Repository configuration

`repository.yml` is responsible for:

1. Installing repository prerequisites (`ca-certificates`, `curl`, `gpg`; `apt-transport-https` was also included in the working iteration - directly from the Kubernetes documentation).
2. Ensuring `/etc/apt/keyrings` exists.
3. Downloading the Kubernetes repository `Release.key`.
4. Checking whether the dearmored keyring exists.
5. Creating or updating the keyring if the downloaded key changed or the keyring is absent.
6. Configuring the version-specific APT repository.


**Important:** APT will fail if `signed-by` points to a missing keyring. The `stat` check prevents a common partial-configuration failure where the downloaded key exists but the converted `.gpg` file does not.

## 5. Package installation

`install.yml` installs the node binaries, marks them held for deliberate upgrades, and enables the kubelet service:

Enabling kubelet does **not** mean a Kubernetes cluster has been initialized. Kubelet may not be healthy until kubeadm bootstrap provides its configuration.

## 6. Execution and validation

From the `ansible/` directory:

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/kubernetes-install.yml \
  --list-tasks

ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/kubernetes-install.yml -K
```

The `--list-tasks` check confirmed the repository tasks execute before the package-installation tasks. It is a **parse/ordering check**, not proof that installation succeeds.

To verify installed kubeadm versions:

```bash
ansible k8s_cluster \
  -i inventories/host/hosts.yml \
  -a "kubeadm version -o short"
```

**Observed output:**

```text
k8s-worker-2  | rc=0 >> v1.37.2
k8s-control-1 | rc=0 >> v1.37.2
k8s-worker-1  | rc=0 >> v1.37.2
```

Ansible ad-hoc commands may display `CHANGED` even for read-only shell/command invocations; this is not evidence of a package modification.

Additional checks to perform and record:

```bash
ansible k8s_cluster -i inventories/host/hosts.yml \
  -b -a "systemctl is-enabled kubelet"

ansible k8s_cluster -i inventories/host/hosts.yml \
  -a "kubectl version --client"

ansible k8s_cluster -i inventories/host/hosts.yml \
  -a "apt-cache policy kubeadm"
```

## 7. Incident A — Kubernetes repository rejected: `NO_PUBKEY`

**Symptom:** The repository task failed during an APT cache update:

```text
NO_PUBKEY 234654DA9A296436
The repository 'https://pkgs.k8s.io/core:/stable:/v1.37/deb InRelease' is not signed.
```

**Diagnostics on `k8s-control-1`:**

```bash
sudo ls -lh /etc/apt/keyrings/kubernetes*
gpg --show-keys --with-fingerprint \
  /etc/apt/keyrings/kubernetes-release.key
gpg --show-keys --with-fingerprint \
  /etc/apt/keyrings/kubernetes-apt-keyring.gpg
```

**Observed:**

- `/etc/apt/keyrings/kubernetes-release.key` existed.
- Its fingerprint was `DE15 B144 86CD 377B 9E87 6E1A 2346 54DA 9A29 6436`, matching APT's missing key ID.
- `/etc/apt/keyrings/kubernetes-apt-keyring.gpg` **did not exist**.

**Root cause:** The repository referenced a converted keyring that had not been created. A conversion task guarded only by `when: kubernetes_release_key.changed` could skip conversion on reruns if the source key already existed.

**Fix:** Add `stat` for the output keyring and run `gpg --dearmor` when the source key changes **or** the output file is missing. Confirm correct option spelling (`--dearmor`) and YAML indentation of `apt_repository` parameters.

**Recovery wrinkle:** A partially configured repository was already present, so the **first** prerequisite-installation task also failed when it ran `update_cache: true`, before the keyring could be repaired. The recovery iteration disabled that early refresh, repaired the keyring, and refreshed APT after repository setup. For a durable role, plan repository bootstrap and recovery so an existing broken source does not block key repair.

**Security note:** Do not disable signature checking or use `trusted=yes` to work around a missing key.

## 8. Incident B — `No package matching 'kubeadm' is available`

**Symptom:** All nodes initially failed to install `kubeadm`; later, the control-plane node succeeded but both workers still failed:

```text
No package matching 'kubeadm' is available
```

**Diagnostics:** On `k8s-control-1`, manually running:

```bash
sudo apt update
apt-cache search kubeadm
```

successfully fetched the Kubernetes `v1.37` package index, and `apt-cache search` returned:

```text
kubeadm - Command-line utility for administering a Kubernetes cluster
```

**Root cause:** APT did not yet have the Kubernetes package index on the failing nodes. Configuring a repository does not guarantee its package list is refreshed on every subsequent run. `apt_repository` may only update the cache when the source changes; cache-age settings can also suppress an otherwise desired refresh.

**Correction that succeeded:** Add an explicit `ansible.builtin.apt` cache-refresh task **after** repository setup and **before** `install.yml`, with `update_cache: true` and `cache_valid_time: 0`.

**Observed outcome:** The control-plane install task returned `ok`, both worker install tasks returned `changed`, and package holds were applied to the workers. Subsequent `kubeadm version -o short` returned `v1.37.2` on all three nodes.

## 9. Engineering takeaways

- **Idempotency must cover dependent artifacts.** A source key being unchanged does not prove its generated keyring exists.
- **Ordering matters.** Repair a broken signed repository before invoking an APT cache refresh that reads it.
- **Partial failures matter.** Reruns operate against the state left by previous attempts, not always a clean VM.
- **APT source configuration and APT package indexes are distinct.** Refresh indexes explicitly after introducing the source.
- **Validate at each layer.** Check key fingerprint, keyring existence, APT update, package discovery, installed binaries, and kubelet enablement separately.
- **Use controlled upgrades.** Held Kubernetes packages should be upgraded intentionally and with version compatibility in mind.

## 10. Post-install configuration

- Define kubeadm control-plane configuration and confirm API endpoint (`10.20.0.10:6443`) and Pod CIDR with the chosen CNI. This is done in inventories/host/group_vars/k8s_cluster.yml:

```text
---
kubernetes_version: "v1.37"
kubernetes_api_endpoint: "10.20.0.10"
kubernetes_api_port: 6443
kubernetes_pod_cidr: "10.244.0.0/16"
```

