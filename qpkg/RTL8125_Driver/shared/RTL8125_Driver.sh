#!/bin/sh
CONF=/etc/config/qpkg.conf
QPKG_NAME="RTL8125_Driver"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f ${CONF})
export QNAP_QPKG=$QPKG_NAME

case "$1" in
  start)
    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        echo "$QPKG_NAME is disabled."
        exit 1
    fi

    # Load driver from QPKG directory on startup
    DRIVER_PATH="${QPKG_ROOT}/r8125.ko"

    if [ -f "${DRIVER_PATH}" ]; then
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
            echo "$QPKG_NAME: driver was built for '${FILE_VERMAGIC}', running kernel is '${RUNNING_RELEASE}'"
            echo "$QPKG_NAME: leaving the stock driver in place - rebuild the QPKG for this kernel"
        else
            # Unload old module if loaded
            if lsmod | grep -q "^r8125 "; then
                rmmod r8125 2>/dev/null || true
            fi

            # Load driver from QPKG directory, falling back to whatever QTS ships
            # so the NIC is never left without a driver.
            echo "Loading r8125 driver from QPKG directory..."
            insmod "${DRIVER_PATH}" 2>/dev/null || modprobe r8125 2>/dev/null || true
        fi
    fi

    if lsmod | grep -q "^r8125 "; then
        echo "$QPKG_NAME started successfully (driver loaded)"
    else
        echo "$QPKG_NAME started (driver load may have failed, check dmesg)"
    fi
    ;;

  stop)
    # Driver stays loaded as kernel module
    # Don't unload on stop to avoid network interruption
    echo "$QPKG_NAME stopped (driver remains loaded)"
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
