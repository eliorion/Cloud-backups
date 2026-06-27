# hosts/node-a-hardware.nix — node-A hardware module.
#
# ⚠️ TODO operator: this DEFAULTS to the same Lenovo ThinkCentre M715q Tiny
#    (AMD PRO A10-9700E) module as node-B, because doc 13 chose the M715q
#    dual-disk model fleet-wide. If node-A is DIFFERENT hardware, regenerate on
#    the box during install and replace this file:
#        nixos-generate-config --root /mnt        # writes /mnt/etc/nixos/hardware-configuration.nix
#    then copy the relevant boot.initrd.availableKernelModules / kernelModules /
#    cpu microcode / hostPlatform lines here. Wrong kernel modules here can mean
#    a node that does not find its NVMe/SATA at boot.
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ]; # TODO operator: "kvm-intel" if node-A is Intel
  boot.extraModulePackages = [ ];

  hardware.cpu.amd.updateMicrocode = lib.mkDefault true;
  hardware.enableRedistributableFirmware = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
