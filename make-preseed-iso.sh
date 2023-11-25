#!/bin/bash

set -e

# --- Setup and Utility Functions ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESEED_FILENAME="preseed.cfg"
WORK_DIR=$(mktemp -d -p "$SCRIPT_DIR" workdir.XXXXXX) # Temporary working directory

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Cleanup function to remove temporary files and directories
cleanup_and_exit() {
  log_info "Cleaning up temporary work directory: $WORK_DIR"
  if [ -d "$WORK_DIR/isofiles" ]; then
    chmod +w "$WORK_DIR/isofiles" -R
  fi
  rm -rf "$WORK_DIR"
  if [ -n "$1" ] && [ "$1" -ne 0 ]; then
    log_error "Script exited with error."
    exit "$1"
  fi
  log_info "Script finished successfully."
  exit 0
}

# Trap to ensure cleanup runs on exit or interruption
trap 'cleanup_and_exit $?' EXIT SIGHUP SIGINT SIGQUIT SIGTERM

# --- Dependency Checking ---

# Check if a command exists, and offer to install if missing
check_command() {
  if ! command -v "$1" &>/dev/null; then
    log_warn "Command '$1' not found. It is part of package '$2'."
    read -r -p "Do you want to try and install '$2' using 'sudo apt-get install $2'? (y/N): " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
      if sudo apt-get update && sudo apt-get install -y "$2"; then
        log_info "Package '$2' installed successfully."
      else
        log_error "Failed to install package '$2'. Please install it manually and re-run the script."
        return 1
      fi
    else
      log_error "Package '$2' is required. Please install it manually and re-run the script."
      return 1
    fi
  fi
  return 0
}

# Check all required dependencies
check_dependencies() {
  log_info "Checking dependencies..."
  local all_ok=true
  check_command "bsdtar" "libarchive-tools" || all_ok=false
  check_command "xorriso" "xorriso" || all_ok=false
  check_command "wget" "wget" || all_ok=false
  check_command "mkpasswd" "whois" || all_ok=false
  # coreutils (md5sum, dd, basename, etc.), gzip, cpio, sed are generally pre-installed

  if [ "$all_ok" = false ]; then
    log_error "One or more dependencies are missing or could not be installed. Aborting."
    exit 1
  fi
  log_info "All dependencies are met."
}

# --- ISO Download and Verification ---

# Fetch information about the latest Debian netinst ISO
fetch_latest_debian_iso_info() {
  local base_url="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/"
  local sums_file="SHA512SUMS"
  log_info "Fetching latest Debian ISO information from $base_url..."
  
  if ! wget -q -P "$WORK_DIR" "${base_url}${sums_file}"; then
    log_error "Failed to download ${sums_file}. Cannot determine latest ISO."
    return 1
  fi

  # Find the netinst ISO in the SHA512SUMS file
  local iso_line
  iso_line=$(grep 'amd64-netinst.iso$' "$WORK_DIR/$sums_file" | head -n 1)

  if [ -z "$iso_line" ]; then
    log_error "Could not find amd64-netinst.iso in $sums_file."
    rm -f "$WORK_DIR/$sums_file"
    return 1
  fi

  LATEST_ISO_FILENAME=$(echo "$iso_line" | awk '{print $2}')
  LATEST_ISO_CHECKSUM=$(echo "$iso_line" | awk '{print $1}')
  LATEST_ISO_URL="${base_url}${LATEST_ISO_FILENAME}"
  
  log_info "Latest Debian netinst ISO: $LATEST_ISO_FILENAME"
  rm -f "$WORK_DIR/$sums_file" # Clean up SHA512SUMS
  return 0
}

# Download the ISO file
download_iso() {
  local url="$1"
  local filename="$2"
  local dest_path="$3"

  log_info "Downloading $filename from $url..."
  if wget -c -O "$dest_path" "$url"; then
    log_info "Download complete: $dest_path"
    return 0
  else
    log_error "Download failed for $filename."
    return 1
  fi
}

# Verify the ISO checksum
verify_iso_checksum() {
  local iso_file="$1"
  local expected_checksum="$2"
  log_info "Verifying checksum for $iso_file..."
  local calculated_checksum
  calculated_checksum=$(sha512sum "$iso_file" | awk '{print $1}')
  if [ "$calculated_checksum" == "$expected_checksum" ]; then
    log_info "Checksum VERIFIED for $iso_file."
    return 0
  else
    log_error "Checksum MISMATCH for $iso_file!"
    log_error "Expected: $expected_checksum"
    log_error "Got:      $calculated_checksum"
    return 1
  fi
}

# Prompt user to download latest ISO or use a local file
prompt_for_debian_iso() {
  read -r -p "Do you want to download the latest Debian netinst ISO? (Y/n) or provide path to local ISO: " choice
  case "$choice" in
    [nN]|[nN][oO])
      read -r -e -p "Enter the full path to your local Debian ISO file: " local_iso_path
      if [ -f "$local_iso_path" ]; then
        ORIG_ISO="$local_iso_path"
        log_info "Using local ISO: $ORIG_ISO"
      else
        log_error "Local ISO file not found: $local_iso_path. Aborting."
        exit 1
      fi
      ;;
    ""|[yY]|[yY][eE][sS])
      if fetch_latest_debian_iso_info; then
        local downloaded_iso_path="$WORK_DIR/$LATEST_ISO_FILENAME"
        if [ -f "$downloaded_iso_path" ]; then
            log_info "ISO $LATEST_ISO_FILENAME already exists in work directory. Verifying..."
            if verify_iso_checksum "$downloaded_iso_path" "$LATEST_ISO_CHECKSUM"; then
                ORIG_ISO="$downloaded_iso_path"
            else
                log_warn "Existing ISO checksum failed. Re-downloading."
                rm -f "$downloaded_iso_path" # Remove corrupt/old ISO
            fi
        fi
        
        if [ -z "$ORIG_ISO" ]; then # If ORIG_ISO not set (didn't exist or checksum failed)
            if download_iso "$LATEST_ISO_URL" "$LATEST_ISO_FILENAME" "$downloaded_iso_path"; then
              if verify_iso_checksum "$downloaded_iso_path" "$LATEST_ISO_CHECKSUM"; then
                ORIG_ISO="$downloaded_iso_path"
              else
                log_error "Downloaded ISO checksum verification failed. Aborting."
                exit 1
              fi
            else
              log_error "Failed to download the latest Debian ISO. Aborting."
              exit 1
            fi
        fi
      else
        log_error "Could not determine or download the latest Debian ISO. Aborting."
        exit 1
      fi
      ;;
    *) # User entered a path
      if [ -f "$choice" ]; then
        ORIG_ISO="$choice"
        log_info "Using local ISO: $ORIG_ISO"
      else
        log_error "Invalid input or local ISO file not found: $choice. Aborting."
        exit 1
      fi
      ;;
  esac
}

# --- User and Hardening Prompts ---

# Prompt for username and password for the new system
prompt_for_user_credentials() {
  log_info "Configuring user account for the new system..."
  read -r -p "Enter username for the new system: " PRESEED_USERNAME
  while true; do
    read -r -s -p "Enter password for $PRESEED_USERNAME: " PRESEED_PASSWORD
    echo
    read -r -s -p "Confirm password: " PRESEED_PASSWORD_CONFIRM
    echo
    if [ "$PRESEED_PASSWORD" == "$PRESEED_PASSWORD_CONFIRM" ]; then
      if [ -z "$PRESEED_PASSWORD" ]; then
        log_warn "Password is empty. This is insecure. Please provide a password."
      else
        break
      fi
    else
      log_error "Passwords do not match. Please try again."
    fi
  done
  PRESEED_HASHED_PASSWORD=$(mkpasswd -m sha-512 "$PRESEED_PASSWORD")
  # Clear password variables for security
  unset PRESEED_PASSWORD
  unset PRESEED_PASSWORD_CONFIRM
}

# Prompt for system hardening
APPLY_HARDENING="false"
prompt_for_hardening() {
  log_info "System Hardening Configuration"
  read -r -p "Do you want to apply system hardening (hardened partitioning, firewall, etc.)? (y/N): " response
  if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    APPLY_HARDENING="true"
    log_info "System hardening WILL be applied."
  else
    APPLY_HARDENING="false"
    log_info "Standard system configuration will be used (no extra hardening)."
  fi
}

# --- Preseed Generation ---

# Generate the preseed configuration file for automated install
generate_preseed_cfg() {
  local preseed_path="$WORK_DIR/$PRESEED_FILENAME"
  log_info "Generating preseed configuration file: $preseed_path (Hardening: $APPLY_HARDENING)"
  # Overwrite if preseed already exists
  if [ -f "$preseed_path" ]; then
    log_warn "Preseed configuration file already exists. Overwriting..."
  fi 

  local partitioning_config=""
  local late_command_extras_content=""
  local pkgsel_extras=""

  if [ "$APPLY_HARDENING" == "true" ]; then
    pkgsel_extras="ufw aide aide-common"

    partitioning_config=$(cat <<PART_EOF
d-i partman-auto/method string lvm
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-auto/expert_recipe string \
  efi-boot-root-home-var-tmp :: \
    512 512 512 fat32 \
      \$primary{ } \$bootable{ } method{ efi } format{ } \
      mountpoint{ /boot/efi } . \
    512 1024 1024 ext4 \
      \$primary{ } \
      method{ format } format{ } \
      use_filesystem{ } filesystem{ ext4 } \
      mountpoint{ /boot } . \
    20000 30000 -1 lvm \
      \$lvmok{ } \
      method{ lvm } \
      vg_name{ vg0 } . \
    8000 10000 35% logical \
      \$lvmok{ } lv_name{ lv_root } \
      method{ format } format{ } \
      use_filesystem{ } filesystem{ ext4 } \
      mountpoint{ / } . \
    4000 8000 25% logical \
      \$lvmok{ } lv_name{ lv_home } \
      method{ format } format{ } \
      use_filesystem{ } filesystem{ ext4 } \
      options{ nodev,nosuid } \
      mountpoint{ /home } . \
    4000 8000 25% logical \
      \$lvmok{ } lv_name{ lv_var } \
      method{ format } format{ } \
      use_filesystem{ } filesystem{ ext4 } \
      mountpoint{ /var } . \
    2000 4000 10% logical \
      \$lvmok{ } lv_name{ lv_tmp } \
      method{ format } format{ } \
      use_filesystem{ } filesystem{ ext4 } \
      options{ nodev,nosuid,noexec } \
      mountpoint{ /tmp } . \
    1000 2000 100% logical \
      \$lvmok{ } lv_name{ lv_swap } \
      method{ swap } format{ } \
      use_filesystem{ } filesystem{ swap } \
      mountpoint{ none } .
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
PART_EOF
)
    late_command_extras_content=""
  else
    partitioning_config=$(cat <<PART_EOF
d-i partman-auto/method string lvm
d-i partman-auto-lvm/guided_size string max
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
PART_EOF
)
    late_command_extras_content=""
  fi

  # Write the preseed configuration file
  cat > "$preseed_path" <<EOF
#Hardening Applied: $APPLY_HARDENING

d-i debian-installer/language string en
d-i debian-installer/country string US
d-i debian-installer/locale string en_US.UTF-8
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select us

d-i netcfg/choose_interface select auto
d-i netcfg/dhcp_timeout string 60
d-i netcfg/get_hostname string debian-preseed
d-i netcfg/get_domain string localdomain

d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string  

d-i clock-setup/utc boolean true
d-i time/zone string Europe/Amsterdam
d-i clock-setup/ntp boolean true

$partitioning_config

d-i partman/early_command string debconf-set partman-auto/init_automatically_partition select biggest_free

d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

d-i passwd/root-login boolean false
d-i passwd/user-fullname string $PRESEED_USERNAME
d-i passwd/username string $PRESEED_USERNAME
d-i passwd/user-password-crypted password $PRESEED_HASHED_PASSWORD
d-i passwd/user-default-groups string adm cdrom dip lpadmin plugdev sambashare sudo
d-i user-setup/allow-password-weak boolean true
d-i user-setup/encrypt-home boolean false

tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string curl wget sudo vim net-tools apt-transport-https ca-certificates gnupg $pkgsel_extras
d-i pkgsel/upgrade select full-upgrade
d-i pkgsel/update-policy select none

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true

d-i finish-install/reboot_in_progress note

d-i preseed/late_command string \
  in-target sh -c 'echo "$PRESEED_USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/010_$PRESEED_USERNAME-nopasswd && chmod 0440 /etc/sudoers.d/010_$PRESEED_USERNAME-nopasswd'
  in-target apt-get update && \
  in-target DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade && \
  in-target apt-get -y autoremove && \
  in-target apt-get -y clean ${late_command_extras_content:+"&& \\"}
  $late_command_extras_content
EOF
  log_info "$preseed_path generated successfully."
}

# --- ISO Manipulation Functions ---

# Extract the original ISO to the working directory
extract_iso() {
  log_info "Extracting iso: $1 into $WORK_DIR/isofiles..."
  mkdir -p "$WORK_DIR/isofiles"
  bsdtar -C "$WORK_DIR/isofiles" -xf "$1"
}

# Add the preseed file to the initrd image
add_preseed_to_initrd() {
  log_info "Adding $PRESEED_FILENAME to initrd..."
  chmod +w "$WORK_DIR/isofiles/install.amd/" -R
  gunzip "$WORK_DIR/isofiles/install.amd/initrd.gz"
  (cd "$WORK_DIR" && echo "$PRESEED_FILENAME" | cpio -H newc -o -A -F "$WORK_DIR/isofiles/install.amd/initrd")
  gzip "$WORK_DIR/isofiles/install.amd/initrd"
  chmod -w "$WORK_DIR/isofiles/install.amd/" -R
}

# Set 'auto' as the default ISOLINUX boot entry
make_auto_the_default_isolinux_boot_option() {
  local isolinux_cfg_path="$WORK_DIR/isofiles/isolinux/isolinux.cfg"
  local tmp_isolinux_cfg
  tmp_isolinux_cfg=$(mktemp --tmpdir="$WORK_DIR" isolinux.XXXXX)

  log_info "Setting 'auto' as default ISOLINUX boot entry..."
  sed 's/timeout 0/timeout 30/g' "$isolinux_cfg_path" >"$tmp_isolinux_cfg"
  if ! grep -q "^default auto" "$tmp_isolinux_cfg"; then
    echo "default auto" >>"$tmp_isolinux_cfg"
  fi
  chmod +w "$isolinux_cfg_path"
  cat "$tmp_isolinux_cfg" >"$isolinux_cfg_path"
  chmod -w "$isolinux_cfg_path"
  rm "$tmp_isolinux_cfg"
}

# Set 'auto' as the default GRUB boot entry
make_auto_the_default_grub_boot_option() {
  local grub_cfg_path="$WORK_DIR/isofiles/boot/grub/grub.cfg"
  log_info "Setting 'auto' as default GRUB boot entry..."
  chmod +w "$grub_cfg_path"
  if ! grep -q 'set default="2>5"' "$grub_cfg_path"; then
    echo 'set default="2>5"' >>"$grub_cfg_path"
  fi
  if ! grep -q "set timeout=3" "$grub_cfg_path"; then
    echo "set timeout=3" >>"$grub_cfg_path"
  fi
  chmod -w "$grub_cfg_path"
}

# Recompute md5 checksums for the ISO contents
recompute_md5_checksum() {
  log_info "Calculating new md5 checksum for files in ISO structure..."
  log_warn "You can safely ignore the warning about a 'file system loop' if it appears below."
  (
    cd "$WORK_DIR/isofiles"
    chmod +w md5sum.txt
    find . -follow -type f ! -name md5sum.txt -print0 | xargs -0 md5sum >md5sum.txt
    chmod -w md5sum.txt
  )
}

# Generate the new ISO with the preseed and modifications
generate_new_iso() {
  local new_iso_name="preseed-$(basename "$ORIG_ISO")"
  local new_iso_path="$SCRIPT_DIR/$new_iso_name"

  log_info "Generating new iso: $new_iso_path..."
  dd if="$ORIG_ISO" bs=1 count=432 of="$WORK_DIR/mbr_template.bin" status=none

  chmod +w "$WORK_DIR/isofiles/isolinux/isolinux.bin"
  xorriso -as mkisofs -r \
    -V 'Debian AUTO amd64' \
    -o "$new_iso_path" \
    -J -joliet-long \
    -cache-inodes \
    -isohybrid-mbr "$WORK_DIR/mbr_template.bin" \
    -b isolinux/isolinux.bin \
    -c isolinux/boot.cat \
    -boot-load-size 4 -boot-info-table \
    -no-emul-boot -eltorito-alt-boot \
    -e boot/grub/efi.img -no-emul-boot \
    -isohybrid-gpt-basdat \
    -isohybrid-apm-hfsplus \
    "$WORK_DIR/isofiles"

  log_info "New ISO created: $new_iso_path"
}

# --- Start: Ask all questions first ---
prompt_for_debian_iso
prompt_for_user_credentials
prompt_for_hardening
# --- End: All questions asked, now continue with setup ---

# --- Main Script Execution ---
check_dependencies
generate_preseed_cfg
extract_iso "$ORIG_ISO"
add_preseed_to_initrd
make_auto_the_default_isolinux_boot_option
make_auto_the_default_grub_boot_option
recompute_md5_checksum
generate_new_iso

log_info "All steps completed. The preseeded ISO is ready."
# Cleanup is handled by the trap function

exit 0