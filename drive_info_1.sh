#!/bin/bash
#
# Squidnoses's Disk Analyzer
# --------------------------
# A simple interactive disk information utility for Linux.
# Provides SMART data, NVMe PCIe link details, SATA stats, and general drive info.
#

clear
echo -e "\e[31m=== Squidnoses's Disk Analyzer ===\e[0m"
echo -e "\e[31mI recommend running this with sudo\e[0m"
echo -e "\e[31mRequires smartctl (from smartmontools)\e[0m"

# =======================================================
# Helper Functions
# =======================================================

# Convert bytes into human-readable GB/TB with raw included
bytes_to_human() {
  local bytes=$1
  if [[ -z $bytes || $bytes -eq 0 ]]; then
    echo "0 B"
    return
  fi

  local kib=$((1024))
  local mib=$((1024 * 1024))
  local gib=$((1024 * 1024 * 1024))
  local tib=$((1024 * 1024 * 1024 * 1024))

  if (( bytes >= tib )); then
    printf "%.2f TB (%s bytes)\n" "$(echo "$bytes / $tib" | bc -l)" "$bytes"
  elif (( bytes >= gib )); then
    printf "%.2f GB (%s bytes)\n" "$(echo "$bytes / $gib" | bc -l)" "$bytes"
  elif (( bytes >= mib )); then
    printf "%.2f MB (%s bytes)\n" "$(echo "$bytes / $mib" | bc -l)" "$bytes"
  else
    printf "%.2f KB (%s bytes)\n" "$(echo "$bytes / $kib" | bc -l)" "$bytes"
  fi
}

show_partitions() {
  local disk=$1
  echo -e "\e[31mPartitions:\e[0m"

  # Show tree of partitions with mount points
  lsblk -n -r -o NAME,MOUNTPOINT "$disk" | while read -r name mount; do
    devpath="/dev/$name"
    if [[ $name == $(basename "$disk") ]]; then
      # Disk itself
      printf "%s\n" "$devpath"
    else
      # Partitions (indented, with ├─ or └─ depending on position)
      last=$(lsblk -n -r -o NAME "$disk" | tail -n1)
      if [[ $name == $last ]]; then
        printf " └─%-12s | %s\n" "$devpath" "${mount:-unmounted}"
      else
        printf " ├─%-12s | %s\n" "$devpath" "${mount:-unmounted}"
      fi
    fi
  done

  # Partition table type (use lsblk first, fallback to parted)
  table_type=$(lsblk -no PTTYPE "$disk" 2>/dev/null | head -n1)
  if [[ -z $table_type ]] && command -v parted &>/dev/null; then
    table_type=$(sudo parted -s "$disk" print 2>/dev/null | grep "Partition Table:" | awk '{print $3}')
  fi

  if [[ -n $table_type ]]; then
    echo "Partition Table Type:               $table_type"
  else
    echo "Partition Table Type:               Unknown"
  fi
}




# =======================================================
# Check for smartctl availability
# =======================================================
if ! command -v smartctl &>/dev/null; then
  echo -e "\e[31mError: smartctl command not found. Please install smartmontools.\e[0m"
  exit 1
fi

# =======================================================
# Get list of available disks
# =======================================================
disks=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}')
disk_array=($disks)

if [ ${#disk_array[@]} -eq 0 ]; then
  echo -e "\e[31mNo disks detected. Ensure drives are connected and visible.\e[0m"
  exit 1
fi

# =======================================================
# User chooses a disk
# =======================================================
echo -e "\e[31mChoose your disk from the list:\e[0m"
for i in "${!disk_array[@]}"; do
  echo "$((i+1))) - ${disk_array[$i]}"
done

read -p "Enter the number of the disk: " disk_num

if [[ ! $disk_num =~ ^[0-9]+$ ]] || [[ $disk_num -lt 1 || $disk_num -gt ${#disk_array[@]} ]]; then
  echo -e "\e[31mInvalid input.\e[0m"
  exit 1
fi

DISK=${disk_array[$((disk_num-1))]}

clear
echo -e "\e[31m=== Disk Information for $DISK ===\e[0m"

# =======================================================
# Show partitions and table type
# =======================================================
show_partitions "$DISK"

# =======================================================
# Verify SMART support
# =======================================================
if ! sudo smartctl -i "$DISK" &>/dev/null; then
  echo -e "\e[31mSMART is not supported or not accessible for $DISK.\e[0m"
  exit 1
fi

# =======================================================
# Disk health and temperature
# =======================================================
echo -e "\e[31mDisk State:\e[0m"
smart_overall=$(sudo smartctl -H "$DISK" | grep "SMART overall-health self-assessment test result:" || echo "Health info not available.")
echo "$smart_overall"
sudo smartctl -a "$DISK" | grep "Temperature:"

# =======================================================
# Determine interface (NVMe or SATA)
# =======================================================
if [[ $DISK == /dev/nvme* ]]; then
  interface="NVMe"

  # PCIe link info from sysfs
  pcie_device_path=$(readlink -f /sys/class/block/$(basename "$DISK")/device/device)
  if [[ -d "$pcie_device_path" ]]; then
    current_speed=$(<"$pcie_device_path/current_link_speed")
    current_width=$(<"$pcie_device_path/current_link_width")
    max_speed=$(<"$pcie_device_path/max_link_speed")
    max_width=$(<"$pcie_device_path/max_link_width")
    link_speed="Current: PCIe ${current_speed:-Unknown} x${current_width:-Unknown}, Max: PCIe ${max_speed:-Unknown} x${max_width:-Unknown}"
  else
    link_speed="Unknown"
  fi

else
  interface="SATA"
  link_speed=$(sudo smartctl -i "$DISK" | grep "SATA Version is" | awk -F: '{print $2}' | xargs)
fi

# =======================================================
# Print interface info
# =======================================================
echo "Interface:                          ${interface:-Unknown}"
echo "Link Speed:                         ${link_speed:-Unknown}"

# =======================================================
# NVMe-specific information
# =======================================================
if [[ $interface == "NVMe" ]]; then
  echo -e "\e[31m=== NVMe-Specific Data ===\e[0m"
  sudo smartctl -x "$DISK" | grep -E "Data Units Read|Data Units Written|Power Cycles|Power On Hours|Namespace 1 Size|NVMe Version" || echo "No NVMe-specific stats available."

# =======================================================
# SATA-specific information
# =======================================================
else
  echo -e "\e[31m=== SATA-Specific Data ===\e[0m"

  # Extract SMART attributes by ID (common across most drives)
  lba_written=$(sudo smartctl -A "$DISK" | awk '/241/ {print $10}')
  lba_read=$(sudo smartctl -A "$DISK" | awk '/242/ {print $10}')
  power_on_hours=$(sudo smartctl -A "$DISK" | awk '/  9 / {print $10}')
  power_cycles=$(sudo smartctl -A "$DISK" | awk '/ 12 / {print $10}')
  reallocated_sectors=$(sudo smartctl -A "$DISK" | awk '/  5 / {print $10}')

  # Convert LBAs → Bytes (assuming 512 bytes per LBA)
  if [[ -n $lba_read ]]; then
    bytes_read=$((lba_read * 512))
    echo -e "Data Units Read:                    $lba_read LBAs → $(bytes_to_human $bytes_read)"
  fi
  if [[ -n $lba_written ]]; then
    bytes_written=$((lba_written * 512))
    echo -e "Data Units Written:                 $lba_written LBAs → $(bytes_to_human $bytes_written)"
  fi

  echo "Power On Hours:                     ${power_on_hours:-Not available} hours"
  echo "Power Cycles:                       ${power_cycles:-Not available}"
  echo "Reallocated Sectors:                ${reallocated_sectors:-0}"
fi

# =======================================================
# HDD-specific info: rotation speed + cache size
# =======================================================
rotation_speed=$(sudo smartctl -i "$DISK" | grep "Rotation Rate" | awk -F: '{print $2}' | xargs)
cache_size=$(sudo smartctl -i "$DISK" | grep "Cache Size" | awk -F: '{print $2}' | xargs)

echo "Rotation Speed:                     ${rotation_speed:-Not applicable (SSD)}"
echo "Cache Size:                         ${cache_size:-Not available}"

# =======================================================
# Basic drive info
# =======================================================
echo -e "\e[31mBasic Info:\e[0m"
sudo smartctl -i "$DISK" | grep -E "Model Number|Serial Number|Firmware Version|Capacity" || echo "Basic info not available."

# =======================================================
# More detailed info
# =======================================================
echo -e "\e[31mMore Info:\e[0m"
if [[ $interface == "NVMe" ]]; then
  sudo smartctl -x "$DISK" | grep -E "Available Spare|Available Spare Threshold|Unsafe Shutdowns|Media and Data Integrity Errors" || echo "No additional NVMe info available."
else
  sudo smartctl -A "$DISK" | grep -E "Current_Pending_Sector|Offline_Uncorrectable" || echo "No additional SATA info available."
fi

# =======================================================
# Footer
# =======================================================
echo -e "\e[31mIf you see nothing above, it could be:\e[0m"
echo -e "\e[31m- Your drive does not support SMART\e[0m"
echo -e "\e[31m- Your USB adapter does not support SMART\e[0m"
echo -e "\e[31m- Permissions error (try running with sudo)\e[0m"
echo -e "\e[32mPress any key to exit...\e[0m"
read -n 1 -s
