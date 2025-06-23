#!/bin/bash

# Script to generate fstab entries for ext4 and NTFS filesystems based on blkid output
# Includes user confirmation, enhanced debugging, and optional label application
# Fixes UUID extraction to exclude PARTUUID

# Check if script is run with sudo
if [ "$(id -u)" != "0" ]; then
    echo "Error: This script must be run with sudo."
    exit 1
fi

# Setup debug log
debug_log="/tmp/fstab_script_debug.log"
echo "Debug log started at $(date)" > "$debug_log"

# Store blkid output in a temporary file to avoid pipeline issues
temp_blkid=$(mktemp) || { echo "Error: Failed to create temporary blkid file"; echo "Error: Failed to create temporary blkid file" >> "$debug_log"; exit 1; }
echo "Running blkid..." >> "$debug_log"
blkid > "$temp_blkid" 2>>"$debug_log"
echo "blkid output saved to $temp_blkid" >> "$debug_log"

# Log /dev/disk/by-uuid contents
echo "Contents of /dev/disk/by-uuid:" >> "$debug_log"
ls -l /dev/disk/by-uuid >> "$debug_log" 2>&1

# Backup /etc/fstab
backup_file="/etc/fstab.bak-$(date +%F_%T)"
if [ -f /etc/fstab ]; then
    cp /etc/fstab "$backup_file"
    echo "Backed up /etc/fstab to $backup_file"
    echo "Backed up /etc/fstab to $backup_file" >> "$debug_log"
    echo "Original /etc/fstab content:" >> "$debug_log"
    cat /etc/fstab >> "$debug_log"
else
    echo "Error: /etc/fstab not found!"
    echo "Error: /etc/fstab not found!" >> "$debug_log"
    exit 1
fi

# Create temporary file to store new fstab entries
temp_fstab=$(mktemp) || { echo "Error: Failed to create temporary file"; echo "Error: Failed to create temporary file" >> "$debug_log"; exit 1; }
echo "Created temporary file: $temp_fstab" >> "$debug_log"

# Read blkid output from temporary file
while IFS= read -r line; do
    echo "Processing line: $line" >> "$debug_log"
    # Check if the line contains TYPE="ext4" or TYPE="ntfs"
    if [[ $line == *TYPE=\"ext4\"* ]] || [[ $line == *TYPE=\"ntfs\"* ]]; then
        echo "Matched ext4 or NTFS: $line" >> "$debug_log"
        # Extract UUID (exclude PARTUUID), device, and filesystem type
        uuid=$(echo "$line" | grep -oP '(?<!PART)UUID="\K[^"]+')
        if [ -z "$uuid" ]; then
            echo "Warning: No UUID found in line: $line"
            echo "Warning: No UUID found in $line" >> "$debug_log"
            continue
        fi
        device=$(echo "$line" | cut -d: -f1)
        fs_type=$(echo "$line" | grep -oP 'TYPE="\K[^"]+')
        echo "Extracted: device=$device, uuid=$uuid, fs_type=$fs_type" >> "$debug_log"
        printf "UUID hex: " >> "$debug_log"
        echo -n "$uuid" | od -An -tx1 >> "$debug_log"

        # Verify device exists
        if [ ! -b "$device" ]; then
            echo "Warning: Device $device not found, skipping"
            echo "Warning: Device $device not found" >> "$debug_log"
            continue
        fi

        # Check UUID in /dev/disk/by-uuid (warn but don't skip)
        if [ ! -e "/dev/disk/by-uuid/$uuid" ]; then
            echo "Warning: UUID=$uuid not found in /dev/disk/by-uuid, proceeding anyway"
            echo "Warning: UUID=$uuid not found in /dev/disk/by-uuid, proceeding anyway" >> "$debug_log"
        fi

        # Extract LABEL (avoid PARTLABEL, remove whitespace and control chars)
        label=$(echo "$line" | grep -oP '(?<!PART)LABEL="\K[^"]+' | tr -d '[:space:]\n\r')
        if [ -z "$label" ]; then
            label="None"
        fi
        echo "Extracted raw label: '$label'" >> "$debug_log"
        printf "Extracted label hex: " >> "$debug_log"
        echo -n "$label" | od -An -tx1 >> "$debug_log"

        # Display drive details and prompt for confirmation
        echo "Found drive:"
        echo "  Device: $device"
        echo "  UUID: $uuid"
        echo "  Filesystem: $fs_type"
        echo "  Label: $label"
        read -p "Add this drive to /etc/fstab? (Y/N): " confirm </dev/tty
        echo "User input: '$confirm' (length=${#confirm})" >> "$debug_log"
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Skipping $device (UUID=$uuid) due to user choice"
            echo "Skipped $device (UUID=$uuid) due to user choice" >> "$debug_log"
            continue
        fi

        # Check if UUID already exists in /etc/fstab
        if grep -q "$uuid" /etc/fstab; then
            echo "Warning: UUID=$uuid already exists in /etc/fstab."
            echo "Warning: UUID=$uuid already exists in /etc/fstab." >> "$debug_log"
            read -p "Overwrite existing entry? (Y/N): " overwrite </dev/tty
            echo "Overwrite input: '$overwrite' (length=${#overwrite})" >> "$debug_log"
            if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
                echo "Skipping $device (UUID=$uuid) due to existing fstab entry"
                echo "Skipped $device (UUID=$uuid) due to existing fstab entry" >> "$debug_log"
                continue
            fi
        fi

        # Determine filesystem type and set mount options
        if [ "$fs_type" == "ext4" ]; then
            mount_options="defaults"
            dump_pass="0 2"
        else
            mount_options="defaults,uid=1000,gid=1000"
            dump_pass="0 0"
        fi
        echo "Mount options: $mount_options, dump_pass: $dump_pass" >> "$debug_log"

        # Prompt for mount point name (use label if available, or ask)
        mount_name="$label"
        if [ "$mount_name" == "None" ]; then
            echo "No LABEL found for $device (UUID=$uuid, type=$fs_type)."
            read -p "Enter a name for the mount point (e.g., Data): " mount_name </dev/tty
            while [ -z "$mount_name" ]; do
                echo "Mount point name cannot be empty."
                read -p "Enter a name for the mount point (e.g., Data): " mount_name </dev/tty
            done
        fi
        echo "Raw mount point name: '$mount_name'" >> "$debug_log"
        printf "Raw mount name hex: " >> "$debug_log"
        echo -n "$mount_name" | od -An -tx1 >> "$debug_log"

        # Sanitize mount point name (replace spaces with underscores, keep alphanumeric)
        mount_name=$(echo "$mount_name" | sed 's/[[:space:]]\+/_/g' | tr -dc '[:alnum:]_')
        echo "Sanitized mount point name: '$mount_name'" >> "$debug_log"
        printf "Sanitized mount name hex: " >> "$debug_log"
        echo -n "$mount_name" | od -An -tx1 >> "$debug_log"

        # Define mount point
        mount_point="/mnt/$mount_name"
        echo "Mount point: '$mount_point'" >> "$debug_log"
        printf "Mount point hex: " >> "$debug_log"
        echo -n "$mount_point" | od -An -tx1 >> "$debug_log"

        # Validate mount_name (alphanumeric and underscore only)
        if [[ "$mount_name" =~ ^[[:alnum:]_]+$ ]]; then
            echo "Mount name validation passed: '$mount_name'" >> "$debug_log"
        else
            echo "Error: Invalid mount name '$mount_name' for $device (UUID=$uuid)"
            echo "Error: Invalid mount name '$mount_name'" >> "$debug_log"
            continue
        fi

        # Create mount point if it doesn't exist
        if [ ! -d "$mount_point" ]; then
            mkdir -p "$mount_point" || { echo "Error: Failed to create $mount_point"; echo "Error: Failed to create $mount_point" >> "$debug_log"; continue; }
            echo "Created mount point $mount_point"
            echo "Created mount point $mount_point" >> "$debug_log"
        fi

        # Prompt to apply label to filesystem (ext4 only, if different from current label)
        if [ "$fs_type" == "ext4" ] && [ "$mount_name" != "$label" ] && command -v e2label >/dev/null 2>&1; then
            read -p "Apply '$mount_name' as the filesystem label for $device? (Y/N): " apply_label </dev/tty
            echo "Apply label input: '$apply_label' (length=${#apply_label})" >> "$debug_log"
            if [[ "$apply_label" =~ ^[Yy]$ ]]; then
                if e2label "$device" "$mount_name"; then
                    echo "Applied label '$mount_name' to $device"
                    echo "Applied label '$mount_name' to $device" >> "$debug_log"
                else
                    echo "Warning: Failed to apply label '$mount_name' to $device"
                    echo "Warning: Failed to apply label '$mount_name' to $device" >> "$debug_log"
                fi
            else
                echo "Not applying label to $device; using '$mount_name' for mount point only"
                echo "Not applying label; using '$mount_name' for mount point" >> "$debug_log"
            fi
        elif [ "$fs_type" == "ntfs" ]; then
            echo "Note: NTFS label not applied (requires ntfslabel, not attempted)."
            echo "Note: NTFS label not applied for $device" >> "$debug_log"
        fi

        # Create fstab entry
        fstab_entry="UUID=$uuid $mount_point $fs_type $mount_options $dump_pass"
        echo "$fstab_entry" >> "$temp_fstab"
        echo "Generated fstab entry: '$fstab_entry'" >> "$debug_log"
        printf "fstab entry hex: " >> "$debug_log"
        echo -n "$fstab_entry" | od -An -tx1 >> "$debug_log"

        # Validate fstab entry (check for 6 fields)
        field_count=$(echo "$fstab_entry" | awk '{print NF}')
        if [ "$field_count" -ne 6 ]; then
            echo "Warning: Invalid fstab entry for $device (UUID=$uuid): $fstab_entry (field count: $field_count)"
            echo "Warning: Invalid fstab entry: $fstab_entry (field count: $field_count)" >> "$debug_log"
            continue
        fi
    else
        echo "Line did not match ext4 or NTFS: $line" >> "$debug_log"
    fi
done < "$temp_blkid"

# Clean up temporary blkid file
rm -f "$temp_blkid"
echo "Removed temp blkid file: $temp_blkid" >> "$debug_log"

# Check if any entries were generated
if [ ! -s "$temp_fstab" ]; then
    echo "No ext4 or NTFS filesystems found or no new entries generated."
    echo "No ext4 or NTFS filesystems found or no new entries generated." >> "$debug_log"
    echo "Check $debug_log for details."
    rm -f "$temp_fstab"
    exit 0
fi

# Append new entries to /etc/fstab
echo "New fstab entries to append:" >> "$debug_log"
cat "$temp_fstab" >> "$debug_log"
if cat "$temp_fstab" >> /etc/fstab; then
    echo "Appended new entries to /etc/fstab"
    echo "Appended new entries to /etc/fstab" >> "$debug_log"
    echo "Updated /etc/fstab content:" >> "$debug_log"
    cat /etc/fstab >> "$debug_log"
else
    echo "Error: Failed to append to /etc/fstab"
    echo "Error: Failed to append to /etc/fstab" >> "$debug_log"
    rm -f "$temp_fstab"
    exit 1
fi

# Clean up temporary file
rm -f "$temp_fstab"
echo "Removed temp file: $temp_fstab" >> "$debug_log"

# Test fstab configuration
echo "Testing new fstab configuration..."
echo "Running mount -a..." >> "$debug_log"
if mount -a 2>>"$debug_log"; then
    echo "Success: fstab configuration tested OK."
    echo "Success: fstab configuration tested OK." >> "$debug_log"
else
    echo "Error: Invalid fstab configuration detected. Restoring backup."
    echo "Error: Invalid fstab configuration detected. Restoring backup." >> "$debug_log"
    if cp "$backup_file" /etc/fstab; then
        echo "Backup restored successfully."
        echo "Backup restored successfully." >> "$debug_log"
        echo "Restored /etc/fstab content:" >> "$debug_log"
        cat /etc/fstab >> "$debug_log"
    else
        echo "Error: Failed to restore backup"
        echo "Error: Failed to restore backup" >> "$debug_log"
        exit 1
    fi
    exit 1
fi

echo "Done! Please reboot to confirm automatic mounting."
echo "Script completed successfully." >> "$debug_log"
