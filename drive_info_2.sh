#!/bin/bash
# Squidnoses's Disk Analyzer (consolidated)
# - fixes SATA LBA unit confusion
# - shows partition tree + mountpoints + partition table + logical block size
# - shows NVMe PCIe link info
# - sanitizes SMART parsing to avoid arithmetic errors
#
# Requires: smartctl, lsblk. parted is optional (only used as a fallback).

set -u
# ---------------------------
# Helpers
# ---------------------------
bytes_to_human() {
  local bytes=${1:-0}
  if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
    echo "Unknown"
    return
  fi
  awk -v b="$bytes" 'BEGIN{
    kib=1024; mib=kib*kib; gib=mib*kib; tib=gib*kib;
    if (b >= tib)      printf "%.2f TB (%d bytes)", b/tib, b;
    else if (b >= gib) printf "%.2f GB (%d bytes)", b/gib, b;
    else if (b >= mib) printf "%.2f MB (%d bytes)", b/mib, b;
    else if (b >= kib) printf "%.2f KB (%d bytes)", b/kib, b;
    else               printf "%d B (%d bytes)", b, b;
  }'
}

# show partitions in a tree with mountpoints, partition table type and logical block size
show_partitions() {
  local disk=$1
  echo -e "\e[31mPartitions:\e[0m"

  # tree-like partition + mountpoint listing (no header)
  lsblk -n -r -o NAME,MOUNTPOINT "$disk" | while read -r name mount; do
    devpath="/dev/$name"
    if [[ $name == $(basename "$disk") ]]; then
      printf "%s\n" "$devpath"
    else
      last=$(lsblk -n -r -o NAME "$disk" | tail -n1)
      if [[ $name == $last ]]; then
        printf " └─%-12s | %s\n" "$devpath" "${mount:-unmounted}"
      else
        printf " ├─%-12s | %s\n" "$devpath" "${mount:-unmounted}"
      fi
    fi
  done

  # Partition table type (prefer lsblk PTTYPE, fallback to parted only if lsblk empty)
  local ptype
  ptype=$(lsblk -no PTTYPE "$disk" 2>/dev/null | head -n1)
  if [[ -z $ptype && -x "$(command -v parted)" ]]; then
    # Note: parted may probe the device (can trigger automounters). Use only as fallback.
    ptype=$(sudo parted -s "$disk" print 2>/dev/null | awk -F: '/Partition Table:/ {print $2}' | xargs)
  fi
  echo "Partition Table Type:               ${ptype:-Unknown}"

  # Logical block size
  local lbsz
  lbsz=$(cat "/sys/block/$(basename "$disk")/queue/logical_block_size" 2>/dev/null || echo "")
  echo "Logical Block Size:                 ${lbsz:-Unknown} bytes"
}

# Best-guess conversion from SMART LBA count to bytes:
# - uses logical block size (lbsz) as primary conversion
# - also computes vendor-scale (512 KiB) as an alternate
# - chooses the conversion that plausibly matches disk size (prefer % of disk between 0.1% and 200%)
best_guess_bytes_from_lba() {
  local lba="${1:-}"
  local disk="${2:-}"
  local lbsz="${3:-512}"

  # fallback to global DISK if caller didn't pass disk
  if [[ -z "$disk" && -n "${DISK:-}" ]]; then
    disk="$DISK"
  fi

  # sanitize LBA
  if ! [[ "$lba" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  # get a single numeric disk size (bytes) for the device only (-d)
  local disk_bytes=0
  if [[ -n "$disk" ]]; then
    disk_bytes=$(lsblk -nb -o SIZE -d "$disk" 2>/dev/null | head -n1 || echo 0)
    disk_bytes=${disk_bytes:-0}
    disk_bytes=$(echo "$disk_bytes" | tr -cd '0-9')
    if [[ -z "$disk_bytes" ]]; then disk_bytes=0; fi
  fi

  # compute candidate totals
  local bytes_lbsz bytes_512Ki bytes_1Mi
  bytes_lbsz=$(awk -v a="$lba" -v b="$lbsz" 'BEGIN{printf "%.0f", a*b}')
  bytes_512Ki=$(awk -v a="$lba" 'BEGIN{printf "%.0f", a*524288}')
  bytes_1Mi=$(awk -v a="$lba" 'BEGIN{printf "%.0f", a*1048576}')

  # compute percent of disk if disk_bytes known
  local p_lbsz=0 p_512Ki=0 p_1Mi=0
  if [[ "$disk_bytes" -gt 0 ]]; then
    p_lbsz=$(awk -v x="$bytes_lbsz" -v d="$disk_bytes" 'BEGIN{printf "%.9f", x/d}')
    p_512Ki=$(awk -v x="$bytes_512Ki" -v d="$disk_bytes" 'BEGIN{printf "%.9f", x/d}')
    p_1Mi=$(awk -v x="$bytes_1Mi" -v d="$disk_bytes" 'BEGIN{printf "%.9f", x/d}')
  fi

  # check plausibility
  local ok_lbsz ok_512Ki ok_1Mi
  ok_lbsz=$(awk -v p="$p_lbsz" 'BEGIN{print (p>=0.001 && p<=2.0)?1:0}')
  ok_512Ki=$(awk -v p="$p_512Ki" 'BEGIN{print (p>=0.001 && p<=2.0)?1:0}')
  ok_1Mi=$(awk -v p="$p_1Mi" 'BEGIN{print (p>=0.001 && p<=2.0)?1:0}')

  local choice_bytes choice_label
  if [[ "$ok_512Ki" -eq 1 && "$ok_lbsz" -eq 0 && "$ok_1Mi" -eq 0 ]]; then
    choice_bytes="$bytes_512Ki"; choice_label="assumes 512 KiB per unit (vendor-scale)"
  elif [[ "$ok_lbsz" -eq 1 && "$ok_512Ki" -eq 0 && "$ok_1Mi" -eq 0 ]]; then
    choice_bytes="$bytes_lbsz"; choice_label="assumes logical block size (${lbsz} B)"
  elif [[ "$ok_1Mi" -eq 1 && "$ok_512Ki" -eq 0 && "$ok_lbsz" -eq 0 ]]; then
    choice_bytes="$bytes_1Mi"; choice_label="assumes 1 MiB per unit (USB-SATA quirk)"
  elif [[ "$ok_512Ki" -eq 1 && "$ok_lbsz" -eq 1 ]]; then
    # both plausible -> prefer vendor-scale (matches most SATA SSD/NVMe)
    choice_bytes="$bytes_512Ki"; choice_label="assumes 512 KiB per unit (vendor-scale)"
  elif [[ "$ok_1Mi" -eq 1 ]]; then
    choice_bytes="$bytes_1Mi"; choice_label="assumes 1 MiB per unit (USB-SATA quirk)"
  else
    choice_bytes="$bytes_512Ki"; choice_label="assumes 512 KiB per unit (vendor-scale) (fallback)"
  fi

  printf "%s||%s" "$choice_bytes" "$choice_label"
}




# ---------------------------
# Pre-flight checks
# ---------------------------
if ! command -v smartctl &>/dev/null; then
  echo -e "\e[31mError: smartctl not found. Install smartmontools.\e[0m"
  exit 1
fi

# gather disks
disks=$(lsblk -d -n -o NAME | awk '{print "/dev/"$1}')
disk_array=($disks)
if [ ${#disk_array[@]} -eq 0 ]; then
  echo -e "\e[31mNo disks found.\e[0m"
  exit 1
fi

echo -e "\e[31mChoose your disk:\e[0m"
for i in "${!disk_array[@]}"; do echo "$((i+1))) - ${disk_array[$i]}"; done
read -p "Enter number: " disk_num
if [[ ! $disk_num =~ ^[0-9]+$ ]] || (( disk_num < 1 )) || (( disk_num > ${#disk_array[@]} )); then
  echo -e "\e[31mInvalid selection.\e[0m"; exit 1
fi
DISK=${disk_array[$((disk_num-1))]}

clear
echo -e "\e[31m=== Disk Information for $DISK ===\e[0m"

# partitions + block size + pttype
show_partitions "$DISK"

# SMART availability
if ! sudo smartctl -i "$DISK" &>/dev/null; then
  echo -e "\e[31mSMART not supported or inaccessible for $DISK.\e[0m"
  exit 1
fi

echo -e "\e[31mDisk State:\e[0m"
sudo smartctl -H "$DISK" | sed -n 's/^\s*SMART overall-health self-assessment test result: */SMART overall-health: /p' || echo "Health info not available."
sudo smartctl -a "$DISK" | sed -n 's/.*Temperature:.*//p' >/dev/null 2>&1
# print temp if exists (grep used to avoid noise)
sudo smartctl -a "$DISK" | grep -i "Temperature:" || true

# Detect interface
if [[ $DISK == /dev/nvme* ]]; then
  interface="NVMe"
  pcie_device_path=$(readlink -f /sys/class/block/$(basename "$DISK")/device/device 2>/dev/null || true)
  if [[ -d "$pcie_device_path" ]]; then
    current_speed=$(cat "$pcie_device_path/current_link_speed" 2>/dev/null || echo "Unknown")
    current_width=$(cat "$pcie_device_path/current_link_width" 2>/dev/null || echo "Unknown")
    max_speed=$(cat "$pcie_device_path/max_link_speed" 2>/dev/null || echo "Unknown")
    max_width=$(cat "$pcie_device_path/max_link_width" 2>/dev/null || echo "Unknown")
    link_speed="Current: PCIe ${current_speed} x${current_width}, Max: PCIe ${max_speed} x${max_width}"
  else
    link_speed="Unknown"
  fi
else
  interface="SATA"
  smartctl_i=$(sudo smartctl -i "$DISK" 2>/dev/null || true)
  # extract the full remainder of the "SATA Version is" line (avoid truncation from extra colons)
  link_speed=$(echo "$smartctl_i" | sed -n 's/.*SATA Version is:[[:space:]]*//p' | head -n1)
  link_speed=${link_speed:-Unknown}
fi

echo "Interface:                          ${interface:-Unknown}"
echo "Link Speed:                         ${link_speed:-Unknown}"

# NVMe-specific
if [[ $interface == "NVMe" ]]; then
  echo -e "\e[31m=== NVMe-Specific Data ===\e[0m"
  sudo smartctl -x "$DISK" | grep -E "Data Units Read|Data Units Written|Power Cycles|Power On Hours|Namespace 1 Size|NVMe Version" || echo "No NVMe-specific stats."
else
  echo -e "\e[31m=== SATA-Specific Data ===\e[0m"
  smartctl_A=$(sudo smartctl -A "$DISK" 2>/dev/null || true)

  # try attribute IDs 241/242 first, fallback to textual patterns
  lba_written_raw=$(echo "$smartctl_A" | grep -E '^[[:space:]]*241[[:space:]]' | awk '{print $NF}' | head -n1 || true)
  lba_read_raw=$(echo "$smartctl_A" | grep -E '^[[:space:]]*242[[:space:]]' | awk '{print $NF}' | head -n1 || true)

  if [[ -z $lba_written_raw ]]; then
    lba_written_raw=$(echo "$smartctl_A" | grep -i -m1 -E 'Total_LBAs_Written|Total LBAs Written|Total_LBAs_Written|Data Units Written' | awk '{print $NF}' | head -n1 || true)
  fi
  if [[ -z $lba_read_raw ]]; then
    lba_read_raw=$(echo "$smartctl_A" | grep -i -m1 -E 'Total_LBAs_Read|Total LBAs Read|Total_LBAs_Read|Data Units Read' | awk '{print $NF}' | head -n1 || true)
  fi

  # sanitize numeric (strip non-digits)
  lba_written=$(echo "${lba_written_raw:-}" | tr -cd '0-9')
  lba_read=$(echo "${lba_read_raw:-}" | tr -cd '0-9')

  # logical block size
  lbsz=$(cat "/sys/block/$(basename "$DISK")/queue/logical_block_size" 2>/dev/null || echo 512)
  # get disk size in bytes (disk-only, first line), sanitize to digits only
disk_bytes=$(lsblk -nb -o SIZE -d "$disk" 2>/dev/null | head -n1 || echo 0)
disk_bytes=${disk_bytes:-0}
disk_bytes=$(echo "$disk_bytes" | tr -cd '0-9')
if [[ -z "$disk_bytes" ]]; then
  disk_bytes=0
fi


  # Print raw + one best-guess human readable line for each (less noisy)
  if [[ -n $lba_read ]]; then
    # determine best guess
    guess=$(best_guess_bytes_from_lba "$lba_read" "$lbsz")
    if [[ -n $guess ]]; then
      bytes_choice=${guess%%||*}
      label_choice=${guess##*||}
      echo "Data Units Read:                    ${lba_read} LBAs (raw)"
      echo "  - Best guess:                     $(bytes_to_human "$bytes_choice")  [${label_choice}]"
    else
      echo "Data Units Read:                    ${lba_read} LBAs (raw) - cannot interpret"
    fi
  else
    echo "Data Units Read:                    Not available"
  fi

  if [[ -n $lba_written ]]; then
    guess=$(best_guess_bytes_from_lba "$lba_written" "$DISK" "$lbsz")
    if [[ -n $guess ]]; then
      bytes_choice=${guess%%||*}
      label_choice=${guess##*||}
      echo "Data Units Written:                 ${lba_written} LBAs (raw)"
      echo "  - Best guess:                     $(bytes_to_human "$bytes_choice")  [${label_choice}]"
    else
      echo "Data Units Written:                 ${lba_written} LBAs (raw) - cannot interpret"
    fi
  else
    echo "Data Units Written:                 Not available"
  fi

  # other SATA attributes: power/time/rehomed etc.
  power_on_hours=$(echo "$smartctl_A" | awk '/[[:space:]]+9[[:space:]]/ {print $10; exit}')
  power_cycles=$(echo "$smartctl_A" | awk '/[[:space:]]+12[[:space:]]/ {print $10; exit}')
  reallocated_sectors=$(echo "$smartctl_A" | awk '/[[:space:]]+5[[:space:]]/ {print $10; exit}')

  echo "Power On Hours:                     ${power_on_hours:-Not available} hours"
  echo "Power Cycles:                       ${power_cycles:-Not available}"
  echo "Reallocated Sectors:                ${reallocated_sectors:-0}"
fi

# Extra info
rotation_speed=$(sudo smartctl -i "$DISK" 2>/dev/null | grep -i "Rotation Rate" | awk -F: '{print $2}' | xargs || true)
cache_size=$(sudo smartctl -i "$DISK" 2>/dev/null | grep -i "Cache Size" | awk -F: '{print $2}' | xargs || true)

if [[ -n $rotation_speed ]]; then
  echo "Rotation Speed:                     ${rotation_speed}"
else
  echo "Rotation Speed:                     Not applicable (SSD)"
fi
echo "Cache Size:                         ${cache_size:-Not available}"

echo -e "\e[31mBasic Info:\e[0m"
sudo smartctl -i "$DISK" | grep -E "Model Number|Serial Number|Firmware Version|Capacity" || echo "Basic info not available."

echo -e "\e[31mMore info:\e[0m"
if [[ $interface == "NVMe" ]]; then
  sudo smartctl -x "$DISK" | grep -E "Available Spare|Unsafe Shutdowns|Media and Data Integrity Errors" || echo "No extra NVMe info."
else
  sudo smartctl -A "$DISK" | grep -E "Current_Pending_Sector|Offline_Uncorrectable" || echo "No extra SATA info."
fi

echo -e "\e[31mIf you see nothing above, it could be:\e[0m"
echo -e "\e[31m- Drive does not support SMART\e[0m"
echo -e "\e[31m- USB adapter does not support SMART\e[0m"
echo -e "\e[31m- Permissions error (try running with sudo)\e[0m"
echo -e "\e[32mPress any key to exit...\e[0m"
read -n 1 -s
