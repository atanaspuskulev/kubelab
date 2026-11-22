# Kubernetes Worker Enrollment — Ansible Runbook

**Stage:** 04 — Worker enrollment  
**Status:** Both workers successfully registered; rerun idempotency not yet confirmed in the provided output  
**Cluster:** kubeadm / Kubernetes v1.37.2 / containerd 2.2.1

## 1. Objective and starting state

Enroll two Ubuntu 24.04 Kubernetes workers into the existing single-control-plane cluster, without resetting already configured nodes or persisting bootstrap credentials somewhere unsafe.

| Node            | Node IP      | Function                               |
|-----------------|--------------|----------------------------------------|
| `k8s-control-1` | `10.20.0.10` | Control plane and API endpoint `:6443` |
| `k8s-worker-1`  | `10.20.0.11` | Worker                                 |
| `k8s-worker-2`  | `10.20.0.12` | Worker                                 |

The workers had containerd and Kubernetes packages installed, but were not enrolled. The API server was reachable from the workers.

## 2. Repository layout

```text
ansible/
├── inventories/host/hosts.yml
├── playbooks/k8s/kubernetes-join-workers.yml
└── roles/k8s-agent/tasks/
    ├── main.yml
    ├── preflight.yml
    ├── join.yml
    └── validate.yml
```

The playbook uses `import_role` with `tasks_from`, so the role's `main.yml` is not automatically run in this workflow.

## 3. Read-only preflight

The preflight checks:

1. Local existence of `/etc/kubernetes/kubelet.conf` with `ansible.builtin.stat`.
2. TCP connectivity from each worker to `10.20.0.10:6443` with `ansible.builtin.wait_for`.
3. Node registration in the API, using `kubectl --kubeconfig=/etc/kubernetes/admin.conf get node <inventory_hostname> --ignore-not-found -o name` delegated to the control plane.
4. Consistency between local configuration and API registration.

**Observed preflight output:**

```text
Worker: k8s-worker-1
Local kubelet config exists: False
Registered in API: False

Worker: k8s-worker-2
Local kubelet config exists: False
Registered in API: False
```

### Enrollment state decisions

| Local 
|`kubelet.conf` | API Node object | Decision |
|---------|---------|--------------------------------------------------------------|
| Missing | Missing | Eligible to join, subject to additional partial-state checks |
| Present | Present | Skip join; validate                                          |
| Present | Missing | Fail and investigate                                         |
| Missing | Present | Fail and investigate                                         |

**Limitation:** These two signals alone cannot rule out all partial `kubeadm join` states. Before using this role as a general-purpose recovery tool, inspect residual `/etc/kubernetes/pki`, kubelet state and active processes; do not automatically run `kubeadm reset`.

## 4. Enrollment orchestration

`playbooks/k8s/kubernetes-join-workers.yml` is organized as three plays:

1. **Preflight:** targets `k8s_agents`, imports `k8s-agent` tasks from `preflight.yml`.
2. **Bootstrap credentials:** targets `k8s_servers`, creates a token only when at least one worker requires enrollment.
3. **Join and validate:** targets `k8s_agents`, imports `join.yml` and `validate.yml`.

The token-generation command is:

```yaml
- name: Generate bootstrap token if workers need enrollment
  ansible.builtin.command:
    cmd: kubeadm token create --ttl 15m --print-join-command
  register: kubeadm_join_command
  changed_when: true
  no_log: true
  when: >-
    groups['k8s_agents']
    | map('extract', hostvars, 'worker_join_required')
    | select('equalto', true)
    | list
    | length > 0
```

This matches the current **single-control-plane** design. If the inventory gains more control-plane nodes, constrain token creation to one designated host. The 15-minute token lifetime means long or interrupted runs may need a fresh token.

## 5. Joining workers

The generated join command includes the API endpoint, a temporary bootstrap token, and the CA discovery hash. The worker also specifies the containerd CRI socket.

```yaml
- name: Join worker to Kubernetes cluster
  ansible.builtin.command:
    cmd: >-
      {{ hostvars[groups['k8s_servers'][0]].kubeadm_join_command.stdout }}
      --cri-socket unix:///run/containerd/containerd.sock
  register: worker_join_result
  changed_when: worker_join_result.rc == 0
  no_log: true
  when: worker_join_required | bool
```

**Security:** Never commit bootstrap tokens or rendered join commands. `no_log: true` suppresses normal Ansible task output, but the token may still be visible to privileged users inspecting the running process. Rotate/revoke any token accidentally disclosed in logs.

### Troubleshooting encountered: `argv` treated the full command as an executable

An initial attempt passed the entire generated `kubeadm join ...` string as one `argv` element. Ansible then tried to execute a file whose name was that entire string, producing `[Errno 2] No such file or directory`.

Fix: use `cmd` as above, or split the generated command into individual `argv` elements and append the CRI arguments. A second typo was corrected: `worker_join.result.rc` must be `worker_join_result.rc`.

The failed `argv` attempt did not invoke `kubeadm join`. A subsequent corrected run registered both workers successfully.

## 6. Post-join validation

The validation task runs on the control plane and retries until each worker's Node object is available:

```yaml
- name: Wait for worker registration in Kubernetes API
  ansible.builtin.command:
    cmd: >-
      kubectl
      --kubeconfig={{ kube_admin_config }}
      get node {{ inventory_hostname }}
      -o name
  delegate_to: "{{ groups['k8s_servers'][0] }}"
  become: true
  register: worker_registration_result
  changed_when: false
  retries: 12
  delay: 5
  until: worker_registration_result.rc == 0
```

Execute from the Ansible project directory:

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/k8s/kubernetes-join-workers.yml -K
```

Observed cluster state after enrollment:

```text
NAME            STATUS     ROLES           INTERNAL-IP   VERSION
k8s-control-1   NotReady   control-plane   10.20.0.10    v1.37.2
k8s-worker-1    NotReady   <none>          10.20.0.11    v1.37.2
k8s-worker-2    NotReady   <none>          10.20.0.12    v1.37.2
```

All nodes reported containerd `2.2.1`. The workers' `ROLES` value of `<none>` is normal: `kubeadm join` does not add a `node-role.kubernetes.io/worker` label. Such a label is optional and does not determine basic scheduling behavior.

### Why `NotReady` is expected

The kubelet reported:

```text
Ready=False
KubeletNotReady
NetworkReady=false reason:NetworkPluginNotReady
cni plugin not initialized
```

This is expected until a CNI is installed. It is **not** evidence that enrollment failed.

## 7. Kubernetes administration kubeconfig

Running plain `kubectl` as the `ubuntu` user initially tried `localhost:8080`, because it had no usable kubeconfig. Setting `KUBECONFIG=/etc/kubernetes/admin.conf` then caused `permission denied`: the root-owned admin kubeconfig is not readable by the regular user.

The working solution was to install a private user-owned copy:

```bash
mkdir -p ~/.kube
sudo install -o "$(id -u)" -g "$(id -g)" -m 600 \
  /etc/kubernetes/admin.conf ~/.kube/config
```

Use the default `~/.kube/config`, or set `export KUBECONFIG="$HOME/.kube/config"`. Do not make the root-owned original world-readable. This kubeconfig contains cluster-admin credentials and must not be committed to Git.

## 8. Pod CIDRs observed

Kubernetes assigned per-node Pod CIDRs from the configured `10.244.0.0/16` network:

| Node            | Assigned Pod CIDR |
|-----------------|-----------------|
| `k8s-control-1` | `10.244.0.0/24` |
| `k8s-worker-1`  | `10.244.2.0/24` |
| `k8s-worker-2`  | `10.244.1.0/24` |

These are assignments, not proof that pod traffic can flow. The CNI remains to be installed.

On both workers, `/etc/cni/net.d/` contained only a zero-byte `.kubernetes-cni-keep` placeholder, not an active CNI configuration.

## 9. Rerun and safety checklist

- Rerun the enrollment playbook and confirm token generation and join tasks are skipped for enrolled workers.
- Confirm `changed=0` on a no-op rerun. **This result was not supplied in the recorded session; do not mark it verified yet.**
- Validate all three Node objects exist.
- Do not require `Ready` until the CNI is deployed.
- Never reset nodes automatically to resolve an inconsistent state.
- Revoke any bootstrap token exposed in command output (`kubeadm token delete <token-id>`).

