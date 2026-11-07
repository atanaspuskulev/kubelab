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

