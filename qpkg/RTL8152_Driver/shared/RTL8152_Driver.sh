#!/bin/sh
CONF=/etc/config/qpkg.conf
QPKG_NAME="RTL8152_Driver"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})
export QNAP_QPKG=$QPKG_NAME

# QTS starts QPKG services at boot with a minimal PATH. Without this, lsmod,
# insmod and rmmod are "command not found" and every step below no-ops.
PATH="/sbin:/bin:/usr/sbin:/usr/bin:${PATH}"

# Nothing captures this script's stdout on an unattended boot, so every decision
# is also written here. This file is the only record of what happened at boot.
LOG="${QPKG_ROOT:-/tmp}/service.log"
log() {
    echo "$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG}" 2>/dev/null || true
}

case "$1" in
  start)
    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        log "$QPKG_NAME is disabled."
        exit 1
    fi

    # Load driver from QPKG directory on startup
    DRIVER_PATH="${QPKG_ROOT}/r8152.ko"
    log "start: root='${QPKG_ROOT}' kernel='$(uname -r)'"

    # The QPKG lives on the data volume. If the service is started before that
    # volume is mounted there is nothing to load, and silently doing nothing here
    # is what leaves the stock driver in place for the rest of the boot.
    if [ ! -f "${DRIVER_PATH}" ]; then
        log "ERROR: ${DRIVER_PATH} does not exist - is the data volume mounted?"
        exit 1
    fi

    # A QTS firmware update can change the kernel, and this module is built
    # for one exact kernel release. Check before unloading anything: without
    # this, a kernel bump means we drop QTS's working driver, fail to insmod
    # ours, and leave the NIC with no driver at all - on every boot.
    FILE_VERMAGIC=$(strings "${DRIVER_PATH}" 2>/dev/null | grep "^vermagic=" | head -1 | cut -d= -f2-)
    RUNNING_RELEASE=$(uname -r)

    SKIP=0
    case "${FILE_VERMAGIC}" in
        "${RUNNING_RELEASE} "*)
            ;;
        "")
            # Could not read it; let insmod be the judge rather than refusing
            ;;
        *)
            SKIP=1
            ;;
    esac

    if [ "${SKIP}" = "1" ]; then
        log "$QPKG_NAME: driver was built for '${FILE_VERMAGIC}', running kernel is '${RUNNING_RELEASE}'"
        log "$QPKG_NAME: leaving the stock driver in place - rebuild the QPKG for this kernel"
        exit 1
    fi

    # srcversion is what distinguishes our module from the one QTS ships; module
    # size and /proc/modules memory footprint do not.
    WANT_SRC=$(strings "${DRIVER_PATH}" 2>/dev/null | grep "^srcversion=" | cut -d= -f2)

    if [ -n "${WANT_SRC}" ] && [ "$(cat /sys/module/r8152/srcversion 2>/dev/null)" = "${WANT_SRC}" ]; then
        log "our r8152 is already loaded (srcversion ${WANT_SRC}); leaving the link alone"
    else
        # Unload old module if loaded
        if lsmod | grep -q "^r8152 "; then
            OUT=$(rmmod r8152 2>&1) || log "ERROR: rmmod r8152 failed: ${OUT}"
        fi

        # Load driver from QPKG directory, falling back to whatever QTS ships
        # so the NIC is never left without a driver.
        log "Loading r8152 driver from QPKG directory..."
        OUT=$(insmod "${DRIVER_PATH}" 2>&1)
        if [ $? -ne 0 ]; then
            log "ERROR: insmod ${DRIVER_PATH} failed: ${OUT}"
            log "falling back to the stock driver"
            modprobe r8152 2>/dev/null || true
        fi
    fi

    LOADED_SRC=$(cat /sys/module/r8152/srcversion 2>/dev/null)
    LOADED_VER=$(cat /sys/module/r8152/version 2>/dev/null)
    if [ -n "${WANT_SRC}" ] && [ "${LOADED_SRC}" = "${WANT_SRC}" ]; then
        log "$QPKG_NAME started successfully (r8152 ${LOADED_VER} loaded)"
    elif lsmod | grep -q "^r8152 "; then
        # Reported as a failure on purpose: a loaded stock driver is the exact
        # end state this package exists to replace, so it must not read as success.
        log "$QPKG_NAME FAILED: a different r8152 is loaded (version '${LOADED_VER}', srcversion '${LOADED_SRC}'), expected srcversion '${WANT_SRC}'"
        exit 1
    else
        log "$QPKG_NAME FAILED: no r8152 driver is loaded, check dmesg"
        exit 1
    fi
    ;;

  stop)
    # Driver stays loaded as kernel module
    # Don't unload on stop to avoid network interruption
    log "$QPKG_NAME stopped (driver remains loaded)"
    ;;

  restart)
    $0 stop
    $0 start
    ;;

  remove)
    # Removal is handled by package_routines
    ;;

  *)
    echo "Usage: $0 {start|stop|restart|remove}"
    exit 1
esac

exit 0
