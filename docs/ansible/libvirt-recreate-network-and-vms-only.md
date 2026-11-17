# Recreation only on the network and VMs in order

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/prepare-host-kubelab.yml -K
```

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/provision-vms-kubelab.yml -K
```

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/wait-for-k8s-nodes.yml -K
```

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/prepare-k8s-nodes.yml -K
```

```bash
ansible-playbook \
  -i inventories/host/hosts.yml \
  playbooks/verify-k8s-prerequisites.yml -K
```
