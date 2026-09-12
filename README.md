# USB Wakeup Configuration Tool

## Overview

The **USB Wakeup Configuration Tool** (`usb-wakeup-disable.sh`) is a system administration utility
designed to selectively disable ACPI wakeup functionality for USB devices in Linux.

It is particularly useful for preventing some USB devices (such as overly sensitive mice or
keyboards) from waking a Linux system from sleep/suspend states. The tool provides a user-friendly
Terminal User Interface (TUI) to select devices and automatically generates persistent `udev` rules
to ensure the configuration survives reboots and device replugging.

## Features

- **Interactive TUI**: Utilizes the `dialog` utility to present a clear, selectable list of
  connected USB devices.
- **Smart Defaults**: By default, only filters and displays USB HID (Human Interface Device) input
  devices, keeping the list uncluttered.
- **Safeguards**: Automatically ignores USB Hubs to prevent users from accidentally locking out an
  entire USB device tree.
- **State Persistence**: Generates and manages `udev` rules (`99-usb-wakeup-disable.rules`) to apply
  your preferences permanently.
- **Hot-Application**: Dynamically applies changes to the `/sys/bus/usb/devices/` tree immediately,
  without requiring a reboot or replug.

## Prerequisites

- **Root Privileges**: The script must be run as `root` (or via `sudo`) to modify `sysfs` and
  `/etc/udev/rules.d/`.
- **Dependencies**: 
  - `bash`
  - `dialog` (Must be installed via your distribution's package manager, e.g., `apt install dialog`,
    `dnf install dialog` or `zypper install dialog`)
  - `udev` subsystem

## Usage

Run the script with root privileges:

```bash
sudo ./usb-wakeup-disable.sh [OPTIONS]
```

### Command-Line Arguments

| Argument | Long Option | Description                                                                                                  |
| :------- | :---------- | :----------------------------------------------------------------------------------------------------------- |
| `-a`     | `--all`     | Display all connected USB devices (by default displays only HID devices - keyboards, mice).                  |
| `-r`     | `--reset`   | Delete the current configuration, remove the `udev` rules, and re-enable wakeup for all devices immediately. |
| `-h`     | `--help`    | Display the help message and exit.                                                                           |

### Using the TUI

<img width="646" height="355" alt="image" src="https://github.com/user-attachments/assets/d6539a7b-1967-44fe-b81e-952c4d18cbc2" />

1. Launch the script.
2. Use the **Up/Down Arrow** keys to navigate the list of connected devices.
3. Press **Space** to toggle the selection. Devices that are *checked* will have their wakeup
   functionality **DISABLED**.
4. Press **Enter** to save and apply the configuration.
5. Press **Esc** to cancel without making any changes.

## Architecture & Technical Details

### USB discovery

The script queries the Linux `sysfs` filesystem at `/sys/bus/usb/devices/*` to discover connected
devices, extracting metadata such as `idVendor`, `idProduct`, `serial`, `manufacturer`, and
`product`. It determines interface classes by reading `bInterfaceClass` (looking for `03` to
identify HID devices).

### Configuration generation

Selected configurations are translated into standard `udev` rules. A typical generated rule looks
like this:

```udev
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1234", ATTR{idProduct}=="5678", ATTR{serial}=="ABCDEF", ATTR{power/wakeup}="disabled"
```

These rules enforce that whenever the matching USB device is added to the system, its power wakeup
attribute is strictly disabled.

### Managed files

- **Script**: `usb-wakeup-disable.sh`
- **Configuration / Rules File**: `/etc/udev/rules.d/99-usb-wakeup-disable.rules`
