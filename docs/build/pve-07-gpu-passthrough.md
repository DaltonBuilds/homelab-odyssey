# pve-07 — GPU passthrough preparation

Tracked by [HOMELAB-11](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-11), Phase 0.1b. Owner confirmed on 2026-09-27 that tower onboarding is complete except GPU passthrough. It did not depend on pve-01's recovery (completed 2026-10-10).

Keep Proxmox on the tower. Pass the whole RTX 5070 to the future `prod-gpu-01` VM; the tower retains its management and build VM roles. The GPU is exclusive to its assigned VM. A bare-metal GPU worker is possible with a consumer GPU, but would change the accepted placement plan. Host preparation does not itself verify CUDA inside a guest.

## Read-only preflight

Run as root in the pve-07 shell. These commands inspect configuration without changing it:

```sh
hostname
pveversion
pvecm status
proxmox-boot-tool status
efibootmgr -v
cat /proc/cmdline
lspci -nnk
pvesh get /nodes/pve-07/hardware/pci --pci-class-blacklist ""
dmidecode -s baseboard-product-name
qm list
pct list
```

Inspect the actual bootloader, GPU and audio PCI IDs, current drivers, IOMMU groups, and other devices in those groups. Record the motherboard model to check firmware settings and slot lane sharing. A group containing the GPU's own functions or a PCI bridge is acceptable; unrelated storage/network endpoints require investigation. Do not apply ACS overrides or unsafe-interrupt workarounds by default.

## Configuration after reviewing preflight

1. Confirm firmware SVM and IOMMU support. AMD IOMMU is normally enabled by the kernel when firmware exposes it; do not add kernel parameters blindly. If kernel command-line changes are needed, preserve existing root/ZFS arguments. GRUB uses `/etc/default/grub` and `update-grub`; systemd-boot uses `/etc/kernel/cmdline` and `proxmox-boot-tool refresh`.
2. Ensure remote management remains available when the NVIDIA card is detached from the host. Check the integrated graphics/console fallback. Inspect running guests and cluster quorum before planning a reboot: with pve-01 down, rebooting pve-07 leaves five of the original seven votes if every other node is online.
3. Save the original affected configuration securely. Configure VFIO modules and bind the identified GPU and audio functions to `vfio-pci`; prevent host drivers from taking those devices. Use observed IDs, not example IDs. Keep NVIDIA compute drivers in the eventual guest.
4. Refresh initramfs after module changes and reboot during an appropriate maintenance window. Verify SSH/UI, cluster quorum, ZFS health, the existing ARC cap, and `lspci -nnk` showing `vfio-pci` for both GPU functions.
5. Record validation in HOMELAB-11. Later, attach the GPU to the intended q35/OVMF guest, install a supported guest NVIDIA driver and validate `nvidia-smi` plus a CUDA workload. That guest validation is separate from this host-preparation acceptance.

If the host fails to boot or loses expected access, use the local console to restore the saved boot/module configuration, regenerate the affected boot artifacts and reboot. Establish that console path before making binding changes.

References: [Proxmox PCI passthrough](https://github.com/proxmox/pve-docs/blob/master/qm-pci-passthrough.adoc) and [bootloader configuration](https://github.com/proxmox/pve-docs/blob/master/system-booting.adoc).

## Verified implementation — 2026-09-27

HOMELAB-11 host preparation completed over SSH and verified after reboot on Proxmox 9.2.20, kernel 7.0.14-17-pve. Motherboard: ASRock B650D4U-2L2T/BCM. Both NVIDIA functions (`01:00.0`, ID `10de:2f04`; `01:00.1`, ID `10de:2f80`) use `vfio-pci` and remain the only endpoints in their IOMMU group. KVM is available. No guest was created or CUDA workload tested.

Installed `/etc/modprobe.d/homelab-gpu-vfio.conf` with the two device IDs, a `snd_hda_intel` soft dependency on VFIO, and NVIDIA/nouveau driver blacklists. Installed `/etc/modules-load.d/homelab-gpu-vfio.conf` and appended early VFIO modules to `/etc/initramfs-tools/modules`. Ran `update-initramfs -u -k all`; Proxmox hooks synchronized both EFI partitions. Systemd-boot kernel arguments were unchanged.

After reboot: SSH available, pveproxy/pvedaemon active, seven cluster votes and healthy quorum, ZFS mirror ONLINE with zero errors, and host framebuffer still `astdrmfb`. No NVIDIA/nouveau modules were loaded. Preflight measured both NVMe links at PCIe 4.0 x4 with the GPU installed; active management NIC link is 1Gb/s.

The persistent and runtime ARC cap remains **6647971840 bytes (~6.19GiB)**, rather than the earlier documented 10GiB target; it was deliberately preserved during GPU work. Reconcile that target separately before changing memory allocation.

Rollback files are on pve-07 at `/root/homelab-11-vfio-backup.LeAL4Q/`. Its `rollback.sh` moves the two new configuration files out of active directories, restores the original initramfs module list and rebuilds boot images. Run it as root if reverting this change, then reboot after successful regeneration. Review later configuration changes before using this point-in-time rollback.
