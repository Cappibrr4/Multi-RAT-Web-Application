#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Dynamic policy routing for mp-quic multipath.
#
# mp-quic can only use a link if traffic sourced from that interface's address
# is sent out of that interface's own gateway. That needs, per interface, a
# dedicated routing table plus an `ip rule from <addr> table <t>`. When a client
# or interface resets, the address can change and the rule is lost, so this is
# re-checked on every dashboard start.
#
# Nothing here is hardcoded to specific interfaces. It DISCOVERS every interface
# that currently has a global IPv4 address (minus loopback / virtual ones) and,
# for each, ensures its table + rule exist:
#   * routes are installed with `ip route replace` (idempotent);
#   * the source `ip rule` is (re)added only when `ip rule list` has none for
#     the interface's CURRENT address — which also repairs it after a reset gave
#     the interface a new IP;
#   * per-interface routing tables are auto-registered in rt_tables on demand.
#
# Gateway per interface = an existing default route via that dev if there is
# one, else the first host of its subnet (network + 1), matching the usual
# `.1` gateway convention.
#
# Overridable via env:
#   MRAT_BASE_TABLE_ID  first routing-table id / rule priority to allocate (100)
#   MRAT_TABLE_PREFIX   routing-table name prefix (mrat_)
#   MRAT_EXCLUDE_RE     regex of interface names to skip
#   MRAT_DRY_RUN=1      print the ip commands instead of running them
#
# Needs sudo for the ip / rt_tables changes; run from a terminal (start.sh does)
# so sudo can prompt.
# ---------------------------------------------------------------------------
set -uo pipefail

BASE_TABLE_ID="${MRAT_BASE_TABLE_ID:-100}"
TABLE_PREFIX="${MRAT_TABLE_PREFIX:-mrat_}"
EXCLUDE_RE="${MRAT_EXCLUDE_RE:-^(lo|docker|veth|br-|virbr|vnet|tun|tap|wg|tailscale|zt|kube|cni|flannel|dummy|bond|ifb)}"
DRY_RUN="${MRAT_DRY_RUN:-0}"
RT_TABLES=/etc/iproute2/rt_tables

declare -A ALLOCATED   # routing-table ids already taken

run() {   # execute, or just print under MRAT_DRY_RUN=1
    if [[ "$DRY_RUN" == "1" ]]; then echo "    [dry-run] $*"; else "$@"; fi
}

seed_allocated_ids() {
    local id _
    while read -r id _; do
        [[ "$id" =~ ^[0-9]+$ ]] && ALLOCATED[$id]=1
    done < <(grep -vE '^[[:space:]]*#' "$RT_TABLES" 2>/dev/null)
}

subnet_of() { python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network.with_prefixlen)' "$1"; }
gw_of()     { python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network.network_address+1)' "$1"; }

# An existing default gateway reachable via this interface, if any.
detect_gw() {
    ip route show default dev "$1" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

# Ensure a named routing table exists in rt_tables; sets REPLY_ID to its id.
ensure_table() {
    local table="$1" id cand
    id="$(awk -v t="$table" '$1!~/^#/ && $2==t{print $1; exit}' "$RT_TABLES" 2>/dev/null)"
    if [[ -n "$id" ]]; then REPLY_ID="$id"; ALLOCATED[$id]=1; return; fi
    cand=$BASE_TABLE_ID
    while [[ -n "${ALLOCATED[$cand]:-}" ]]; do cand=$((cand+1)); done
    ALLOCATED[$cand]=1
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "    [dry-run] would register table '$table' (id $cand) in $RT_TABLES"
    else
        echo "$cand $table" | sudo tee -a "$RT_TABLES" >/dev/null
        echo "  + registered routing table '$table' (id $cand)"
    fi
    REPLY_ID="$cand"
}

setup_link() {
    local iface="$1" cidr="$2"
    local ip="${cidr%%/*}"
    local subnet gw table
    subnet="$(subnet_of "$cidr")"
    table="${TABLE_PREFIX}${iface}"

    # Already routed for this exact address? Nothing to do.
    if ip rule list | grep -qE "from ${ip//./\\.} lookup ${table}\b"; then
        echo "  = $iface already routed (from $ip -> $table)"
        return
    fi

    gw="$(detect_gw "$iface")"; [[ -z "$gw" ]] && gw="$(gw_of "$cidr")"
    ensure_table "$table"
    local prio="$REPLY_ID"

    echo "  + configuring $iface: $ip/${cidr##*/} -> table $table via $gw (priority $prio)"
    run sudo ip route replace default via "$gw" dev "$iface" table "$table"
    run sudo ip route replace "$subnet" dev "$iface" scope link table "$table"

    # Drop any stale rule(s) for this table (e.g. an old IP from before a reset),
    # then add the source rule for the current address.
    while ip rule list | grep -qE "lookup ${table}\b"; do
        run sudo ip rule del table "$table" || break
        [[ "$DRY_RUN" == "1" ]] && break   # avoid an infinite loop in dry-run
    done
    run sudo ip rule add from "$ip" table "$table" priority "$prio"
    echo "    ip rule: from $ip table $table priority $prio"
}

echo "Checking mp-quic policy routing (dynamic per-interface)…"
seed_allocated_ids
declare -A SEEN
while read -r iface cidr; do
    [[ -z "$iface" || -z "$cidr" ]] && continue
    if [[ "$iface" =~ $EXCLUDE_RE ]]; then
        echo "  - $iface excluded"
        continue
    fi
    [[ -n "${SEEN[$iface]:-}" ]] && continue   # one rule per interface (first global addr)
    SEEN[$iface]=1
    setup_link "$iface" "$cidr"
done < <(ip -o -4 addr show up scope global 2>/dev/null | awk '{print $2, $4}')
echo "Policy routing check done."
