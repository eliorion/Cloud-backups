# hosts/node-a-hardware.nix — node-A hardware module.
#
# Transcribed from `nixos-generate-config` run on the REAL node-A box (AMD, so
# kvm-amd). No longer node-B's placeholder. To re-derive after a hardware change:
#     nixos-generate-config --root /mnt    # writes .../hardware-configuration.nix
# then copy the boot.initrd.availableKernelModules / kernelModules / cpu
# microcode / hostPlatform lines here. Wrong kernel modules here can mean a node
# that does not find its NVMe/SATA at boot.
#
# `swapDevices` is intentionally omitted (generate-config emits an empty list;
# disko owns node-A's pools). `hardware.enableRedistributableFirmware` is not set
# explicitly either — not-detected.nix (imported below) already mkDefaults it
# true, which is what the microcode line reads.
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "ehci_pci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
