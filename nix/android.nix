# Android shared library — uses haskell-mobile's lib.nix.
{ sources ? import ../npins
, androidArch ? "aarch64"
, mainModule ? ../app/MobileMain.hs
}:
let
  haskellMobileSrc = sources.haskell-mobile;
  prSyncApiSrc = sources.pr-sync-api;
  pkgs = import sources.nixpkgs {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };
  androidPkgs = pkgs.pkgsCross.aarch64-android-prebuilt;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources androidArch; };

  # Static versions of C libraries so iserv-proxy-interpreter can be
  # linked statically.  A static binary does not need /system/bin/linker64,
  # which lets QEMU run it on the build host during TH evaluation.
  gmpStatic = androidPkgs.gmp.overrideAttrs (old: {
    dontDisableStatic = true;
  });
  libffiStatic = androidPkgs.libffi.overrideAttrs (old: {
    dontDisableStatic = true;
  });
  numactlStatic = androidPkgs.numactl.overrideAttrs (old: {
    dontDisableStatic = true;
  });

  # Android NDK ships libdl.a as LLVM bitcode with stub implementations
  # where dlerror() returns "libdl.a is a stub --- use libdl.so instead".
  # GHC's RTS linker can't parse LLVM bitcode as ELF.
  #
  # Fix: provide a native-ELF libdl.a that implements dlopen/dlsym by
  # searching the process's own dynamic symbol table.  Combined with
  # --export-dynamic on iserv-proxy-interpreter, this lets the RTS
  # linker resolve symbols (strlen, ghc-prim, etc.) from the static binary.
  libdlNative = pkgs.runCommand "libdl-native-android" {
    nativeBuildInputs = [ androidPkgs.stdenv.cc ];
  } ''
    cat > dl_impl.c <<'EOF'
    #include <stddef.h>
    #include <string.h>
    #include <elf.h>
    #include <stdint.h>

    /*
     * Minimal dlopen/dlsym for a statically linked aarch64 binary.
     *
     * dlopen: returns a fake non-NULL handle (the binary itself).
     * dlsym:  walks the .dynsym table (populated by --export-dynamic
     *         and --hash-style=sysv) to find symbols by name.
     *
     * Requires: -Wl,--export-dynamic -Wl,--hash-style=sysv at link time.
     */

    /* _DYNAMIC is provided by the linker when --export-dynamic is used. */
    extern Elf64_Dyn _DYNAMIC[] __attribute__((weak));

    static Elf64_Sym  *g_symtab  = NULL;
    static const char *g_strtab  = NULL;
    static uint32_t    g_nsyms   = 0;
    static int         g_inited  = 0;

    static void init_symtab(void) {
        Elf64_Dyn *d;
        g_inited = 1;
        if (!_DYNAMIC) return;
        for (d = _DYNAMIC; d->d_tag != DT_NULL; d++) {
            switch (d->d_tag) {
            case DT_SYMTAB:
                g_symtab = (Elf64_Sym *)(uintptr_t)d->d_un.d_ptr;
                break;
            case DT_STRTAB:
                g_strtab = (const char *)(uintptr_t)d->d_un.d_ptr;
                break;
            case DT_HASH: {
                /* SysV hash table: uint32_t nbuckets, nchain.
                 * nchain == total number of symbols in .dynsym. */
                uint32_t *h = (uint32_t *)(uintptr_t)d->d_un.d_ptr;
                g_nsyms = h[1];
                break;
            }
            }
        }
    }

    void *dlopen(const char *filename, int flags) {
        (void)filename; (void)flags;
        return (void *)(uintptr_t)1;  /* fake non-NULL handle */
    }

    char *dlerror(void) { return NULL; }

    void *dlsym(void *handle, const char *symbol) {
        uint32_t i;
        (void)handle;
        if (!g_inited) init_symtab();
        if (!g_symtab || !g_strtab || g_nsyms == 0) return NULL;
        for (i = 0; i < g_nsyms; i++) {
            if (g_symtab[i].st_shndx != SHN_UNDEF &&
                g_symtab[i].st_name  != 0 &&
                strcmp(g_strtab + g_symtab[i].st_name, symbol) == 0) {
                return (void *)(uintptr_t)g_symtab[i].st_value;
            }
        }
        return NULL;
    }

    int dlclose(void *handle) { (void)handle; return 0; }

    void *dlvsym(void *handle, const char *s, const char *v) {
        (void)v;
        return dlsym(handle, s);
    }

    int dladdr(const void *addr, void *info) {
        (void)addr; (void)info;
        return 0;
    }
    EOF

    cat > mmap_wrapper.c <<'MEOF'
    #include <stddef.h>
    #include <stdint.h>

    /*
     * mmap wrapper for iserv-proxy-interpreter under QEMU user-mode.
     *
     * GHC's RTS linker on aarch64 sets linkerAlwaysPic=true, which
     * causes mmapForLinker to call mmap(NULL,...) without any address
     * hint.  Under QEMU user-mode, NULL-hint mmaps land at very high
     * guest addresses (0x7fb...), far from the static binary at
     * 0x200000.  When the RTS linker processes ADRP relocations
     * between loaded code and its GOT, the ±4 GiB range is exceeded.
     *
     * This wrapper intercepts mmap(NULL,...) calls and provides a
     * hint address just above the binary.  QEMU honours the hint if
     * the guest address is free, keeping all allocations within the
     * ±4 GiB ADRP range.
     *
     * Linked with -Wl,--wrap=mmap so __wrap_mmap replaces mmap and
     * __real_mmap calls the original.
     */

    /* Flags from linux/mman.h — same on all architectures */
    #define _MAP_ANONYMOUS 0x20
    #define _MAP_FIXED     0x10

    void *__real_mmap(void *addr, unsigned long length, int prot,
                      int flags, int fd, long offset);

    /* _end is provided by the linker: end of BSS = end of binary */
    extern char _end;

    static void *_mmap_next_hint = 0;

    void *__wrap_mmap(void *addr, unsigned long length, int prot,
                      int flags, int fd, long offset) {
        /* Only intercept NULL-hint anonymous mappings */
        if (addr == 0 && (flags & _MAP_ANONYMOUS)
                      && !(flags & _MAP_FIXED)) {
            if (_mmap_next_hint == 0) {
                /* First call: start 2 MiB above end of binary */
                uintptr_t binary_end = ((uintptr_t)&_end + 0xfff)
                                       & ~(uintptr_t)0xfff;
                _mmap_next_hint = (void *)(binary_end + 0x200000);
            }
            void *result = __real_mmap(_mmap_next_hint, length, prot,
                                       flags, fd, offset);
            if (result != (void *)(intptr_t)-1) {
                /* Advance hint past this allocation (page-aligned) */
                uintptr_t next = ((uintptr_t)result + length + 0xfff)
                                 & ~(uintptr_t)0xfff;
                _mmap_next_hint = (void *)next;
                return result;
            }
            /* Hint rejected (region occupied): fall through */
        }
        return __real_mmap(addr, length, prot, flags, fd, offset);
    }
    MEOF

    aarch64-unknown-linux-android-clang -c -fPIC -o dl_impl.o dl_impl.c
    aarch64-unknown-linux-android-clang -c -fPIC -o mmap_wrapper.o mmap_wrapper.c
    mkdir -p $out/lib
    aarch64-unknown-linux-android-ar rcs $out/lib/libdl.a dl_impl.o
    aarch64-unknown-linux-android-ar rcs $out/lib/libmmap_wrapper.a mmap_wrapper.o
  '';

  # Inline cabal2nix function — only library deps, no test deps.
  # haskell-mobile is compiled separately by mkAndroidLib.
  consumerCabal2Nix =
    { mkDerivation, base, containers, lib, sqlite-simple, text
    , pr-sync-api
    , servant, servant-client, http-client, http-client-tls, time, aeson
    }:
    mkDerivation {
      pname = "prrrrrrrrr";
      version = "0.1.0.0";
      libraryHaskellDepends = [
        base containers sqlite-simple text
        pr-sync-api
        servant servant-client http-client http-client-tls time aeson
      ];
      license = lib.licenses.mit;
    };

  # Use a nixpkgs wrapper that adds QEMU -B (guest_base) flag.
  # Without this, aarch64 ADRP relocations exceed ±4 GiB during TH
  # evaluation because QEMU's mmap ignores address hints.
  sourcesWithQemuFix = sources // { nixpkgs = ./nixpkgs-qemu-fix; };

  crossDeps = import "${haskellMobileSrc}/nix/cross-deps.nix" {
    sources = sourcesWithQemuFix;
    inherit androidArch consumerCabal2Nix;
    hpkgs = self: super: {
      # Override mkDerivation to fix Template Haskell evaluation during
      # cross-compilation.  The static iserv-proxy-interpreter provides
      # a real dlsym (searching its own .dynsym via --export-dynamic)
      # so GHC's RTS linker can resolve C symbols from the static binary.
      # We clear dynamic-library-dirs to force LoadArchive for Haskell
      # packages, and resolve ${pkgroot} to absolute paths for copied
      # boot package confs.
      #
      # The iserv-proxy package itself is excluded: it needs the real
      # (unpatched) package database for its own static linking.
      mkDerivation = args:
        let isIservProxy = (args.pname or "") == "iserv-proxy";
        in super.mkDerivation (args // {
          preConfigure = (args.preConfigure or "") +
            (if isIservProxy then "" else ''
              # --- TH cross-compilation fix ---
              # Copy GHC's global package DB entries (rts, base, ghc-prim,
              # etc.) into the local package DB so we can patch them.
              # The local DB shadows the global one.
              _ghcLibDir=$(${self.ghc}/bin/${self.ghc.targetPrefix}ghc --print-libdir)
              _globalConfDir="$_ghcLibDir/package.conf.d"
              if [ -d "$_globalConfDir" ] && [ -d "$packageConfDir" ]; then
                echo "TH-fix: copying global package DB from $_globalConfDir"
                for _conf in "$_globalConfDir"/*.conf; do
                  _name=$(basename "$_conf")
                  if [ ! -e "$packageConfDir/$_name" ]; then
                    cp "$_conf" "$packageConfDir/$_name"
                  fi
                done
                # Patch ALL conf files:
                # 1. Resolve ''${pkgroot} to absolute paths (relative refs
                #    break when boot packages are copied to the local DB)
                # 2. Clear dynamic-library-dirs (forces LoadArchive over
                #    LoadDLL for Haskell .a files)
                # extra-libraries are kept: our dlsym resolves C symbols
                # from the static iserv-proxy-interpreter binary.
                for _conf in "$packageConfDir"/*.conf; do
                  ${pkgs.gawk}/bin/awk -v pkgroot="$_ghcLibDir" '
                    { gsub(/\$\{pkgroot\}/, pkgroot) }
                    /^dynamic-library-dirs:/ { print "dynamic-library-dirs:"; skip=1; next }
                    skip && /^[[:space:]]/ { next }
                    { skip=0; print }
                  ' "$_conf" > "$_conf.tmp" && mv "$_conf.tmp" "$_conf"
                done
                echo "TH-fix: patched package DB, recaching"
                ${self.ghc}/bin/${self.ghc.targetPrefix}ghc-pkg --package-db="$packageConfDir" recache
                echo "TH-fix: rts include-dirs after patch:"
                grep -A3 "include-dirs" "$packageConfDir"/rts-*.conf || true
              fi
            '');
        });
      pr-sync-api = self.callCabal2nix "pr-sync-api" prSyncApiSrc {};
      # Build iserv-proxy-interpreter as a static binary so QEMU can
      # run it without Android's /system/bin/linker64.
      # --export-dynamic populates .dynsym so our dlsym can find symbols.
      # --hash-style=sysv provides DT_HASH (needed by our dlsym impl).
      # --wrap=mmap intercepts NULL-hint mmaps from GHC's RTS linker
      # (which uses mmap(NULL,...) on aarch64 due to linkerAlwaysPic=true)
      # and provides hints near the binary so allocations stay within
      # the ±4 GiB ADRP relocation range.
      iserv-proxy = pkgs.haskell.lib.appendConfigureFlags super.iserv-proxy [
        "--ghc-option=-optl-static"
        "--ghc-option=-optl-pie"
        "--ghc-option=-optl-Wl,--export-dynamic"
        "--ghc-option=-optl-Wl,--hash-style=sysv"
        "--ghc-option=-optl-Wl,--wrap=mmap"
        "--ghc-option=-optl-lmmap_wrapper"
        "--extra-lib-dirs=${gmpStatic}/lib"
        "--extra-lib-dirs=${libffiStatic}/lib"
        "--extra-lib-dirs=${numactlStatic}/lib"
        "--extra-lib-dirs=${libdlNative}/lib"
      ];
    };
  };

in
lib.mkAndroidLib {
  inherit haskellMobileSrc mainModule crossDeps;
  pname = "prrrrrrrrr-android";
  soName = "libhaskellmobile.so";
  javaPackageName = "me.jappie.prrrrrrrrr";
  extraJniBridge = [ ../cbits/jni_extras.c ];
  extraNdkCompile = ndkCc: sysroot: ''
    ${ndkCc} -c -fPIC -I${sysroot}/usr/include \
      -o storage_helper.o ${../cbits/storage_helper.c}
  '';
  extraModuleCopy = ''
    mkdir -p GymTracker
    cp ${../src/HaskellMobile/App.hs} HaskellMobile/App.hs
    cp ${../src/GymTracker/Config.hs} GymTracker/Config.hs
    cp ${../src/GymTracker/Model.hs} GymTracker/Model.hs
    cp ${../src/GymTracker/Storage.hs} GymTracker/Storage.hs
    cp ${../src/GymTracker/Sync.hs} GymTracker/Sync.hs
    cp ${../src/GymTracker/Views.hs} GymTracker/Views.hs
  '';
  extraLinkObjects = [ "$(pwd)/storage_helper.o" ];
  extraGhcIncludeDirs = [ ../cbits ];
}
