# hosts/node-c-hardware.nix — node-C is the SAME hardware as node-B (offsite
# storage Lenovo ThinkCentre, AMD). Reuse node-B's module verbatim rather than
# duplicate the kernel-module list. If node-C's box ever differs, regenerate on
# the box (`nixos-generate-config --root /mnt`) and split this into its own file.
{ ... }:
{
  imports = [ ./node-b-hardware.nix ];
}
