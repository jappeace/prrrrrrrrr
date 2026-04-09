# Thin wrapper around nixpkgs that adds a QEMU -B (guest_base) overlay.
#
# When cross-compiling Haskell with Template Haskell for aarch64-android,
# iserv-proxy-interpreter runs under QEMU user-mode.  Without -B, QEMU
# uses guest_base=0: guest addresses map directly to host addresses.
# The guest binary loads at ~0x200000 where QEMU's own code already
# resides on the host, so mmap hints from GHC's RTS linker are ignored.
# Loaded .o code lands far from the binary's symbols, exceeding the
# +/-4 GiB range of aarch64 ADRP relocations (assertion in
# rts/linker/elf_reloc_aarch64.c).
#
# -B 0x4000000000 shifts the guest address space by 256 GiB, placing
# the guest binary at an unoccupied host address so mmap hints succeed
# and relocations stay within range.
args@{ overlays ? [], ... }:
let
  realNixpkgs = (import ../../npins).nixpkgs;
in
import realNixpkgs (args // {
  overlays = overlays ++ [
    (final: prev: {
      qemu-user = prev.symlinkJoin {
        name = "qemu-user-with-guest-base";
        paths = [ prev.qemu-user ];
        postBuild = ''
          rm $out/bin/qemu-aarch64
          cat > $out/bin/qemu-aarch64 <<'WRAPPER'
#!/bin/sh
exec ${prev.qemu-user}/bin/qemu-aarch64 -B 0x4000000000 "$@"
WRAPPER
          chmod +x $out/bin/qemu-aarch64
        '';
      };
    })
  ];
})
