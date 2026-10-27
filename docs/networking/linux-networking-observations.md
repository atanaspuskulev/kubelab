# Linux Networking work

## Namespaces

1. List namespaces

`ip netns list`

`ip netns show`

2. Add new namespace 

`ip netns add <namespace>` - creates a new namespace with that name

3. Delete namespace

`ip netns delete <namespace>` - delete the namespace defined by this name

4. Attach device to a namespace

`ip link set <device> netns <namespace>` - attach given device to a defined namespace

5. Execute a command inside a namespace

`ip -n <namespace> <obj> <verb> <ctx> <verb>`

For example, if we want to bring up an network interface (eth0), previously attached to a 
namespace (ns), we can do:

`ip -n ns link set eth0 up`

In order, to bring it down:

`ip -n ns link set eth0 down`

6. Show information about the state of the configured namespace device state, MAC and config information

`ip -n <namespace> -br link`

7. Assign an IP (with range) to an devince inside namespace

`ip -n <namespace> addr add 10.10.1.2/16 dev eth0`

8. Checks the configured addresses of a namespace

`ip -n <namespace> -br addr`

9. Remove IP address from an device inside namespace

`ip -n <namespace> addr del <configured-IP> dev <dev>`

10. Add virtual device with a name to a configured namespace router

`ip -n <namespace> link add <virtual-dev> type veth peer <name> netns <namespace-router-name>`

`ip -n ns1 link add veth1 type veth peer rtl1 netns ns-router`

11. Remove device from a namespace

`ip -n <namespace> link delete <device>`

12. Attach virtual name device with a specific address to a router (see 10)

`ip -n <router-name> addr add 10.10.1.1/16 dev rtl1`

13. Bring up lo interface for a namespace

`ip -n <namespace> link set lo up`

14. Get a namespace route to an IP. Inspection for debug purposes

`ip -n <namespace> route get <ip-address>`

15. Add the default route to a namespace

`ip -n <namespace> add default via <ip-address>`

where <ip-address> is the IP configured for the NS network.

16. Delete the default routing from a namespace.

`ip -n <namespace> route del default`

## Bridge network

1. Create bridge network

`ip link add name <name> type bridge`

2. Set up bridge network

`ip link set <name> up`

3. Bring it down

`ip link set <name> down`

4. Set interface as a slave to the bridge network

`ip link set eth0 master <name>`

where <name> is the name of bridged network.

5. Assign IP to the bridge

`ip addr add 10.10.2.3/24 dev <name>`

where <name> is the name of the bridged network.

6. Verify bridge network

`ip link show type bridge`

`bridge link show`

`ip addr show <name>`

where <name> is the name of the bridged network.

7. Delete bridged network

`ip link delete <name> type bridge`

## Various

1. Check ipv4 (is enabled via sysctl) for a namespace

`ip netns exec <namespace> sysctl net.ipv4.ip_forward`

2. Capture packet exchange for a namespace routing (ICMP)

`sudo ip netns exec <namespace> tcpdump -ni r2 icmp`

3. Capture traffic to/from an IP
`tcpdump -ni eth0 host 10.10.1.2`

4. Capture ICMP traffic
`tcpdump -ni eth0 icmp`
