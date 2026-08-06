#!/bin/sh
#
# r8125-tune.sh - confine RSS to N RX rings and pin the r8125 MSI-X vectors so no
# active RX ring shares a core with a TX ring.
#
# Standalone test tool. scp it to the NAS and run as root. Nothing here persists:
# a module reload or reboot puts everything back. Once the layout is shown to
# help, the same logic moves into the QPKG service script.
#
# Why this is needed at all: QTS never tunes r8125 interrupts.
# /etc/init.d/init_platform.sh only touches NICs advertising 10000base (and only
# on hybrid-core SoCs, which the RK3568 is not) or those on the st_gmac driver.
# So every vector keeps the default 0-3 mask and the ARM GICv3 ITS picks a target
# core per vector by itself, differently on each load. That is why two identical
# iperf runs put RX and TX on separate cores once and the same core the next time.
#
# Usage:
#   ./r8125-tune.sh [apply|show|snap|diff] [interface] [rx_rings]
#
#   apply   set the RSS table and pin the vectors, then show the layout (default)
#   show    print the current layout without changing anything
#   snap    record interrupt counters and NIC drop counters
#   diff    compare against the last snap - run this after an iperf
#
# Typical session:
#   ./r8125-tune.sh apply
#   ./r8125-tune.sh snap
#   ...run a 60s iperf3 from the client...
#   ./r8125-tune.sh diff

set -u

CMD="${1:-apply}"
IFACE="${2:-eth0}"
RX_WANT="${3:-2}"
SNAP=/tmp/r8125-tune.snap

ETHTOOL=/usr/sbin/ethtool
[ -x "$ETHTOOL" ] || ETHTOOL=$(command -v ethtool 2>/dev/null || echo "")

die() { echo "ERROR: $*" >&2; exit 1; }

# IRQ number for a vector name like eth0-16
irq_of() {
    awk -v n="${IFACE}-$1" '$NF == n { sub(":", "", $1); print $1; exit }' /proc/interrupts
}

# All "<irq> <vector>" pairs belonging to this interface, vector ascending
vector_pairs() {
    awk -v ifc="$IFACE" '
        $NF ~ "^" ifc "-[0-9]+$" {
            irq = $1; sub(":", "", irq);
            n = $NF; sub(".*-", "", n);
            print n, irq
        }' /proc/interrupts | sort -n | awk '{print $2, $1}'
}

# Read a hex field out of the driver's procfs dump, e.g. num_rx_rings -> 4
driver_var() {
    _f="/proc/net/r8125/${IFACE}/debug/driver_var"
    [ -r "$_f" ] || return 1
    _v=$(awk -v k="$1" '$1 == k { print $2; exit }' "$_f")
    [ -n "$_v" ] || return 1
    echo $(( _v ))
}

# Which vectors carry TX completions. The mapping moves with HwCurrIsrVer - see
# rtl8125_interrupt_msix() in r8125_n.c - so derive it rather than assuming.
tx_vectors() {
    _isr=$(driver_var HwCurrIsrVer 2>/dev/null || echo "")
    case "$_isr" in
        5)  echo "16 17" ;;
        7)  echo "27 28" ;;
        3|4) echo "" ;;   # TX shares the low message IDs with RX; not handled
        *)  echo "16 18" ;;
    esac
}

cpu_count() { grep -c ^processor /proc/cpuinfo; }

NCPU=$(cpu_count)

# Interrupt count for an IRQ, summed across CPUs. Only the first NCPU fields
# after the "NNN:" are per-CPU counts - what follows is the controller name, the
# MSI hwirq number and the trigger type, and summing those yields nonsense.
irq_count() {
    awk -v i="$1:" -v nc="$NCPU" '$1 == i { s = 0; for (j = 2; j <= nc + 1; j++) s += $j; print s; exit }' /proc/interrupts
}

show_layout() {
    echo "=== ${IFACE} ==="
    if [ -r "/sys/module/r8125/version" ]; then
        echo "driver     : $(cat /sys/module/r8125/version)"
    fi
    _nrx=$(driver_var num_rx_rings 2>/dev/null || echo "?")
    _ntx=$(driver_var num_tx_rings 2>/dev/null || echo "?")
    _isr=$(driver_var HwCurrIsrVer 2>/dev/null || echo "?")
    _nvec=$(driver_var irq_nvecs 2>/dev/null || echo "?")
    echo "rings      : ${_nrx} RX / ${_ntx} TX, HwCurrIsrVer=${_isr}, ${_nvec} MSI-X vectors"
    echo "TX vectors : $(tx_vectors)"
    echo ""

    if [ -n "$ETHTOOL" ]; then
        echo "RSS indirection table (first line shows which rings are in use):"
        "$ETHTOOL" -x "$IFACE" 2>/dev/null | sed -n '2,4p'
        echo ""
    fi

    echo "vector  irq   cpu   interrupts"
    vector_pairs | while read -r _irq _n; do
        _aff=$(cat "/proc/irq/${_irq}/smp_affinity_list" 2>/dev/null || echo "?")
        _cnt=$(irq_count "${_irq}")
        # Only list vectors with traffic, or ones we deliberately pinned
        if [ "${_cnt:-0}" -gt 0 ] || [ "${_aff}" != "0-$(( NCPU - 1 ))" ]; then
            printf '%-7s %-5s %-5s %s\n' "${IFACE}-${_n}" "${_irq}" "${_aff}" "${_cnt:-0}"
        fi
    done
}

do_apply() {
    [ "$(id -u)" = "0" ] || die "must run as root"
    [ -d "/sys/class/net/${IFACE}" ] || die "no such interface: ${IFACE}"
    [ -n "$ETHTOOL" ] || die "ethtool not found"

    _cpus=$(cpu_count)
    [ "$_cpus" -ge 4 ] || die "need at least 4 CPUs to split RX and TX (have ${_cpus})"

    _nrx=$(driver_var num_rx_rings 2>/dev/null || echo 0)
    [ "$_nrx" -ge 1 ] || die "cannot read num_rx_rings; is /proc/net/r8125/${IFACE}/debug present?"

    if [ "$RX_WANT" -ge "$_cpus" ]; then
        die "rx_rings (${RX_WANT}) must be less than CPU count (${_cpus}), or no core is left for TX"
    fi
    if [ "$RX_WANT" -gt "$_nrx" ]; then
        die "rx_rings (${RX_WANT}) exceeds the driver's ${_nrx} RX rings"
    fi

    _txvec=$(tx_vectors)
    [ -n "$_txvec" ] || die "TX vector layout for HwCurrIsrVer=$(driver_var HwCurrIsrVer) is not handled"

    echo "Confining RSS to ${RX_WANT} RX rings..."
    "$ETHTOOL" -X "$IFACE" equal "$RX_WANT" || die "ethtool -X failed"

    # Active RX rings take CPUs 0..RX_WANT-1, one each.
    _n=0
    while [ "$_n" -lt "$RX_WANT" ]; do
        _irq=$(irq_of "$_n")
        if [ -n "$_irq" ]; then
            echo "$_n" > "/proc/irq/${_irq}/smp_affinity_list" 2>/dev/null \
                && echo "  ${IFACE}-${_n} (irq ${_irq}) -> cpu ${_n}"
        fi
        _n=$(( _n + 1 ))
    done

    # TX vectors take the cores the RX rings are not using.
    _cpu=$RX_WANT
    for _v in $_txvec; do
        _irq=$(irq_of "$_v")
        if [ -n "$_irq" ]; then
            echo "$_cpu" > "/proc/irq/${_irq}/smp_affinity_list" 2>/dev/null \
                && echo "  ${IFACE}-${_v} (irq ${_irq}) -> cpu ${_cpu}  [TX]"
            _cpu=$(( _cpu + 1 ))
            [ "$_cpu" -ge "$_cpus" ] && _cpu=$RX_WANT
        fi
    done

    # Park the now-unused RX vectors on the TX cores so a stray packet cannot
    # land on a core we are keeping clear for RX.
    _n=$RX_WANT
    while [ "$_n" -lt "$_nrx" ]; do
        _irq=$(irq_of "$_n")
        [ -n "$_irq" ] && echo "$(( _cpus - 1 ))" > "/proc/irq/${_irq}/smp_affinity_list" 2>/dev/null
        _n=$(( _n + 1 ))
    done

    echo ""
    show_layout
}

do_snap() {
    { vector_pairs | while read -r _irq _n; do
        _cnt=$(irq_count "${_irq}")
        echo "V ${_n} ${_cnt:-0}"
      done
      if [ -n "$ETHTOOL" ]; then
        "$ETHTOOL" -S "$IFACE" 2>/dev/null | awk '/rx_missed|rx_mac_missed/ { gsub(":","",$1); print "S", $1, $2 }'
      fi
    } > "$SNAP"
    echo "Snapshot written to ${SNAP}. Run your iperf, then: $0 diff ${IFACE}"
}

do_diff() {
    [ -r "$SNAP" ] || die "no snapshot at ${SNAP}; run '$0 snap ${IFACE}' first"

    echo "=== interrupt deltas (${IFACE}) ==="
    echo "vector  cpu   delta"
    vector_pairs | while read -r _irq _n; do
        _now=$(irq_count "${_irq}")
        _was=$(awk -v n="$_n" '$1 == "V" && $2 == n { print $3; exit }' "$SNAP")
        _d=$(( ${_now:-0} - ${_was:-0} ))
        if [ "$_d" -gt 0 ]; then
            _aff=$(cat "/proc/irq/${_irq}/smp_affinity_list" 2>/dev/null || echo "?")
            printf '%-7s %-5s %s\n' "${IFACE}-${_n}" "${_aff}" "${_d}"
        fi
    done

    echo ""
    echo "=== NIC drop counters ==="
    if [ -n "$ETHTOOL" ]; then
        "$ETHTOOL" -S "$IFACE" 2>/dev/null | awk '/rx_missed|rx_mac_missed/ { gsub(":","",$1); print $1, $2 }' | \
        while read -r _k _now; do
            _was=$(awk -v k="$_k" '$1 == "S" && $2 == k { print $3; exit }' "$SNAP")
            printf '%-16s %s (was %s, delta %s)\n' "$_k" "$_now" "${_was:-0}" "$(( _now - ${_was:-0} ))"
        done
    fi

    echo ""
    echo "Want: RX and TX deltas on DIFFERENT cpu numbers, and rx_missed delta 0."
}

case "$CMD" in
    apply) do_apply ;;
    show)  show_layout ;;
    snap)  do_snap ;;
    diff)  do_diff ;;
    *)     echo "usage: $0 [apply|show|snap|diff] [interface] [rx_rings]" >&2; exit 1 ;;
esac
