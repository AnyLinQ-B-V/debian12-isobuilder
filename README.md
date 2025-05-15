# Debian Fully Automatic Install Through ISO Remastering

This project provides a script to remaster a Debian netinst ISO for a 100% unattended installation. The script interactively prompts for user credentials, hostname, and whether to apply system hardening.

## Usage

1. Download a [Debian "netinst"](https://www.debian.org/CD/netinst/) ISO, or let the script fetch the latest version for you.
2. Run the script. It will guide you through:
    - Selecting the base ISO (download or local path).
    - Setting up user credentials (username, password).
    - **Choosing whether to apply system hardening** (hardened partitioning, firewall with `ufw`, and other security enhancements).
3. Execute the script:
   ```
   ./make-preseed-iso.sh debian-12.0.0-amd64-netinst.iso
   ```
   Or simply:
   ```
   ./make-preseed-iso.sh
   ```
   and follow the prompts.

A new ISO image named `preseed-<original-iso-name>` will be created, which installs Debian on the first available disk without intervention—not even a boot menu prompt.

---

## ⚠️ WARNING: Data Loss

The generated preseed configuration **completely erases the first disk**  
> as returned by `list-devices disk`, excluding USB

**Read the script and generated preseed file before use!**  
This is intended for automated installs and will destroy all data on the target disk.

- The location of the initrd is hardcoded to `install.amd`. If you use an ISO for an architecture other than amd64, you must change this in the script.
- The boot menu configuration is specific to Debian 12 (Bookworm) and may need adjustment for other releases or architectures.

---

## More on Preseeding

- https://wiki.debian.org/DebianInstaller/Preseed
- https://wiki.debian.org/DebianInstaller/Preseed/EditIso
- https://wiki.debian.org/RepackBootableISO

---

## Extra's

### Timing

| Attempt         | With Hardening | Without Hardening |
| :-------------: | :------------: | :---------------: |
| Building ISO    | 32 seconds     | 32 seconds        |
| Installing VM   | tbd            | tbd               |

### CIS Hardening Status according to Lynis

| State             | With Hardening | Without Hardening |
| :---------------: | :------------: | :---------------: |
| post installation | tbd            | 61                |

![Demo of script](.github/images/719057.gif)

---

## Todo / Fixes

- Lynis states secure boot is not enabled (`/sys/firmware/efi/efivars/SecureBoot-*`)
- `/boot` needs `nodev,noexec,nosuid`

---

<div align="center">
Created and maintained by <a href="https://www.anylinq.com">anylinq B.V.</a><br/><br/>
<a href="https://www.anylinq.com"><img src="https://anylinq.com/hubfs/AnyLinQ%20transparant.png" width="120" alt="anylinq Logo"/></a>
</div>

---

<sub>Author: Ronny Roethof (<a href="mailto:ronny@roethof.net">ronny@roethof.net</a>)</sub>
