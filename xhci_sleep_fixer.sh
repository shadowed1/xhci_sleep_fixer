#!/bin/bash
# Created by shadowed1
XHCI="0000:00:14.0"
XHCI_DRIVER="/sys/bus/pci/drivers/xhci_hcd"
USB4="/sys/bus/usb/devices/usb4"
POLL_INTERVAL=2
STUCK_TIME=4
STUCK_COUNT=0
LAST_LID=""
LOG_FILE="/var/log/xhci_sleep_fixer.log"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log()
{
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

is_lid_closed()
{
    for state in /proc/acpi/button/lid/*/state; do
        [ -f "$state" ] || continue
        if grep -qi 'closed' "$state"; then
            return 0
        fi
    done

    return 1
}

is_xhci_bound()
{
    [ -e "/sys/bus/pci/devices/$XHCI/driver" ]
}

usb4_is_stuck()
{
    [ -f "$USB4/power/runtime_status" ] || return 1
    [ "$(cat "$USB4/power/runtime_status" 2>/dev/null)" = "suspending" ]
}

unbind_xhci()
{
    log "Unbinding xHCI $XHCI"
    echo "$XHCI" > "$XHCI_DRIVER/unbind" 2>/dev/null
    sleep 1
    log "Rebinding xHCI $XHCI"
    echo "$XHCI" > "$XHCI_DRIVER/bind" 2>/dev/null
    sleep 1
    log "Unbinding xHCI $XHCI for sleep"
    echo "$XHCI" > "$XHCI_DRIVER/unbind" 2>/dev/null
    STUCK_COUNT=0
}

bind_xhci()
{
    log "Binding xHCI $XHCI"
    echo "$XHCI" > "$XHCI_DRIVER/bind" 2>/dev/null
    sleep 1
    log "Rescanning PCI bus"
    echo 1 > /sys/bus/pci/rescan 2>/dev/null
    STUCK_COUNT=0
}

while true; do
    if is_lid_closed; then
        LID="closed"
    else
        LID="open"
    fi
    if [ "$LID" != "$LAST_LID" ]; then
        log "Lid state changed: $LAST_LID -> $LID"
        LAST_LID="$LID"
        if [ "$LID" = "closed" ]; then
            if is_xhci_bound; then
                sleep 1
                if usb4_is_stuck; then
                    log "usb4 stuck suspending on lid close"
                    unbind_xhci
                fi
            fi
        else
            if ! is_xhci_bound; then
                bind_xhci
            fi
        fi
    fi
    if [ "$LID" = "closed" ]; then
        if ! is_xhci_bound; then
            STUCK_COUNT=0
            sleep "$POLL_INTERVAL"
            continue
        fi
        if usb4_is_stuck; then
            STUCK_COUNT=$((STUCK_COUNT + POLL_INTERVAL))
            if [ "$STUCK_COUNT" -ge "$STUCK_TIME" ]; then
                log "usb4 stuck suspending for ${STUCK_COUNT}s"
                unbind_xhci
            fi
        else
            STUCK_COUNT=0
        fi  
    else
        if ! is_xhci_bound; then
            bind_xhci
        fi
        STUCK_COUNT=0
    fi
    sleep "$POLL_INTERVAL"
done
