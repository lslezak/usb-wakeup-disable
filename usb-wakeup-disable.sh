#!/bin/bash

# USB Wakeup Configuration Tool
# Generates udev rules to disable ACPI wakeup for selected USB devices.

set -e

UDEV_FILE="/etc/udev/rules.d/99-usb-wakeup-disable.rules"

# 1. Parse Arguments
SHOW_ALL=0
RESET_ALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--all)
            SHOW_ALL=1
            shift
            ;;
        -r|--reset)
            RESET_ALL=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-a | --all] [-r | --reset]"
            echo "  -a, --all    Show all USB devices (defaults to HID input devices only)"
            echo "  -r, --reset  Delete configuration and re-enable wakeup for all devices"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [-a | --all] [-r | --reset]" >&2
            exit 1
            ;;
    esac
done

# 2. Pre-flight checks
if [[ $EUID -ne 0 ]]; then
    echo "Error: This tool must be run as root." >&2
    exit 1
fi

# 3. Handle Reset Request
if [[ $RESET_ALL -eq 1 ]]; then
    echo "Resetting USB wakeup configuration..."

    if [[ -f "$UDEV_FILE" ]]; then
        rm -f "$UDEV_FILE"
        echo "Removed $UDEV_FILE"
    fi

    for dev in /sys/bus/usb/devices/*; do
        if [[ -w "$dev/power/wakeup" ]]; then
            echo "enabled" > "$dev/power/wakeup" 2>/dev/null || true
        fi
    done

    udevadm control --reload-rules

    echo "Wakeup functionality has been re-enabled for all USB devices."
    exit 0
fi

if ! command -v dialog >/dev/null 2>&1; then
    echo "Error: 'dialog' utility is not installed." >&2
    exit 1
fi

# 4. Load existing configuration from the udev rules file
declare -A current_config
if [[ -f "$UDEV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

        vid=""
        pid=""
        serial=""

        [[ "$line" =~ ATTR\{idVendor\}==\"([^\"]+)\" ]] && vid="${BASH_REMATCH[1]}"
        [[ "$line" =~ ATTR\{idProduct\}==\"([^\"]+)\" ]] && pid="${BASH_REMATCH[1]}"
        [[ "$line" =~ ATTR\{serial\}==\"([^\"]+)\" ]] && serial="${BASH_REMATCH[1]}"

        # Normalize dummy serial numbers
        [[ "$serial" == "0" ]] && serial=""

        if [[ -n "$vid" && -n "$pid" ]]; then
            tag="${vid}:${pid}:${serial}"
            current_config["$tag"]=1
        fi
    done < "$UDEV_FILE"
fi

# 5. Discover connected USB devices
declare -A seen_devices
declare -A device_descs
dialog_args=()

for dev in /sys/bus/usb/devices/*; do
    [[ -f "$dev/idVendor" ]] || continue

    class=$(cat "$dev/bDeviceClass" 2>/dev/null || true)

    # Skip USB Hubs to prevent locking out entire device tree
    [[ "$class" == "09" ]] && continue

    vid=$(cat "$dev/idVendor" 2>/dev/null || true)
    pid=$(cat "$dev/idProduct" 2>/dev/null || true)
    serial=$(cat "$dev/serial" 2>/dev/null || true)
    manufacturer=$(cat "$dev/manufacturer" 2>/dev/null || true)
    product=$(cat "$dev/product" 2>/dev/null || true)

    # Normalize dummy serial numbers
    [[ "$serial" == "0" ]] && serial=""

    tag="${vid}:${pid}"
    [[ -n "$serial" ]] && tag+=" (SN: ${serial})"

    # Deduplicate identical devices missing serial numbers
    if [[ -n "${seen_devices[$tag]}" ]]; then
        continue
    fi
    seen_devices["$tag"]=1

    status="off"
    is_configured=0
    if [[ -n "${current_config[$tag]}" ]]; then
        status="on"
        is_configured=1
    fi

    show_device=0
    if [[ $SHOW_ALL -eq 1 || $is_configured -eq 1 ]]; then
        show_device=1
    else
        if grep -q -x '03' "$dev"/*/bInterfaceClass 2>/dev/null; then
            show_device=1
        fi
    fi

    [[ $show_device -eq 0 ]] && continue

    desc="${manufacturer} ${product}"
    [[ -z "${desc// /}" ]] && desc="Unknown Device"

    device_descs["$tag"]="$desc"
    dialog_args+=("$tag" "$desc" "$status")
done

if [[ ${#dialog_args[@]} -eq 0 ]]; then
    if [[ $SHOW_ALL -eq 0 ]]; then
        echo "No configurable USB HID input devices found. Try running with --all"
    else
        echo "No configurable USB devices found."
    fi
    exit 0
fi

# 6. Calculate dynamic dialog dimensions
term_lines=$(tput lines 2>/dev/null || echo 24)
term_cols=$(tput cols 2>/dev/null || echo 80)

width=$(( term_cols * 9 / 10 ))
[[ $width -lt 80 ]] && width=80
[[ $width -gt 120 ]] && width=120
[[ $term_cols -lt $width ]] && width=$(( term_cols - 2 ))

num_items=$(( ${#dialog_args[@]} / 3 ))
height=$(( num_items + 9 ))
max_height=$(( term_lines - 4 ))

[[ $height -gt $max_height ]] && height=$max_height
[[ $height -lt 20 ]] && height=20
[[ $term_lines -lt $height ]] && height=$(( term_lines - 2 ))

list_height=$(( height - 8 ))

# 7. Display TUI
choices_raw=$(dialog --clear \
    --backtitle "System Administration" \
    --title "USB Wakeup Configuration" \
    --separate-output \
    --checklist "Select devices to DISABLE wakeup functionality:\n[Space] Toggle  [Enter] Save  [Esc] Cancel" \
    "$height" "$width" "$list_height" \
    "${dialog_args[@]}" 2>&1 >/dev/tty) || exit_status=$?

clear

# Handle Cancel/Esc
if [[ $exit_status -ne 0 ]]; then
    echo "Configuration aborted. No changes made."
    exit 0
fi

# 8. Apply changes and generate rules
echo "Applying configuration..."

# Re-enable wakeup for previously configured devices, so un-checked devices are restored
for dev in /sys/bus/usb/devices/*; do
    if [[ -f "$dev/idVendor" && -w "$dev/power/wakeup" ]]; then
        cvid=$(cat "$dev/idVendor" 2>/dev/null || true)
        cpid=$(cat "$dev/idProduct" 2>/dev/null || true)
        cser=$(cat "$dev/serial" 2>/dev/null || true)

        # Normalize dummy serial numbers for active parsing
        [[ "$cser" == "0" ]] && cser=""

        if [[ -n "${current_config[${cvid}:${cpid}:${cser}]}" || -n "${current_config[${cvid}:${cpid}:]}" ]]; then
            echo "enabled" > "$dev/power/wakeup" 2>/dev/null || true
        fi
    fi
done

# If no devices are configured then just delete the current config
if [[ -z "$choices_raw" ]]; then
    if [[ -f "$UDEV_FILE" ]]; then
        rm -f "$UDEV_FILE"
        echo "Removed $UDEV_FILE"
        udevadm control --reload-rules
    fi

    exit 0
fi

echo "# Auto-generated by the usb-wakeup-config tool" > "$UDEV_FILE"
echo "# Do not edit manually unless you maintain the exact syntax" >> "$UDEV_FILE"

# Parse choices (mapfile handles newlines properly)
mapfile -t choices <<< "$choices_raw"

for choice in "${choices[@]}"; do
    [[ -z "$choice" ]] && continue

    # Split VID, PID, SERIAL
    IFS=':' read -r vid pid serial <<< "$choice"

    # Generate udev rule
    rule="ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$vid\", ATTR{idProduct}==\"$pid\""
    if [[ -n "$serial" ]]; then
        rule+=", ATTR{serial}==\"$serial\""
    fi
    rule+=", ATTR{power/wakeup}=\"disabled\""

    echo >> "$UDEV_FILE"
    if [[ -n "${device_descs[$choice]}" ]]; then
        echo "# Device: ${device_descs[$choice]}" >> "$UDEV_FILE"
    fi
    echo "$rule" >> "$UDEV_FILE"

    # Disable wakeup for the currently attached configured devices
    for dev in /sys/bus/usb/devices/*; do
        if [[ -f "$dev/idVendor" ]]; then
            cvid=$(cat "$dev/idVendor" 2>/dev/null || true)
            cpid=$(cat "$dev/idProduct" 2>/dev/null || true)
            cser=$(cat "$dev/serial" 2>/dev/null || true)

            # Normalize dummy serial numbers for active parsing
            [[ "$cser" == "0" ]] && cser=""

            if [[ "$cvid" == "$vid" && "$cpid" == "$pid" ]]; then
                # If no serial was saved, apply to all matching VID:PID. Otherwise, strictly match the serial.
                if [[ -z "$serial" || "$cser" == "$serial" ]]; then
                    if [[ -w "$dev/power/wakeup" ]]; then
                        echo "Disabling wakeup for $dev"
                        echo "disabled" > "$dev/power/wakeup" 2>/dev/null || true
                    fi
                fi
            fi
        fi
    done
done

# Reload the udev rules
udevadm control --reload-rules

echo "Configuration saved to $UDEV_FILE"
