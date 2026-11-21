# Kubernetes Control-Plane Initialization — Ansible Runbook

**Project:** `kubelab`  
**Environment:** Ubuntu 24.04 virtual machines on KVM/libvirt  
**Recorded:** 18–21 November 2026  
**Status:** Control plane operational and validated; both workers inspected and awaiting enrollment. CNI not yet deployed.

## 1. Purpose and scope

This runbook records initialization of an upstream Kubernetes control plane using kubeadm and Ansible, recovery from incomplete initialization, and verification of idempotent configuration against the recovered cluster. It follows `02-kubernetes-package-installation.md`.

Worker enrollment and CNI deployment are separate milestones. An operational API server does not yet imply a fully functional workload environment.

## 2. Environment

| Node            | Address      | Role          |
|-----------------|--------------|---------------|
| `k8s-control-1` | `10.20.0.10` | Control plane |
| `k8s-worker-1`  | `10.20.0.11` | Future worker |
| `k8s-worker-2`  | `10.20.0.12` | Future worker |

- Hypervisor: `kubelab`, KVM/libvirt.
- Virtual network: `k8s-lab` (`10.20.0.0/24`).
- Kubernetes: `v1.37.2`.
- Container runtime: containerd, CRI endpoint `unix:///run/containerd/containerd.sock`.
- API endpoint: `10.20.0.10:6443`.
- Pod CIDR: `10.244.0.0/16`.
- Local stacked etcd; single control plane, not a highly available cluster.

## 3. Repository layout and execution scope

```text
ansible/
├── inventories/host/
│   ├── hosts.yml
│   └── group_vars/k8s_cluster.yml
├── playbooks/k8s/
│   └── kubernetes-config.yml
└── roles/k8s-server/
    ├── tasks/
    │   ├── main.yml
    │   ├── configure.yml
    │   ├── initialize.yml
    │   ├── recover-admin-rbac.yml
    │   ├── postinstall-checks.yml
    │   ├── postinstall.yml
    │   └── validate.yml
    └── templates/
        └── kubeadm-config.yaml.j2
```

The control-plane playbook targets `k8s_servers`, not `k8s_cluster`:

```yaml
---
- name: Configure Kubernetes control plane
  hosts: k8s_servers
  become: true
  gather_facts: true
  roles:
    - k8s-server
```

The role separates configuration, initialization, exceptional RBAC recovery, post-installation detection, conditional remediation and final validation. The task order is significant: administrative access must work before ordinary API resource checks can succeed.

## 4. Declarative kubeadm configuration

Relevant group variables:

```yaml
kubernetes_version: "v1.37"
kubernetes_release: "v1.37.2"
kubernetes_api_endpoint: "10.20.0.10"
kubernetes_api_port: 6443
kubernetes_pod_cidr: "10.244.0.0/16"
kube_admin_config: /etc/kubernetes/admin.conf
kube_kubeadm_config: /etc/kubernetes/kubeadm-config.yml
kube_kubelet_config: /etc/kubernetes/kubelet.conf
kube_kubelet_client_cert: /var/lib/kubelet/pki/kubelet-client-current.pem
kube_manifests_dir: /etc/kubernetes/manifests
kube_etcd_data_dir: /var/lib/etcd
```


The template renders two kubeadm configuration documents:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "{{ kubernetes_api_endpoint }}"
  bindPort: {{ kubernetes_api_port }}
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "{{ kubernetes_release }}"
controlPlaneEndpoint: "{{ kubernetes_api_endpoint }}:{{ kubernetes_api_port }}"
networking:
  podSubnet: "{{ kubernetes_pod_cidr }}"
```

Initialization uses `kubeadm init --config /etc/kubernetes/kubeadm-config.yml`. The Pod CIDR must be compatible with the eventual CNI configuration.

## 5. Incident A — Incorrect playbook scope and incomplete initialization

**Symptoms:** The original initialization attempt targeted all three guests. Worker attempts reported conflicts involving etcd ports 2379 and 2380. The intended control plane was left with local configuration and running static pods but missing or incomplete post-bootstrap resources.

**Confirmed findings:**

- The playbook scope was too broad and was corrected to `k8s_servers`.
- `/etc/kubernetes/admin.conf` existed, causing the original initialization guard to skip subsequent attempts.
- The API server and etcd were operational, despite incomplete later initialization phases.
- Administrative RBAC, cluster configuration resources, add-ons and kubelet certificate finalization required inspection or recovery.

**Root cause boundary:** Incorrect targeting and inadequate completion detection are confirmed automation defects. The exact cause of the original control-plane initialization failure and the source of the historical worker port conflicts were not conclusively established.

**Correction:** Recover the existing control plane using individual kubeadm phases instead of resetting it or rerunning initialization blindly.

## 6. Diagnostics and incremental recovery

Run privileged commands on `k8s-control-1`. For ordinary API inspection:

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw='/readyz?verbose'
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system -o wide
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get configmaps -n kube-system
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get clusterrolebindings
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get roles,rolebindings -n kube-system
```

Local inspection:

```bash
sudo ls -la /etc/kubernetes/ /etc/kubernetes/manifests/ /etc/kubernetes/pki/
sudo ls -la /var/lib/etcd/member
sudo ss -lntp | grep -E ':(2379|2380|6443|10250|10257|10259)\b'
```

### 6.1. Administrative RBAC

The expected binding `kubeadm:cluster-admins` connects the kubeadm administrative group to the `cluster-admin` ClusterRole. During recovery, `super-admin.conf` was used for exceptional access to inspect and restore administrative RBAC.

A misspelled binding, `kubeadm:cluster-admiins`, was also observed. Its removal was not recorded. Inspect its role reference and subjects before removing any redundant binding. Routine automation must use `admin.conf`, not the break-glass kubeconfig.

### 6.2. Individual initialization phases

The following phases were used during recovery, after inspecting the corresponding resources. These commands are reference material, not a script to run unconditionally:

```bash
sudo kubeadm init phase upload-config kubeadm --config /etc/kubernetes/kubeadm-config.yml
sudo kubeadm init phase upload-config kubelet --config /etc/kubernetes/kubeadm-config.yml
sudo kubeadm init phase bootstrap-token --config /etc/kubernetes/kubeadm-config.yml
sudo kubeadm init phase mark-control-plane --config /etc/kubernetes/kubeadm-config.yml
sudo kubeadm init phase addon coredns --config /etc/kubernetes/kubeadm-config.yml
sudo kubeadm init phase addon kube-proxy --config /etc/kubernetes/kubeadm-config.yml
```

| Resource                                   | Purpose                                                            |
|--------------------------------------------|--------------------------------------------------------------------|
| `kube-system/kubeadm-config`               | Cluster-level kubeadm configuration                                |
| `kube-system/kubelet-config`               | Shared kubelet configuration                                       |
| `kube-public/cluster-info`                 | Bootstrap discovery information                                    |
| Bootstrap RBAC                             | Node discovery, TLS bootstrap and certificate rotation permissions |
| Control-plane label and `NoSchedule` taint | Node role and default workload placement                           |
| CoreDNS Deployment                         | Cluster DNS                                                        |
| kube-proxy DaemonSet                       | Service networking                                                 |

An expired or absent bootstrap token is not by itself evidence of an unhealthy control plane. Generate enrollment credentials only when required.

## 7. Incident B — Missing kubelet configuration and incorrect RBAC detection

**Symptom:** The `kubelet-config` ConfigMap was missing during the initial resource audit. After recovery, validation still reported a missing RoleBinding named `kubeadm:nodes-kubelet-config`.

**Diagnostics:**

```bash
sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf \
  get roles,rolebindings -n kube-system | grep kubelet
```

**Observed:** Both the Role and RoleBinding existed under the name `kubeadm:kubelet-config`.

**Correction:** The kubelet upload phase restored configuration resources. Both the detection and validation tasks were corrected to query `kubeadm:kubelet-config`, rather than the incorrect assumed name.

The absence check uses `kubectl get ... --ignore-not-found -o name`, with `changed_when: false`. An empty successful output indicates absence; other API errors should remain failures. A strict validation query intentionally omits `--ignore-not-found`.

This distinction prevents a nonexistent resource name from triggering unnecessary recovery on every run.

## 8. Incident C — Incomplete kubelet client certificate finalization

**Symptom:** `/etc/kubernetes/kubelet.conf` contained embedded `client-certificate-data` and `client-key-data`, rather than references to the rotating kubelet client PEM file.

**Diagnostics:**

```bash
sudo grep -E '^[[:space:]]*client-(certificate|key)(-data)?:' \
  /etc/kubernetes/kubelet.conf | cut -d ':' -f 1
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem \
  -noout -subject -dates
```

The rotating certificate existed and identified `system:node:k8s-control-1` in organization `system:nodes`. Its dates were inspected. This check alone does not verify private-key matching or successful API authentication.

**Correction:** After verifying the target file exists, recover certificate finalization conditionally:

```bash
sudo kubeadm init phase kubelet-finalize enable-client-cert-rotation \
  --config /etc/kubernetes/kubeadm-config.yml
```

The Ansible check uses `stat` with `follow: true` for the rotating certificate symlink. Both `stat.exists` and `stat.isreg` are asserted before recovery.

Validation independently reads the `client-certificate` and `client-key` references using `kubectl config view --minify` and JSONPath. Both must equal `kube_kubelet_client_cert`.

Recovery uses inequality (`!=`); validation uses equality (`==`). Do not print embedded private-key material into logs or documentation.

## 9. Safe initialization-state detection

The original implementation used `admin.conf` as both a `stat` guard and a command `creates` condition. This cannot distinguish a complete initialization from one that stopped after kubeconfig generation.

The improved `initialize.yml` inspects:

1. The administrative kubeconfig (`stat.exists`).
2. Existing files in the static manifest directory (`find.matched`).
3. Local etcd member data (`/var/lib/etcd/member`).
4. API readiness through `/readyz`, with a bounded request timeout.

| State                     | Detection                                                       | Action                                  |
|---------------------------|---------------------------------------------------------------- |---------------------------------------- |
| `uninitialized`           | No admin kubeconfig, no detected manifests, no etcd member data | Run kubeadm init                        |
| `operational`             | Admin kubeconfig exists and API readiness succeeds              | Skip init; run post-installation checks |
| `incomplete_or_unhealthy` | Other detected combinations                                     | Fail explicitly; investigate manually   |

The API probe deliberately uses `failed_when: false` to classify the result, not to conceal failure. The subsequent state guard stops on an unhealthy existing cluster. `creates` remains a secondary guard. No automatic reset is performed.

**Discovered edge case:** The installed packages provide a `.kubelet-keep` placeholder in the manifests directory. Exclude it from the artifact count:

```yaml
- name: Check existing static pod manifests
  ansible.builtin.find:
    paths: "{{ kube_manifests_dir }}"
    file_type: file
    hidden: true
    recurse: false
    excludes:
      - ".kubelet-keep"
  register: kubernetes_static_manifests
```

This exclusion was identified after the successful state-detection run; its application and fresh-node behavior still need verification. The classifier is a conservative heuristic, not exhaustive proof of clean state. Fresh initialization, inaccessible manifest directories and unhealthy-state branches need testing on disposable VMs. Administrative authentication failures also require explicit diagnosis because the readiness gate precedes exceptional RBAC recovery.

## 10. Execution and validation

From `ansible/`:

```bash
ansible-playbook -i inventories/host/hosts.yml \
  playbooks/k8s/kubernetes-config.yml -K
```

**Observed after recovery and validation:**

```text
k8s-control-1 : ok=30 changed=0 unreachable=0 failed=0 skipped=9 rescued=0 ignored=0
```

**Observed after improved state detection:**

```text
k8s-control-1 : ok=35 changed=0 unreachable=0 failed=0 skipped=11 rescued=0 ignored=0
```

These results demonstrate an unchanged successful rerun against the recovered control plane, not yet a tested fresh-install or failure-recovery matrix.

The control-plane audit showed all four static pods running (etcd, kube-apiserver, kube-controller-manager, kube-scheduler), a successful API readiness check, kube-proxy running, CoreDNS Pending and the node NotReady before CNI installation.

The final inspection confirmed the expected kubeconfigs, PKI files, manifests, persistent etcd member data and listening ports.

## 11. CRI troubleshooting tools

On `k8s-worker-1`, `crictl` was initially absent despite installed, held Kubernetes packages at `1.37.2-1.1`. `apt-cache depends kubeadm` listed no dependencies, and `apt-cache policy` showed `cri-tools` candidate `1.37.0-1.1` and installed `kubernetes-cni` version `1.9.1-1.1`.

`crictl` subsequently worked on the worker, including with the default endpoint configuration. The precise installation task was not supplied for this record. Manage it explicitly through the common package role, with a separate version variable and a consistent runtime endpoint; verify the implementation on every node.

Suggested `/etc/crictl.yaml`:

```yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
```

Useful diagnostics:

```bash
sudo crictl info
sudo crictl ps -a
sudo crictl pods
sudo ctr -n k8s.io containers list
sudo ctr -n k8s.io tasks list
```

`crictl` communicates via CRI; `ctr` uses containerd's native API. Installed CNI binaries are not equivalent to a deployed cluster pod network.

## 12. Worker inspection before enrollment

Both workers were inspected because the original initialization targeted all guests.

```bash
hostname
sudo ls -la /etc/kubernetes/ /etc/kubernetes/manifests/
sudo ls -la /etc/kubernetes/pki/ /var/lib/etcd/ /var/lib/kubelet/
sudo ss -lntp | grep -E ':(2379|2380|6443|10250|10257|10259)\b'
sudo crictl ps -a
sudo crictl pods
sudo systemctl status kubelet --no-pager
```

**Observed on worker 1; worker 2 reported equivalent:**

- No admin or kubelet kubeconfig, PKI directory or etcd data.
- No control-plane static manifests; only `.kubelet-keep`.
- No relevant listening Kubernetes ports.
- Empty CRI container and pod-sandbox listings.
- Kubelet enabled but inactive; its data directory contained only the placeholder.
- A rendered `kubeadm-config.yml` remained from the accidental targeting, but was not evidence of bootstrap.

**Decision:** No destructive reset is warranted by the observed state. Validate API connectivity and enrollment state before joining. Kubelet inactivity is acceptable before enrollment.

## 13. Engineering takeaways

- Separate control-plane and worker inventory scopes.
- File existence is not proof of successful service initialization.
- Inspect before remediation; preserve functioning cluster state.
- Recover individual missing phases rather than repeat a destructive bootstrap.
- Distinguish resource absence from API failures and verify actual RBAC names.
- Keep privileged recovery credentials separate from routine administration.
- Validate certificate rotation references without exposing credentials.
- Treat package placeholders as baseline state, not bootstrap artifacts.
- Distinguish idempotency evidence from fresh-install and failure-path coverage.
- Use `ansible-doc`, syntax checks and linting to reduce module parameter and expression errors; runtime validation remains necessary.

