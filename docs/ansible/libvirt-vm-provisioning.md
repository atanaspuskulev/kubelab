# QEMU

## Why

***Why chose qemu?

First of, becase I havent workend exactly with this type  of KVM virtualization.
Second, it is very lightweight compared to the other provisioners. After all, I just needed
something simple to work with.

## Topics

### Installation

All the installed packages and dependencies were installed via Ansible provision.

### Verifications

List all configured VMs to inspect.

```bash
sudo virsh list --all
```

Showing the created VMs with their respective statuses.

```text
 Id   Name            State
-------------------------------
 4    k3s-control-1   running
 5    k3s-worker-1    running
 6    k3s-worker-2    running
```

Since, my configuration is to use DHCP ip addresses assignments, to each VM (though each VM has assigned IP address),
this is how I inspect the states of the network configuration:

```bash
sudo virsh net-dhcp-leases k3s-lab
```

where the **k3s-lab** is my network name.

```text
 Expiry Time           MAC address         Protocol   IP address      Hostname        Client ID or DUID
------------------------------------------------------------------------------------------------------------------------------------------------
 2026-11-07 17:38:21   52:54:00:20:00:10   ipv4       10.20.0.10/24   k3s-control-1   ff:56:50:4d:98:00:02:00:00:ab:11:14:d9:a7:7b:f6:ce:dd:e7
 2026-11-07 17:38:37   52:54:00:20:00:11   ipv4       10.20.0.11/24   k3s-worker-1    ff:56:50:4d:98:00:02:00:00:ab:11:57:55:b5:b8:f4:ab:f3:5d
 2026-11-07 17:37:00   52:54:00:20:00:12   ipv4       10.20.0.12/24   k3s-worker-2    ff:56:50:4d:98:00:02:00:00:ab:11:df:8b:8c:12:a9:07:d1:e0
```

The use of **cloud-init** was only during the creation of the VMs. I do not rely on it, to control the VMs.
The check that it is actually disabled (on the host machine, where the VMs resides):

```bash
sudo cloud-init status --long
```

should output something similar to

```text
status: disabled
extended_status: disabled
boot_status_code: disabled-by-marker-file
detail: Cloud-init disabled by /etc/cloud/cloud-init.disabled
errors: []
recoverable_errors: {}
```

This expected result on the host (hypervisor) is independend from the one inside a VM.

However, on an actual VM, the expectation is the opposite, it should be **done** and not **inactive**:

```text
status: done
extended_status: done
boot_status_code: enabled-by-generator
last_update: Thu, 01 Jan 1970 00:00:37 +0000
detail: DataSourceNoCloud [seed=/dev/sr0]
errors: []
recoverable_errors: {}
```

Also, if all went well, no errors should be reported.

The qemu guest agent, should also be inactive on the host:

```bash
systemctl is-active qemu-guest-agent
```

and the result

```text
inactive
```

Again, on an actual VM, it should be active, so that the communication with the host Qemu, must be persistent.

## Verify, that Qemu bring all networks correctly

Inside each of the VMs, I inspected the configured network, in order to ensure, all is correct.

```bash
ubuntu@k3s-worker-1:~$ ip -br addr
lo               UNKNOWN        127.0.0.1/8 ::1/128
enp1s0           UP             10.20.0.11/24 metric 100 fe80::5054:ff:fe20:11/64
```

and check if the routing is correct:

```bash
ubuntu@k3s-worker-1:~$ ip route
default via 10.20.0.1 dev enp1s0 proto dhcp src 10.20.0.11 metric 100
10.20.0.0/24 dev enp1s0 proto kernel scope link src 10.20.0.11 metric 100
10.20.0.1 dev enp1s0 proto dhcp scope link src 10.20.0.11 metric 100
```

ping the control node

```
ubuntu@k3s-worker-1:~$ ping 10.20.0.10
PING 10.20.0.10 (10.20.0.10) 56(84) bytes of data.
64 bytes from 10.20.0.10: icmp_seq=1 ttl=64 time=0.872 ms
64 bytes from 10.20.0.10: icmp_seq=2 ttl=64 time=0.605 ms
```

ping the other VM

```bash
ubuntu@k3s-worker-1:~$ ping 10.20.0.12
PING 10.20.0.12 (10.20.0.12) 56(84) bytes of data.
64 bytes from 10.20.0.12: icmp_seq=1 ttl=64 time=0.791 ms
64 bytes from 10.20.0.12: icmp_seq=2 ttl=64 time=0.814 ms
```

### Test DNS resolution

```bash
getent hosts github.com
```

should return

```text
140.82.121.4    github.com
```


## VM Provisioning and Validation

The `kubelab-vms` Ansible role provisions and manages the lifecycle of the Kubernetes virtual machines running on QEMU/KVM with libvirt.

The provisioning workflow is designed to be repeatable, idempotent, and recoverable from interrupted executions.

### VM Lifecycle Management

The role manages three virtual machines:

| VM              | IP Address   | Role                     |
|-----------------|--------------|--------------------------|
| `k3s-control-1` | `10.20.0.10` | Kubernetes control plane |
| `k3s-worker-1`  | `10.20.0.11` | Kubernetes worker        |
| `k3s-worker-2`  | `10.20.0.12` | Kubernetes worker        |

During provisioning, Ansible:

1. Creates missing virtual machines.
2. Preserves existing VM definitions and disks.
3. Starts existing VMs if they are stopped.
4. Enables libvirt autostart for each VM.
5. Waits for SSH connectivity and cloud-init completion.

VM autostart ensures that the virtual machines are started automatically when the libvirt host starts.

### Persistent DHCP Reservations

The `k3s-lab` libvirt network uses static DHCP reservations to provide predictable IP addresses.

Reservations are declared in:

`roles/kubelab-virt/templates/network.xml.j2`

The template reads VM names, MAC addresses, and IP addresses from the shared `kubelab_vms` inventory variable.

This makes the persistent libvirt network definition the source of truth and prevents configuration drift between live and persistent DHCP reservations.

Verify the persistent configuration:

```bash
virsh -c qemu:///system net-dumpxml k3s-lab --inactive
```

Verify the active configuration:

```bash
virsh -c qemu:///system net-dumpxml k3s-lab
```

Both should contain the expected MAC-to-IP reservations.

### Cloud-init Seed ISO Management

Cloud-init seed ISOs are generated from two files:

- `user-data`: guest initialization configuration.
- `meta-data`: instance identification and metadata.

The provisioning role calculates SHA-256 checksums of both input files and combines them into a single checksum.

The checksum is compared with the previously persisted value in:

`<vm-name>-cloud-init/inputs.sha256`

An ISO is regenerated when:

- The ISO does not exist.
- The input files have changed.
- The persisted checksum is missing or differs from the current checksum.

The generation process:

1. Creates a temporary ISO file.
2. Generates the seed ISO using `cloud-localds`.
3. Verifies that the generated file exists and is nonempty.
4. Atomically replaces the existing ISO.
5. Persists the checksum after successful generation.
6. Removes the temporary file during cleanup.

This allows provisioning to recover from interrupted runs without manually deleting stale ISO files.

**Important:** Updating a seed ISO does not automatically reapply cloud-init configuration inside an existing VM. Cloud-init initialization normally runs once per instance. Changes to an existing VM may require a separate configuration-management operation.

### Provisioning Validation

Run the provisioning playbook from the `ansible/` directory:

```bash
ansible-playbook -i inventories/host/hosts.yml \
  playbooks/provision-vms-kubelab.yml
```

Run it a second time to verify idempotency.

Expected play recap:

```text
failed=0
changed=0
```

#### Verify VM States

On the hypervisor:

```bash
virsh -c qemu:///system list --all
```

All three Kubernetes VMs should be running.

#### Verify VM Autostart

```bash
for vm in k3s-control-1 k3s-worker-1 k3s-worker-2; do
    virsh -c qemu:///system dominfo "$vm" \
      | grep -E '^State:|^Autostart:'
done
```

Expected for every VM:

```text
State:          running
Autostart:      enable
```

`Autostart Once: disable` is normal and does not affect regular VM autostart.

#### Verify DHCP Reservations

```bash
virsh -c qemu:///system net-dumpxml k3s-lab --inactive
```

Expected reservations:

| VM              | MAC Address         | IP Address   |
|-----------------|---------------------|--------------|
| `k3s-control-1` | `52:54:00:20:00:10` | `10.20.0.10` |
| `k3s-worker-1`  | `52:54:00:20:00:11` | `10.20.0.11` |
| `k3s-worker-2`  | `52:54:00:20:00:12` | `10.20.0.12` |

#### Verify Guest Readiness

The provisioning workflow waits for:

1. SSH connectivity to each VM.
2. Successful cloud-init completion.

Cloud-init can also be checked manually inside a guest:

```bash
sudo cloud-init status --wait --long
```

Expected:

```text
status: done
```

### Idempotency and Recovery

The provisioning workflow is designed to maintain the declared infrastructure state without unnecessary changes.

| Scenario                            | Expected behavior                        |
|-------------------------------------|------------------------------------------|
| VM already exists and is running    | Preserve VM                              |
| VM exists but is stopped            | Start VM                                 |
| VM autostart disabled               | Enable autostart                         |
| VM autostart enabled                | No change                                |
| Seed ISO missing                    | Regenerate ISO                           |
| Cloud-init inputs changed           | Regenerate ISO                           |
| Seed ISO and checksum unchanged     | Skip regeneration                        |
| Previous ISO generation interrupted | Regenerate if checksum was not persisted |
| Provisioning playbook rerun         | `changed=0` when state matches           |

The successful second execution of the provisioning playbook provides evidence of idempotency for the current configuration.

### Operational Considerations

- VM disks and definitions should not be deleted during routine provisioning.
- Seed ISO regeneration does not imply that existing guests have applied the new configuration.
- Persistent DHCP reservations should remain consistent with the VM inventory.
- VM autostart should be managed declaratively rather than configured manually.
- Provisioning failures should be investigated before attempting destructive recovery actions.

