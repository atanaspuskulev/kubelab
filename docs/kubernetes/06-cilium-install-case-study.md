# Cilium CNI deployment on a three-node Kubernetes homelab

**Status:** Deployed; node readiness, cross-node ICMP and VXLAN encapsulation verified  
**Environment:** Local KVM/libvirt virtual machines, Ubuntu 24.04.5 LTS, Kubernetes v1.37.2 (kubeadm), containerd 2.2.1

> This is a record of observed results and troubleshooting, not a claim of production readiness. Cilium `1.21.0-pre.4` is a prerelease.

## 1. Objective

Install a Kubernetes Container Network Interface (CNI) on a three-node kubeadm cluster using a repeatable Ansible role and Helm chart, then verify node readiness and cross-node pod networking. Use packet captures to understand how an overlay network transports pod traffic over the libvirt underlay.

## 2. Environment and topology

| Node            | Role          | Underlay IP  | Observed PodCIDR |
|-----------------|---------------|--------------|-----------------|
| `k8s-control-1` | Control plane | `10.20.0.10` | `10.244.0.0/24` |
| `k8s-worker-1`  | Worker        | `10.20.0.11` | `10.244.2.0/24` |
| `k8s-worker-2`  | Worker        | `10.20.0.12` | `10.244.1.0/24` |

- **Underlay:** libvirt NAT network `10.20.0.0/24`.
- **Overlay:** Kubernetes pod addressing within `10.244.0.0/16`.
- **API server:** `10.20.0.10:6443`.
- **Kubernetes:** `v1.37.2`, bootstrapped using kubeadm (not k3s).
- **Node OS:** Ubuntu 24.04.5 LTS, kernel `6.8.0-147-generic`.
- **Container runtime:** `containerd://2.2.1`.
- **Host firewall:** UFW inactive on all three nodes during the work.
- **Cilium:** Helm chart/app version `1.21.0-pre.4`.
- **Helm:** `4.3.0-1`, installed from the official Helm APT repository on the control plane.
- **Ansible:** executed from a Toolbox container against inventory group `k8s_cluster`.

Before Cilium was installed, nodes were `NotReady` and `/etc/cni/net.d/` had no working CNI configuration (only a `.kubernetes-cni-keep` placeholder).

## 3. Design decisions

1. **Ansible** provisions/configures the local homelab; **Helm** manages the Cilium Kubernetes release. Terraform is reserved for the later AWS infrastructure stage.
2. Use **Cilium with VXLAN tunneling** to connect pods across the libvirt node network.
3. Keep **kube-proxy enabled** initially; do not introduce kube-proxy replacement while establishing baseline connectivity.
4. Use **Kubernetes IPAM** so pod IP allocation aligns with node-assigned PodCIDRs.
5. Explicitly point Cilium at the API server because the CNI must reach it during bootstrap.
6. Use **Cilium `1.21.0-pre.4` experimentally** because the chosen Kubernetes `1.37` version was outside the compatibility range consulted for Cilium `1.20.5`. The prerelease choice is a lab tradeoff, not a production recommendation or a guarantee of complete compatibility.

## 4. Repository layout and role configuration

Relevant paths in the Ansible repository:

```text
ansible/
├── inventories/host/hosts.yml
├── playbooks/k8s/install-cilium.yml
└── roles/cilium/
    ├── defaults/main.yml
    ├── tasks/
    │   ├── main.yml
    │   ├── preflight.yml
    │   ├── repository.yml
    │   └── install.yml
    └── templates/values.yaml.j2
```

The role runs on the control-plane host with privilege escalation. Its main task block supplies the kubeconfig environment:

```yaml
environment:
  KUBECONFIG: "{{ kube_admin_config }}"
```

`kube_admin_config` refers to `/etc/kubernetes/admin.conf`. This is important because `become: true` changes the effective user and therefore the Helm/Kubernetes client configuration context.

Representative role defaults from the working setup:

```yaml
cilium_release_name: cilium
cilium_namespace: kube-system
cilium_chart_version: "1.21.0-pre.4"
cilium_values_path: /tmp/cilium-values.yaml
kube_admin_config: /etc/kubernetes/admin.conf
```

The role preflight reads `kubectl version -o json`, extracts the API server's major/minor version, and asserts it is in the role's configured allowed list. The allowed list was adjusted to include `1.37` for this experimental installation. **An assertion passing means the role permits that version; it is not proof of upstream compatibility.**

### Helm values

Rendered from `roles/cilium/templates/values.yaml.j2` to `/tmp/cilium-values.yaml`:

```yaml
---
k8sServiceHost: "10.20.0.10"
k8sServicePort: 6443
kubeProxyReplacement: "false"
ipam:
  mode: "kubernetes"
routingMode: "tunnel"
tunnelProtocol: "vxlan"
```

The Helm render was checked before installation:

```bash
helm template cilium cilium/cilium \
  --version 1.21.0-pre.4 \
  --namespace kube-system \
  -f /tmp/cilium-values.yaml > /tmp/cilium-rendered.yaml
```

The generated Cilium ConfigMap included the expected `routing-mode`, `tunnel-protocol`, `kube-proxy-replacement`, and `ipam` settings. A `helm show crds` command produced no CRDs in that inspection; **that result alone did not establish whether Cilium CRDs would be installed**. Their existence was subsequently confirmed against the Kubernetes API.

### Helm repository and release tasks

The repository is configured for the **same effective user** that runs the Helm module:

```yaml
- name: Configure Cilium Helm repository
  kubernetes.core.helm_repository:
    name: cilium
    repo_url: https://helm.cilium.io/
```

The installation task:

```yaml
- name: Install or upgrade Cilium
  kubernetes.core.helm:
    name: "{{ cilium_release_name }}"
    chart_ref: cilium/cilium
    chart_version: "{{ cilium_chart_version }}"
    release_namespace: "{{ cilium_namespace }}"
    kubeconfig: "{{ kube_admin_config }}"
    values_files:
      - "{{ cilium_values_path }}"
    state: present
    wait: false
    timeout: 10m
```

`wait: false` means this task's success does **not** prove pods became healthy; health checks must follow separately.

## 5. Troubleshooting timeline

### Failure A — Helm used `localhost:8080` rather than the Kubernetes API

**Symptom:** Ansible's Helm invocation could not reach the Kubernetes API and attempted the default local endpoint `localhost:8080`.

**Cause:** Helm was invoked through Ansible with `become: true`, so the effective user was root, not the interactive `ubuntu` user. Root did not automatically inherit the interactive user's kubeconfig.

**Fix:** Provide `/etc/kubernetes/admin.conf` explicitly using both the role block's `KUBECONFIG` environment and the Helm module's `kubeconfig` parameter.

**Lesson:** Verify the **effective user, environment variables, and kubeconfig** when an automation command behaves differently from the same command in an interactive shell.

### Failure B — Helm repository was not configured for root

**Symptom:** The Cilium chart reference was unavailable to the Helm invocation made by Ansible, despite Helm working in the interactive user's context.

**Cause:** Helm repository configuration is user-scoped; `ubuntu` and root can have different repository lists/configuration.

**Fix:** Add a dedicated `repository.yml` task using `kubernetes.core.helm_repository` under the same privilege context as the installation. On subsequent runs the repository task reported `ok`.

**Lesson:** Treat user-specific CLI configuration as part of automated provisioning, not an implicit prerequisite.

### Failure C — Ansible Helm module invoked a removed Helm 4 flag

**Symptom:** With the Debian-packaged `kubernetes.core 6.2.0` collection, the module failed while inspecting releases:

```text
command: ["/usr/sbin/helm", "list", "--output=yaml", "--filter", "cilium", "--all"]
stderr: Error: unknown flag: --all
```

**Cause:** That installed collection version invoked a `helm list --all` option unsupported by the installed Helm 4 CLI. The error occurred in the module's release-inspection step, not in Cilium itself.

**Fix:** Upgrade the Ansible collection inside the Toolbox environment:

```bash
ansible-galaxy collection list kubernetes.core
# Initially: kubernetes.core 6.2.0

ansible-galaxy collection install kubernetes.core --upgrade
# Installed: kubernetes.core 6.6.0
```

The new version was installed in the user's collection directory:

```text
/home/USER/.ansible/collections/ansible_collections/kubernetes/core
```

The system-provided `6.2.0` collection remained under `/usr/lib/python3/dist-packages/ansible_collections`. The successful run is consistent with Ansible loading the newer user-installed collection. For reproducibility, **pin the tested collection version in `requirements.yml` and verify collection resolution** rather than relying on a global upgrade.

**Rerun:**

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/k8s/install-cilium.yml \
  -K
```

Observed recap:

```text
k8s-control-1 : ok=6 changed=0 unreachable=0 failed=0 skipped=0
```

The Helm task reported `ok` with two warnings:

```text
The default idempotency check can fail to report changes in certain cases.
Install helm diff >= 3.4.1 for better results.
```

and:

```text
The 'status.values' return value is deprecated and will be removed
in version 8.0.0. Use 'status.release_values' instead.
```

These warnings did not stop the playbook. The `changed=0` result **does not by itself establish whether this invocation installed Cilium**, especially given the module's warning about change detection. Helm subsequently confirmed a deployed release at revision 1. The record does not establish exactly which prior attempt created that release.

### Failure/constraint D — Cilium compatibility selection

The role's Kubernetes version preflight originally rejected Kubernetes `1.37` while targeting Cilium `1.20.5`. For the lab, the chart was changed to `1.21.0-pre.4` and the allowed Kubernetes minor version list was adjusted.

**Lesson:** A version gate is useful only when its assumptions are documented. A manual override for an experimental prerelease must be identified as a risk, not presented as an upstream-supported configuration.

## 6. Installation and health validation

### Helm release

```bash
helm list -n kube-system
```

Observed:

```text
NAME    NAMESPACE    REVISION    STATUS      CHART                 APP VERSION
cilium  kube-system  1           deployed    cilium-1.21.0-pre.4  1.21.0-pre.4
```

### System pods

```bash
kubectl get pods -n kube-system -o wide
```

Observed:

- Cilium agent DaemonSet: **3/3** pods `1/1 Running`, one per node.
- Cilium Envoy DaemonSet: **3/3** pods `1/1 Running`, one per node.
- Cilium operator: **2/2** pods `1/1 Running`.
- CoreDNS: **2/2** pods `1/1 Running`.
- kube-proxy: **3/3** pods `1/1 Running`, as intended.
- Control-plane static pods (etcd, API server, controller manager, scheduler): running.

### Node readiness

```bash
kubectl get nodes -o wide
```

All three nodes reported **`Ready`**, Kubernetes `v1.37.2`, Ubuntu 24.04.5 LTS, kernel `6.8.0-147-generic`, and containerd `2.2.1`.

### CRDs

```bash
kubectl get crds | grep cilium
```

Observed **13 Cilium CRDs**:

```text
ciliumcidrgroups.cilium.io
ciliumclusterwidenetworkpolicies.cilium.io
ciliumendpoints.cilium.io
ciliumidentities.cilium.io
ciliuml2announcementpolicies.cilium.io
ciliumloadbalancerippools.cilium.io
ciliumnetworkdriverclusterconfigs.cilium.io
ciliumnetworkdrivernodeconfigs.cilium.io
ciliumnetworkpolicies.cilium.io
ciliumnodeconfigs.cilium.io
ciliumnodes.cilium.io
ciliumpodippools.cilium.io
ciliumresourceippools.cilium.io
```

This verifies the Kubernetes API registered the custom resource definitions, not that every optional Cilium feature is configured or working.

## 7. Cross-node connectivity test

Created two short-lived BusyBox pods on separate worker nodes:

```bash
kubectl run nettest-1 \
  --image=busybox:1.36 \
  --restart=Never \
  --overrides='{"spec":{"nodeName":"k8s-worker-1"}}' \
  -- sleep 3600

kubectl run nettest-2 \
  --image=busybox:1.36 \
  --restart=Never \
  --overrides='{"spec":{"nodeName":"k8s-worker-2"}}' \
  -- sleep 3600

kubectl get pods -o wide
```

Observed:

| Pod         | Node           | Pod IP         | State         |
|-------------|----------------|----------------|---------------|
| `nettest-1` | `k8s-worker-1` | `10.244.2.172` | `1/1 Running` |
| `nettest-2` | `k8s-worker-2` | `10.244.1.26`  | `1/1 Running` |

```bash
kubectl exec nettest-1 -- ping -c 10 10.244.1.26
```

Observed successful ICMP echo replies, including `0.472`, `0.529`, `0.535`, `0.391`, and `0.438` ms. The supplied transcript does not include the final ping summary, so **do not claim 10/10 packets received or zero loss**. The observed replies do establish cross-node reachability at that moment.

A separate node-to-node ping from the control plane to worker 1 (`10.20.0.11`) completed with **4/4 received, 0% loss**, average RTT `0.267 ms`. This establishes underlay reachability for that node pair, independently of the pod test.

## 8. VXLAN packet inspection

On `k8s-worker-1`:

```bash
sudo tcpdump -ni enp1s0 'udp port 8472'
```

The capture exposed both outer node addresses and encapsulated inner pod addresses. Example, worker 2 to worker 1:

```text
IP 10.20.0.12.44572 > 10.20.0.11.8472:
  OTV, flags [I] (0x08), overlay 0, instance 6
IP 10.244.1.240 > 10.244.2.141:
  ICMP echo request

IP 10.20.0.11.53167 > 10.20.0.12.8472:
  OTV, flags [I] (0x08), overlay 0, instance 4
IP 10.244.2.141 > 10.244.1.240:
  ICMP echo reply
```

A second capture also showed encapsulated ICMP and TCP traffic between worker 1 (`10.20.0.11`) and the control plane (`10.20.0.10`):

```text
IP 10.20.0.11.56129 > 10.20.0.10.8472:
  OTV, flags [I] (0x08), overlay 0, instance 6
IP 10.244.2.138 > 10.244.0.14: ICMP echo request

IP 10.20.0.10.58850 > 10.20.0.11.8472:
  OTV, flags [I] (0x08), overlay 0, instance 4
IP 10.244.0.14 > 10.244.2.138: ICMP echo reply
```

**Interpretation:**

- Outer packet: node-to-node underlay IP (`10.20.0.x`) and UDP destination port `8472`.
- Inner packet: original pod-to-pod IP (`10.244.x.x`), including ICMP and TCP.
- `tcpdump` renders the tunnel protocol as `OTV` and displays VXLAN metadata such as the valid VNI flag (`[I]`) and `instance` values.
- These captures demonstrate that **VXLAN encapsulation is in use** across node pairs.
- **Important correlation limitation:** the inner addresses in the supplied captures (`10.244.1.240`, `10.244.2.141`, etc.) are **not** the addresses of `nettest-1` and `nettest-2`. Thus, the capture proves tunnel traffic exists, but it is not direct packet-level evidence for that particular test ping.

To correlate the specific test pods, capture worker-to-worker traffic while pinging and verify the inner addresses:

```bash
# On k8s-worker-1
sudo tcpdump -ni enp1s0 -vv 'udp port 8472 and host 10.20.0.12'

# On k8s-control-1
kubectl exec nettest-1 -- ping -c 5 10.244.1.26
```

Look for inner `10.244.2.172 -> 10.244.1.26` and the corresponding reply. This exact correlation remains **pending** in the supplied record.

## 9. Lessons learned

1. **A successful configuration task is not a health check.** `helm` may report `deployed` while workloads remain unhealthy; independently inspect pods, nodes, CRDs and actual connectivity.
2. **Ansible privilege escalation changes CLI context.** Root may have different kubeconfig and Helm repository settings than the login user.
3. **Dependency compatibility is part of infrastructure engineering.** The Helm 4 failure came from `kubernetes.core 6.2.0`, not from Cilium; upgrading to `6.6.0` removed that blocker.
4. **Reproducibility requires version pinning.** Document Helm, Kubernetes, chart, and collection versions, and pin the tested collection in the repository.
5. **Do not overinterpret `changed=0`.** Especially with the reported Helm module idempotency warning; confirm desired state through independent commands.
6. **Separate underlay and overlay tests.** Node ping proves different properties from pod ping; packet capture connects both layers.
7. **A prerelease is a conscious risk.** Passing smoke tests does not make a Kubernetes/Cilium prerelease combination production-ready.

## 10. Follow-up work

- [ ] Pin `kubernetes.core` version `6.6.0` in an Ansible collections `requirements.yml` and document the installation command.
- [ ] Investigate Helm 4-compatible `helm diff` plugin/version before relying on precise Helm change reporting.
- [ ] Add `roles/cilium/tasks/validate.yml`: Helm release status, DaemonSet rollout, operator rollout, node readiness, and CRD checks.
- [ ] Add a repeatable **cross-node connectivity smoke test** and cleanup of temporary pods.
- [ ] Capture VXLAN packets specifically correlated to `nettest-1` and `nettest-2`.
- [ ] Validate Kubernetes Services and CoreDNS name resolution.
- [ ] Test Cilium NetworkPolicy enforcement (allowed and denied flows).
- [ ] Evaluate Cilium's own health/status tooling and collect evidence for portfolio documentation.
- [ ] Reassess prerelease compatibility and upgrade to a suitable stable Cilium release when available.
- [ ] Proceed to Helm-based deployment of BookHub services, then CI/CD, FluxCD and observability.

## 11. Handy verification commands

```bash
# Cluster
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide
kubectl get crds | grep cilium

# Helm
helm list -n kube-system
helm status cilium -n kube-system
helm get values cilium -n kube-system

# Ansible controller (Toolbox)
ansible-galaxy collection list kubernetes.core
ansible-playbook -i inventories/host/hosts.yml \
  playbooks/k8s/install-cilium.yml -K

# Overlay connectivity
kubectl get pods -o wide
kubectl exec nettest-1 -- ping -c 5 10.244.1.26

# Underlay capture (worker 1)
sudo tcpdump -ni enp1s0 -vv 'udp port 8472 and host 10.20.0.12'

# Cleanup after tests
kubectl delete pod nettest-1 nettest-2 --ignore-not-found
```
