#!/usr/bin/env bash

set -Eeuo pipefail

# Define all paths used by this script

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
STATE_DIR="$PROJECT_ROOT/state/networking"

ACTION=''
BRIDGE=''
COUNT=''
PREFIX=''
SUBNET=''

usage() {
    cat << 'USAGE'
Usage:
    network-manager.sh create --bridge NAME --namescapes COUNT --prefix PREFIX --subnet CIDR
    network-manager.sh verify --bridge NAME
    network-manager.sh delete --bridge NAME
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        create|verify|delete)
            [[ -z "$ACTION" ]] || fail 'Only one action is allowed'
            ACTION=$1
            shift
            ;;

        --bridge|--namespaces|--prefix|--subnet)
            opt=$1
            (($# >= 2)) || fail "Missing value for $opt"

            case "$opt" in
                --bridge) BRIDGE=$2 ;;
                --namespaces) COUNT=$2 ;;
                --prefix) PREFIX=$2 ;;
                --subnet) SUBNET=$2 ;;
            esac

            shift 2
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

# Invalidate user options

[[ $EUID -eq 0 ]] || fail 'This script must be run as root/sudo'
[[ $ACTION == create || $ACTION == verify || $ACTION == delete ]] || { usage; exit 2; }
[[ $BRIDGE =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] || fail 'Invalid bridge name; maximum of 15 characters allowed'
[[ $BRIDGE != '.' && $BRIDGE != '..' ]] || fail 'Invalid bridge name'

# Set the important variables
STATE_FILE="$STATE_DIR/$BRIDGE.state"
LOCK_FILE="$STATE_DIR/$BRIDGE.lock"

# State is privileged ownership metadata, not a disposabale cache.
# Refuse a symlink and an existing directory owned by a non-root user.
[[ ! -L "$STATE_DIR" ]] || fail 'State directory must not be symlink'

if [[ -e "$STATE_DIR" ]]; then
    [[ -d "$STATE_DIR" && $(stat -c %u "$STATE_DIR") == 0 ]] || fail 'State directory must be root owned'
fi

install -d -m 0700 -o root -g root "$STATE_DIR"

# Explicitly check on the lock & state files
[[ ! -L "$LOCK_FILE" && ! -L "$STATE_FILE" ]] || fail 'State/Lock file(s) must not be symlink'
exec 9>"$LOCK_FILE"
flock -n 9 || fail "Another operation is running for $BRIDGE. LOCKFILE $LOCK_FILE is busy"

# Store only simple, validated values. Never save shell-source in the state file.
read_state() {
    [[ -f $STATE_FILE ]] || fail "No managed lab found for $BRIDGE"
    mapfile -t state < "$STATE_FILE"

    [[ ${#state[@]} -eq 4 ]] || fail 'Invalid state file'
    [[ ${state[@]} == "$BRIDGE" ]] || fail 'State bridge mismatch'
    COUNT=${state[1]}
    PREFIX=${state[2]}
    SUBNET=${state[3]}

    validate_values
}

validate_values() {
    [[ $COUNT =~ ^[1-9][0-9]*$ ]] || fail 'Namespaces count must be a positive number'
    (( COUNT <= 200 )) || fail 'The maximum number of namespaces that can be defined is 200'
    [[ $PREFIX =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || fail "Invalid prefix: $PREFIX"
    (( ${#PREFIX} + ${#COUNT} < 63 )) || fail 'Namespaces names are too long'
    [[ $SUBNET =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || fail 'Invalid subnet format'
    command -v python3 >/dev/null || fail 'python3 required for CIDR validation'
    python3 - "$SUBNET" "$COUNT" << 'PY' || fail 'Invalid subnet or insufficient usable addresses'
import ipaddress, sys
try:
    net=ipaddress.IPv4Network(sys.argv[1],strict=True)
    count=int(sys.argv[2])
    assert net.prefixlen <= 30 and net.num_addresses-2 >= count
except (ValueError,AssertionError):
    sys.exit(1)
PY
}

# Short deterministic host-side interface names;
# hash avoids cross-lab collisions
peer_name() {
    local hash
    hash=$(printf '%s' "$BRIDGE" | sha256sum)
    hash=${hash:0:6}
    printf 'nl%s%03d' "$hash" "$1"
}

ns_name() {
    printf '%s%d' "$PREFIX" "$1"
}

# Only delete resources belonging to this run on failure
created_ns=()
created_peers=()
created_bridges=0

rollback() {
    local rc=$?

    trap - ERR INT TERM
    echo 'Creation failed; cleaning up resources for this attempt...' >&2
    
    for ns in "${created_ns[@]}"; do
        ip netns del "$ns" 2>/dev/null || true
    done

    for peer in "${created_peers[@]}"; do
        ip link del "$peer" 2>/dev/null || true
    done

    if (( created_bridges )); then
        ip link del "$BRIDGE" 2>/dev/null || true
    fi

    rm -f "$STATE_FILE"
    exit "${rc:-1}"
}

delete_network() {
    local i ns peer
    local -a remaining_peers=()
    local -a remaining_ns=()

    read_state

    [[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || fail 'Invalid namespaces count in state'
    [[ "$PREFIX" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || fail 'Invalid namespace prefix in state'

    # Validate resources, before delete
    if ip link show dev "$BRIDGE" &>/dev/null; then
        [[ "$(ip -d -j link show dev "$BRIDGE" | 
            jq -r '.[0].linkinfo.info_kind')" == "bridge" ]] || fail "BRIDGE $BRIDGE exists but is not a bridge"

        # Reject interfaces attached to the bridge that we don't own
        local actual_ports expected_ports

        actual_ports="$(bridge link show master "$BRIDGE" | 
            sed -nE 's/^[0-9]+: ([^:@]+).*/\1/p' | sort)"

        expected_ports=""
        for ((i=1; i<=COUNT; i++)); do
            peer="$(peer_name "$i")"

            if ip link show dev "$peer" &>/dev/null; then
                expected_ports+="${peer}"$'\n'
            fi
        done

        [[ "$actual_ports" == "$(printf '%s' "$expected_ports" | 
            sed '/^$/d' | sort)" ]] || fail "Unexpected interface attached to BRIDGE $BRIDGE"
    fi

    for ((i=1; i<=COUNT; i++)); do
        ns="$(ns_name "$i")"
        peer="$(peer_name "$i")"

        if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
            if ip -n "$ns" link show eth0 &>/dev/null; then
                # Is eth0 a veth interface?
                [[ "$(ip -n "$ns" -d -j link show dev eth0 | 
                    jq -r '.[0].linkinfo.info_kind')" == "veth" ]] || fail "Interface eth0 in namespace $ns is not a veth"

                # Check if host-side peer exists
                ip link show dev "$peer" &>/dev/null || fail "Expected PEER $peer for namespace $ns is missing"

                # Iface index of host-side peer
                local peer_ifindex
                peer_ifindex="$(ip -j link show dev "$peer" | jq -r '.[0].ifindex')"

                # Peer iface index recorded by eth0
                local eth0_peer_index
                eth0_peer_index="$(ip -n "$ns" -j link show dev eth0 | jq -r '.[0].link_index')"

                [[ "$eth0_peer_index" == "$peer_ifindex" ]] || fail "Interface eth0 in namespace $ns is not connected to $peer"
            fi
            remaining_ns+=("$ns")
        fi

        if ip link show dev "$peer" &>/dev/null; then
            [[ "$(ip -d -j link show dev "$peer" | 
                jq -r '.[0].linkinfo.info_kind')" == "veth" ]] || fail "PEER $peer exists, but is not a veth"

            [[ -n "$BRIDGE" ]] || fail "Bridge name is empty"

            remaining_peers+=("$peer")
        fi
    done

    # Remove remaining resources
    for peer in "${remaining_peers[@]}"; do
        echo "Deleting veth: $peer"
        ip link delete dev "$peer"
    done

    for ns in "${remaining_ns[@]}"; do
        echo "Deleting namespace: $ns"
        ip netns delete "$ns"
    done

    if ip link show dev "$BRIDGE" &>/dev/null; then
        echo "Deleting bridge: $BRIDGE"
        ip link delete dev "$BRIDGE"
    fi

    rm -- "$STATE_FILE"

    echo "Network lab deleted successfully"
}


case "$ACTION" in
    create)
        [[ -n $COUNT && -n $PREFIX && -n $SUBNET ]] || fail 'create requires --namespaces, --prefix and --subnet'
        validate_values

        [[ ! -e $STATE_FILE ]] || fail "Managed lab already exists: $BRIDGE"

        ! ip link show dev "$BRIDGE" &>/dev/null || fail "Interface already exists: $BRIDGE"

        for ((i=1; i<=COUNT; i++)); do
            ns=$(ns_name "$i")
            peer=$(peer_name "$i")

            ! ip netns list | awk '{print $1}' | grep -Fxq "$ns" || fail "Namespace already exists: $ns"
            ! ip link show dev "$peer" &>/dev/null || fail "Interface already exists: $peer"
        done

        trap rollback ERR
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'rollback' EXIT
        
        ip link add "$BRIDGE" type bridge 
        created_bridges=1
        ip link set "$BRIDGE" up

        for ((i=1; i<=COUNT; i++)); do
            ns=$(ns_name "$i")
            peer=$(peer_name "$i")

            ip netns add "$ns"
            created_ns+=("$ns")

            ip link add "$peer" type veth peer name eth0
            created_peers+=("$peer")

            ip link set eth0 netns "$ns"
            ip link set "$peer" master "$BRIDGE"
            ip link set "$peer" up
            ip -n "$ns" link set lo up
            ip -n "$ns" link set eth0 up
            ip_addr=$(python3 - "$SUBNET" "$i" <<'PY'
import ipaddress,sys
net=ipaddress.IPv4Network(sys.argv[1])
print(f'{net.network_address+int(sys.argv[2])}/{net.prefixlen')
PY
)
            ip -n "$ns" addr add "$ip_addr" dev eth0
            echo "Created $ns: $ip_addr"
        done

        printf '%s\n%s\n%s\n%s\n' "$BRIDGE" "$COUNT" "$PREFIX" "$SUBNET" > "$STATE_FILE"
        chmod 600 "$STATE_FILE"
        trap - EXIT ERR INT TERM
        echo "Created bridge $BRIDGE with $COUNT namespaces"
        ;;
    
    verify)
        [[ -z $COUNT && -z $PREFIX && -z $SUBNET ]] || fail 'verify only accepts --bridge'

        read_state

        for ((i=1; i<=COUNT; i++)); do
            ns=$(ns_name "$i")
            peer=$(peer_name "$i")
            
            ip -n "$ns" link show eth0 >/dev/null || fail "Missing eth0 in $ns"
            ip link show dev "$peer" >/dev/null || fail "Missing $peer"

            [[ $(bridge link show dev "$peer") == *"master $BRIDGE"* ]] || fail "$peer not attached to $BRIDGE"

            ip_addr=$(python3 - "$SUBNET" "$i" <<'PY'
import ipaddress,sys
net=ipaddress.IPv4Network(sys.argv[1])
print(f'{net.network_address+int(sys.argv[2])}/{net.prefixlen}')
PY
)
            ip -n "$ns" -o -4 addr show dev eth0 | grep -Fq "inet $ip_addr " || fail "IP mismatch in $ns"
            echo "OK: $ns ($ip_addr)"
        done
        echo 'Topology verified (structural check only)'
        ;;

    delete)
        [[ -z $COUNT && -z $PREFIX && -z $SUBNET ]] || fail 'delete only accepts --bridge'

        delete_network
        ;;
esac
