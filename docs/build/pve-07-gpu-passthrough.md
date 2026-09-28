# pve-07 — GPU passthrough preparation

Tracked by [HOMELAB-11](https://daltonbuilds.youtrack.cloud/issue/HOMELAB-11), Phase 0.1b. Owner confirmed on 2026-09-27 that tower onboarding is complete except GPU passthrough. This work can proceed while pve-01 awaits its replacement disk.

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
