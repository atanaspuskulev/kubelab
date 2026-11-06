# Troubleshooting cloud-init SSH authentication on libvirt VMs

**Project:** kubelab  
**Environment:** Ubuntu Server hypervisor, KVM/libvirt, Ubuntu 24.04 cloud images, Ansible, NoCloud seed ISOs  
**Affected guests:** `k3s-control-1`, `k3s-worker-1`, `k3s-worker-2`  
**Outcome:** SSH public-key login to `k3s-worker-1` succeeded after correcting cloud-init user-data and reprovisioning. 
Verification of the other guests and the proposed long-term ISO checksum mechanism remain separate follow-up work.

## 1. Incident summary

New Ubuntu VMs booted successfully on the `k3s-lab` libvirt network and received their expected DHCP addresses. 
However, SSH public-key authentication failed, even when connecting through the hypervisor with `ProxyJump` 
and explicitly offering the correct private key.

The investigation found **two related causes**:

1. The cloud-init user-data began with `# cloud-config` (with a space) - this was caused by VIM autoformatting. 
Cloud-init requires the exact first-line marker `#cloud-config` to recognize that content as cloud-config. 
It therefore classified the supplied user-data as `text/x-not-multipart` and did not apply the SSH key or package configuration.
2. The Ansible task generating the NoCloud seed ISO used `creates:`. Once the ISO existed, rerunning the playbook 
after correcting the Jinja2 template did **not** regenerate the ISO. Existing VMs also retained their original cloud-init instance state.

A separate configuration typo, `lock_password: true`, was corrected to `lock_passwd: true`.

## 2. Infrastructure context

```text
Deve host
    |
    | SSH ProxyJump
    v
Hypervisor (192.168.1.120)
    |
    | libvirt NAT network: k3s-lab / 10.20.0.0/24
    +-- k3s-control-1  10.20.0.10
    +-- k3s-worker-1  10.20.0.11
    +-- k3s-worker-2  10.20.0.12
```

Each VM uses a qcow2 overlay backed by the shared Ubuntu 24.04 cloud image and an individual seed ISO 
produced with `cloud-localds` from generated `user-data` and `meta-data` files.

Relevant role files:

```text
ansible/roles/kubelab-vms/
├── tasks/
│   ├── cloud-init.yml
│   ├── disks.yml
│   └── provision.yml
└── templates/
    ├── user-data.yml.j2
    └── meta-data.yml.j2
```

## 3. Initial symptoms

SSH to the worker through the hypervisor reached the guest but failed authentication:

```bash
ssh -J atan@192.168.1.120 ubuntu@10.20.0.11
# ubuntu@10.20.0.11: Permission denied (publickey).
```

Verbose SSH diagnostics showed that the development host offered its RSA key and that authentication to the jump host succeeded. 
The guest rejected the offered key. This narrowed the issue to guest-side authorization rather than jump-host access or routing.

Other observations:

- `virsh list --all` showed the guests running.
- `virsh net-dhcp-leases k3s-lab` showed the expected addresses.
- The guest's SSH daemon was reachable.
- The QEMU guest agent was not connected, suggesting first-boot package configuration might also have been skipped (not conclusive by itself).

## 4. Investigation and evidence

### 4.1 Inspect the guest filesystem offline

Because the `ubuntu` account could not be accessed with a password or key, I've inspected the qcow2 overlay using libguestfs. 
**Shut down a guest before offline inspection of its writable disk.**

On the hypervisor:

```bash
sudo virsh shutdown k3s-control-1
sudo virsh domstate k3s-control-1  # wait for "shut off"

sudo virt-ls -l \
  -a /var/lib/libvirt/images/k3s-control-1.qcow2 \
  /home/ubuntu/.ssh/
```

The decisive result was:

```text
-rw------- 1 1000 1000 0 ... authorized_keys
```

The file existed with plausible ownership and permissions, but was **0 bytes**. 
This explained the SSH rejection: the guest had no authorized public key.

### 4.2 Confirm NoCloud datasource detection

```bash
sudo virt-cat \
  -a /var/lib/libvirt/images/k3s-control-1.qcow2 \
  /var/log/cloud-init.log \
  | grep -iE 'DataSource|NoCloud|user-data|error|failed|traceback' \
  | tail -n 60
```

Relevant log messages:

```text
Detected DataSourceNoCloud
Using data from /dev/sr0
Loaded datasource DataSourceNoCloud [seed=/dev/sr0]
Writing to .../user-data.txt ... 960 bytes
```

This ruled out a missing or unattached seed ISO: cloud-init **found and read** the ISO.

### 4.3 Check whether cloud-init installed the key

```bash
sudo virt-cat \
  -a /var/lib/libvirt/images/k3s-control-1.qcow2 \
  /var/log/cloud-init.log \
  | grep -iE 'config-users|config-ssh|authorized_keys'
```

Relevant messages:

```text
config-users_groups: SUCCESS
Writing to /home/ubuntu/.ssh/authorized_keys - wb: [600] 0 bytes
config-ssh: SUCCESS
```

A module reporting `SUCCESS` does not prove the intended configuration was applied: the SSH module ran but wrote an empty key file.

### 4.4 Inspect the consumed user-data and its MIME classification

```bash
sudo virt-cat \
  -a /var/lib/libvirt/images/k3s-control-1.qcow2 \
  /var/lib/cloud/instances/k3s-control-1/user-data.txt

sudo virt-cat \
  -a /var/lib/libvirt/images/k3s-control-1.qcow2 \
  /var/lib/cloud/instances/k3s-control-1/user-data.txt.i
```

The consumed configuration contained the public key, but its first line was:

```yaml
# cloud-config
```

The intermediate MIME representation identified the part as:

```text
Content-Type: text/x-not-multipart
```

Searching the full log for warnings exposed the definitive message:

```bash
sudo virt-cat \
  -a /var/lib/libvirt/images/k3s-control-1.qcow2 \
  /var/log/cloud-init.log \
  | grep -iE 'warning|unhandled|user-data'
```

```text
Unhandled non-multipart (text/x-not-multipart) userdata: 'b'# cloud-config'...'
```

**Root cause confirmed:** the malformed header prevented cloud-init from recognizing the document as cloud-config. 
It had read the bytes but ignored the intended configuration.

### 4.5 Discover the stale seed ISO

After fixing the Jinja2 template and rerunning Ansible, SSH still failed on a worker. 
Its log contained the same `Unhandled non-multipart` warning.

Inspected the actual ISO mounted by the VM:

```bash
sudo mkdir -p /mnt/check
sudo mount -o loop,ro \
  /var/lib/libvirt/images/k3s-worker-1-seed.iso \
  /mnt/check
head -n 3 /mnt/check/user-data
sudo umount /mnt/check
```

The ISO still contained:

```yaml
# cloud-config
hostname: k3s-worker-1
manage_etc_hosts: true
```

The template was fixed, but the **existing ISO remained stale**.

The original Ansible task used:

```yaml
- name: Create cloud-init seed iso
  ansible.builtin.command:
    argv:
      - cloud-localds
      - "{{ kubelab_vm_storage_path }}/{{ item.name }}-seed.iso"
      - "{{ kubelab_vm_storage_path }}/{{ item.name }}-cloud-init/user-data"
      - "{{ kubelab_vm_storage_path }}/{{ item.name }}-cloud-init/meta-data"
    creates: "{{ kubelab_vm_storage_path }}/{{ item.name }}-seed.iso"
```

After reading and searching, I have found that `creates:` makes the command skip when the target exists, irrespective of 
input file changes. Thus, rendering a corrected `user-data` file did not update the ISO.

## 5. Corrective changes

### 5.1 Correct the cloud-init template

In `ansible/roles/kubelab-vms/templates/user-data.yml.j2`:

```diff
-# cloud-config
+#cloud-config
```

Also correct the password-locking field:

```diff
-    lock_password: true
+    lock_passwd: true
```

The SSH key remains under the intended user:

```yaml
#cloud-config
users:
  - name: ubuntu
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - ssh-rsa ...
ssh_pwauth: false
```

In the actual template, use the existing Ansible public-key variable rather than hardcoding a key. 
Ensure the rendered YAML is valid and that the header is the **first bytes of the file**.

### 5.2 Validate generated cloud-init configuration

Place validation **after rendering `user-data` and `meta-data` and before generating the ISO**:

```yaml
- name: Validate cloud-init user-data
  ansible.builtin.command:
    argv:
      - cloud-init
      - schema
      - --config-file
      - "{{ kubelab_vm_storage_path }}/{{ item.name }}-cloud-init/user-data"
  loop: "{{ kubelab_vms }}"
  loop_control:
    label: "{{ item.name }}"
  changed_when: false
```

The hypervisor must have the `cloud-init` executable. A schema check is a useful safeguard, but it does **not** replace 
checking the exact header or confirming that the guest applied the data.

### 5.3 Correct ISO regeneration conditions

The Ansible role was updated to register results from template rendering and ISO existence checks. 
The generation task should define `vm_index`, remove `creates:`, and regenerate when either template changed **or the ISO is missing**:

```yaml
- name: Generate cloud-init seed ISOs when required
  ansible.builtin.command:
    argv:
      - cloud-localds
      - "{{ kubelab_vm_storage_path }}/{{ item.name }}-seed.iso"
      - "{{ kubelab_vm_storage_path }}/{{ item.name }}-cloud-init/user-data"
      - "{{ kubelab_vm_storage_path }}/{{ item.name }}-cloud-init/meta-data"
  loop: "{{ kubelab_vms }}"
  loop_control:
    index_var: vm_index
    label: "{{ item.name }}"
  when: >-
    cloud_init_user_data.results[vm_index].changed
    or cloud_init_meta_data.results[vm_index].changed
    or not cloud_init_isos.results[vm_index].stat.exists
```

This depends on the earlier tasks registering `cloud_init_user_data`, `cloud_init_meta_data`, and `cloud_init_isos`, 
all iterating over the same ordered `kubelab_vms` list.

**Errors encountered while refining the task:**

- `vm_index is undefined` → add `loop_control.index_var: vm_index`.
- `or cloud_init_isos.results[vm_index].stat.exists` → incorrect; use `or not ...stat.exists`.
- Leaving `creates:` in place → still prevents regeneration of an existing ISO even when the `when` condition is true.
- `virt-install` reported `Size must be specified for non existent volume '*-seed.iso'` → seed ISOs were missing when VM creation ran. Verify ISO existence before invoking `virt-install`.


### 5.4 Reprovision the affected disposable guests

Correcting the ISO alone does not force cloud-init to reapply once-per-instance modules on an existing guest disk. 
For these **new, disposable** lab VMs, the remediation was to rebuild from the clean Ubuntu base image with corrected seed media.

Safe operational sequence:

1. Confirm that the guests contain no data that must be preserved.
2. Shut down each affected VM and verify it is `shut off`.
3. Undefine the affected libvirt domains as appropriate.
4. Remove **only** the selected disposable qcow2 overlays and stale seed ISOs.
5. Preserve `/var/lib/libvirt/images/ubuntu-24.04-base.img` and the libvirt network.
6. Run the Ansible provisioning playbook to recreate overlays, seed ISOs, and domains.
7. Verify the ISO contains `#cloud-config` before trusting the deployment.

### 5.5 Handle expected SSH host-key rotation

After the worker was rebuilt, SSH reported:

```text
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

A rebuilt guest generated new SSH host keys, while the client remembers the old fingerprint. 
This warning is a security feature, not proof of a new provisioning failure.

After confirming the rebuild and **verifying the new fingerprint through a trusted channel**, 
I have removed the obsolete entry on the development host:

```bash
ssh-keygen -f ~/.ssh/known_hosts -R 10.20.0.11
ssh -J atan@192.168.1.120 ubuntu@10.20.0.11
```

## 6. Verification and outcome

The final SSH connection to the worker succeeded:

```text
ubuntu@k3s-worker-1:~$
```

The home directory showed `.ssh` with restrictive permissions:

```text
drwx------ 2 ubuntu ubuntu ... .ssh
```

This demonstrates that the worker was reachable through the jump host and that the configured public-key authentication succeeded. Further checks recommended for each guest:

```bash
sudo cloud-init status --long
wc -l ~/.ssh/authorized_keys
systemctl is-active qemu-guest-agent
```

From the hypervisor:

```bash
sudo virsh list --all
sudo virsh net-dhcp-leases k3s-lab
sudo virsh qemu-agent-command k3s-worker-1 '{"execute":"guest-ping"}'
```

The guest-agent check depends on the package being installed, the service running, and the corresponding libvirt channel being configured.

## 7. Lessons learned and preventive actions

| Lesson | Preventive action |
|---|---|
| A datasource can be detected even when user-data is ignored | Inspect cloud-init warnings and effective user-data handling |
| Cloud-init module `SUCCESS` is not equivalent to successful desired-state configuration | Verify guest-side artifacts such as `authorized_keys` |
| `#cloud-config` is an exact-format marker | Validate header bytes and schema before ISO creation |
| `creates:` only checks target existence | Track input changes and regenerate derived artifacts when necessary |
| A failed playbook may leave partially updated derived artifacts | Persist input checksums and publish new ISOs atomically |
| Cloud-init first-boot state persists on the overlay disk | Require explicit reprovisioning for first-boot changes |
| VM rebuilds rotate SSH host keys | Verify fingerprints, then update `known_hosts` safely |
| Idempotency includes recovery after interruption | Test initial run, no-op rerun, changed input, missing ISO, and interrupted run |

## 8. Troubleshooting sequence at a glance

```text
SSH: Permission denied (publickey)
  ↓
ProxyJump and guest network reachable
  ↓
Offline inspect guest authorized_keys → 0 bytes
  ↓
Cloud-init detected NoCloud /dev/sr0
  ↓
Cloud-init SSH module ran but wrote 0-byte key file
  ↓
Warning: Unhandled non-multipart (text/x-not-multipart)
  ↓
Malformed header: "# cloud-config" instead of "#cloud-config"
  ↓
Fix template; rerun Ansible; issue persists
  ↓
Mount actual seed ISO → still contains old header
  ↓
Identify Ansible creates: preventing ISO regeneration
  ↓
Correct ISO generation logic and recreate disposable VM overlays
  ↓
Verify rotated SSH host key; update known_hosts
  ↓
Successful ubuntu@k3s-worker-1 SSH login
```

**Key takeaway:** The visible symptom was an SSH failure, but the actual failure was in the first-boot configuration pipeline. Following the evidence from networking → authentication → guest filesystem → cloud-init logs → seed ISO → Ansible task logic identified both the malformed input and the stale generated artifact.
