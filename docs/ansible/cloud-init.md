# Cloud-init

## Purpose

I am using **cloud-init** to initialize Ubuntu VMs provisioned by Ansible on KVM/libvirt. It configures each guest on first boot; ongoing configuration is handled by Ansible.

## How it works

1. Ansible renders `user-data` and `meta-data` from Jinja2 templates.
2. `cloud-localds` packages them into a NoCloud seed ISO attached to the VM.
3. On first boot, cloud-init reads the ISO and applies the configuration, including hostname, user settings, and SSH authorized keys.

The `user-data` file must start with the exact header:

```yaml
#cloud-config
```

## Validation

Inside a guest VM:

```bash
sudo cloud-init status --long
```

Expected: `status: done` and `errors: []`.

Verify SSH key installation:

```bash
ls -ld ~/.ssh
wc -l ~/.ssh/authorized_keys
```

From the Ansible controller, verify connectivity:

```bash
cd ansible
ansible k3s_cluster -i inventories/host/hosts.yml -m ansible.builtin.ping
```

## Important behavior

- Cloud-init configuration is normally applied **once per instance**. Updating the seed ISO does not automatically reconfigure an existing VM.
- Seed ISOs should be regenerated when their input files change or the ISO is missing.
- Recreating a VM can change its SSH **host key**; this is different from the user's public key injected into `authorized_keys`.
- The hypervisor's own cloud-init status is independent of the guest VMs.

## Troubleshooting

See [Cloud-init SSH troubleshooting](kubelab-cloud-init-ssh-troubleshooting.md) for the incident involving a malformed `#cloud-config` header and stale seed ISOs.

