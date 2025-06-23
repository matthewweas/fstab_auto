#!/bin/bash

# Script to generate fstab entries for ext4 and NTFS filesystems based on blkid output
# Includes user confirmation for each compatible drive

# Check if script is run with sudo
if [ "$(id -u)" != "0" ]; then
    echo "Error: This script must be run with sudo."
    exit 1
fi

# Backup /etc/fstab
backup_file="/etc/fstab.bak-$(date +%F_%T)"
if [ -f /etc/fstab ]; then
    cp /etc/fstab "$backup_file"
    echo "Backed up /etc/fstab to $backup_file"
else
    echo "Error: /etc/fstab not found!"
    exit 1
fi

# Create temporary file to store new fstab entries
temp_fstab=$(mktemp) || { echo "Error: Failed to create temporary file"; exit 1; }

# Read blkid output line by line
while IFS= read -r line; do
    # Check if the line contains TYPE="ext4" or TYPE="ntfs"
    if [[ $line == *TYPE=\"ext4\"* ]] || [[ $line == *TYPE=\"ntfs\"* ]]; then
        # Extract UUID, device, and filesystem type
        uuid=$(echo "$line" | grep -oP 'UUID="\K[^"]+')
        if [ -z "$uuid" ]; then
            echo "Warning: No UUID found in line: $line"
            continue
        fi
        device=$(echo "$line" | cut -d: -f1)
        fs_type=$(echo "$line" | grep -oP 'TYPE="\K[^"]+')

        # Extract LABEL if it exists
        label=$(echo "$line" | grep -oP 'LABEL="\K[^"]+')
        if [ -z "$label" ]; then
            label="None"
        fi

        # Display drive details and prompt for confirmation
        echo "Found drive:"
        echo "  Device: $device"
        echo "  UUID: $uuid"
        echo "  Filesystem: $fs_type"
        echo "  Label: $label"
        read -p "Add this drive to /etc/fstab? (Y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Skipping $device (UUID=$uuid)"
            continue
        fi

        # Determine filesystem type and set mount options
        if [ "$fs_type" == "ext4" ]; then
            mount_options="defaults"
            dump_pass="0 2"
        else
            mount_options="defaults,uid=1000,gid=1000"
            dump_pass="0 0"
        fi

        # Prompt for label if none exists
        if [ "$label" == "None" ]; then
            echo "No LABEL found for $device (UUID=$uuid, type=$fs_type)."
            read -p "Enter a LABEL for this $fs_type filesystem: " label
            while [ -z "$label" ]; do
                echo "LABEL cannot be empty."
                read -p "Enter a LABEL for this $fs_type filesystem: " label
            done

            # Sanitize label (replace spaces with underscores, keep alphanumeric)
            label=$(echo "$label" | tr '[:space:]' '_' | tr -dc '[:alnum:]_')

            # Apply label for ext4 only (if e2label is available)
            if [ "$fs_type" == "ext4" ] && command -v e2label >/dev/null 2>&1; then
                if e2label "$device" "$label"; then
                    echo "Applied label '$label' to $device"
                else
                    echo "Warning: Failed to apply label '$label' to $device"
                fi
            elif [ "$fs_type" == "ntfs" ]; then
                echo "Note: NTFS label not applied (requires ntfslabel, not attempted)."
            fi
        fi

        # Define mount point
        mount_point="/mnt/$label"

        # Create mount point if it doesn't exist
        if [ ! -d "$mount_point" ]; then
            mkdir -p "$mount_point" || { echo "Error: Failed to create $mount_point"; continue; }
            echo "Created mount point $mount_point"
        fi

        # Check if UUID already exists in /etc/fstab
        if grep -q "$uuid" /etc/fstab; then
            echo "Warning: UUID=$uuid already exists in /etc/fstab, skipping."
            continue
        fi

        # Create fstab entry
        echo "UUID=$uuid $mount_point $fs_type $mount_options $dump_pass" >> "$temp_fstab"
        echo "Generated fstab entry: UUID=$uuid $mount_point $fs_type $mount_options $dump_pass"
    fi
done < <(blkid)

# Check if any entries were generated
if [ ! -s "$temp_fstab" ]; then
    echo "No ext4 or NTFS filesystems found or no new entries generated."
    rm -f "$temp_fstab"
    exit 0
fi

# Append new entries to /etc/fstab
if cat "$temp_fstab" >> /etc/fstab; then
    echo "Appended new entries to /etc/fstab"
else
    echo "Error: Failed to append to /etc/fstab"
    rm -f "$temp_fstab"
    exit 1
fi

# Clean up temporary file
rm -f "$temp_fstab"

# Test fstab configuration
echo "Testing new fstab configuration..."
if mount -a 2>/dev/null; then
    echo "Success: fstab configuration tested OK."
else
    echo "Error: Invalid fstab configuration detected. Restoring backup."
    if cp "$backup_file" /etc/fstab; then
        echo "Backup restored successfully."
    else
        echo "Error: Failed to restore backup"
        exit 1
    fi
    exit 1
fi

echo "Done! Please reboot to confirm automatic mounting."
