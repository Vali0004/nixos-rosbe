{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # efi-emulation boots uefildr.efi as a plain kernel image
    # keeps its own nixpkgs lock, a different compiler or gnu-efi breaks the shim
    efi-emulation.url = "github:PureDarwin/efi-emulation";
  };

  outputs = { self, nixpkgs, efi-emulation }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    fhs = pkgs.buildFHSEnv {
      name = "rosbe-fhs";
      # GCC 13 as host, newer GCC defaults to C23 and breaks the GCC 8 era sources RosBE builds
      targetPkgs = p: with p; [
        gcc13 gnumake binutils
        bison flex m4 texinfo perl python312  # ninja configure.py needs the pipes module, gone in Python 3.13
        bzip2 gzip xz gnutar findutils gnugrep gnused gawk diffutils patch which file
        pkg-config zlib zlib.dev ncurses ncurses.dev
        git wget curl ccache
        coreutils util-linux
      ];
      profile = ''
        export ROSBE_DIR="$HOME/development/reactos/RosBE"
        export CC=gcc CXX=g++
        export PKG_CONFIG_PATH=/usr/lib/pkgconfig:/usr/share/pkgconfig
      '';
      runScript = "bash";
    };
    rosbe = import ./nix/rosbe.nix { inherit pkgs; };
    # unwrapped clang plus its resource dir, the Nix cc-wrapper would add Linux flags
    clangFor = llvm: name: let
      major = pkgs.lib.versions.major llvm.clang-unwrapped.version;
    in pkgs.writeShellScriptBin name ''
      exec ${llvm.clang-unwrapped}/bin/${name} -resource-dir=${llvm.clang-unwrapped.lib}/lib/clang/${major} "$@"
    '';
    # toolchain-clang.cmake takes its sysroot from $_ROSBE_ROSSCRIPTDIR/$ROS_ARCH
    rosbeRoot = pkgs.linkFarm "rosbe-root" [ { name = "i386"; path = rosbe.toolchain; } ];
    rosbeRoot64 = pkgs.linkFarm "rosbe-root-amd64" [ { name = "amd64"; path = rosbe.toolchain64; } ];
    # clang for C and C++, RosBE still does asm, linking and resources
    clangShell = clangShellFor { };
    clangShellFor = { arch ? "i386", tools ? rosbe.all, root ? rosbeRoot }: llvm: (pkgs.mkShell.override { stdenv = pkgs.gcc13Stdenv; }) {
      packages = tools ++ [ (clangFor llvm "clang") (clangFor llvm "clang++") ];
      hardeningDisable = [ "all" ];
      ROS_ARCH = arch;
      _ROSBE_ROSSCRIPTDIR = "${root}";
      BISON_PKGDATADIR = "${rosbe.bison}/share/bison";
      shellHook = "unset CFLAGS CXXFLAGS LDFLAGS HOST";
    };
    # boots an iso with serial on stdio, defaults to the bootcd in the build tree
    qemu = pkgs.writeShellApplication {
      name = "reactos-qemu";
      runtimeInputs = [ pkgs.qemu ];
      text = ''
        iso="''${1:-reactos/output-MinGW-i386/bootcd.iso}"
        disk="''${DISK:-reactos/output-MinGW-i386/hdd.qcow2}"
        [ -f "$disk" ] || qemu-img create -f qcow2 "$disk" 8G
        exec qemu-system-i386 -enable-kvm -m "''${MEM:-1G}" -cdrom "$iso" -hda "$disk" -boot d \
          -serial stdio -vga std -nic user,model=e1000
      '';
    };
    # configures on first run, builds the bootcd and boots it, run from the flake dir
    # or point REACTOS_SRC at the source tree
    buildAndBoot = { name, toolchainFile, outDir, extra ? [ ] }: pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = rosbe.all ++ extra ++ [ pkgs.gcc13 qemu ];
      text = ''
        unset CFLAGS CXXFLAGS LDFLAGS HOST
        # wrapper hardening breaks host-tools
        export NIX_HARDENING_ENABLE=""
        export ROS_ARCH=i386
        export _ROSBE_ROSSCRIPTDIR=${rosbeRoot}
        export BISON_PKGDATADIR=${rosbe.bison}/share/bison
        src=$(readlink -f "''${REACTOS_SRC:-reactos}")
        out="$src/${outDir}"
        if [ ! -f "$out/build.ninja" ]; then
          cmake -S "$src" -B "$out" -G Ninja -DCMAKE_TOOLCHAIN_FILE=${toolchainFile} -DARCH=i386
        fi
        ninja -C "$out" bootcd
        DISK="''${DISK:-$out/hdd.qcow2}" exec reactos-qemu "$out/bootcd.iso"
      '';
    };
    uefildr = let env = builtins.getEnv "UEFILDR"; in builtins.path {
      name = "uefildr.efi";
      path = if env != "" then env else builtins.getEnv "PWD" + "/reactos/output-clang21-amd64/boot/freeldr/freeldr/uefildr.efi";
    };
    uefiInitrd = pkgs.runCommand "uefildr-initrd.cpio" { nativeBuildInputs = [ pkgs.cpio ]; } ''
      mkdir -p EFI/BOOT
      cp ${uefildr} EFI/BOOT/uefildr.efi
      find EFI | cpio -o -H newc --quiet > $out
    '';
    app = drv: { type = "app"; program = "${drv}/bin/${drv.name}"; };
    runGcc = buildAndBoot { name = "reactos-gcc"; toolchainFile = "toolchain-gcc.cmake"; outDir = "output-MinGW-i386"; };
    runClang18 = runClang pkgs.llvmPackages_18 "reactos-clang" "output-clang-i386";
    runClang21 = runClang pkgs.llvmPackages_21 "reactos-clang21" "output-clang21-i386";
    runClang = llvm: name: outDir: buildAndBoot {
      inherit name outDir;
      toolchainFile = "toolchain-clang.cmake";
      extra = [ (clangFor llvm "clang") (clangFor llvm "clang++") ];
    };
    # boots the amd64 uefildr.efi as a Linux bzImage through efi-emulation
    uefiBoot = pkgs.writeShellApplication {
      name = "reactos-uefi";
      runtimeInputs = with pkgs; [ qemu cpio libarchive dosfstools mtools util-linux findutils ];
      text = ''
        src=$(readlink -f "''${REACTOS_SRC:-reactos}")
        out="$src/''${UEFI_OUT:-output-clang21-amd64}"
        work="$out/uefi"
        efi="$out/boot/freeldr/freeldr/uefildr.efi"
        [ -f "$efi" ] && [ -f "$out/bootcd.iso" ] || { echo "build $out bootcd first" >&2; exit 1; }
        mkdir -p "$work/initrd/EFI/BOOT"
        # the initrd carries the loader, the disk carries freeldr.ini and the system
        cp "$efi" "$work/initrd/EFI/BOOT/uefildr.efi"
        (cd "$work/initrd" && find EFI | cpio -o -H newc --quiet > "$work/initrd.cpio")
        if [ ! -f "$work/disk.raw" ] || [ "$out/bootcd.iso" -nt "$work/disk.raw" ]; then
          rm -rf "$work/tree" "$work/disk.raw"
          mkdir -p "$work/tree"
          bsdtar -xf "$out/bootcd.iso" -C "$work/tree"
          truncate -s 2G "$work/disk.raw"
          printf 'label: dos\nstart=2048, type=c, bootable\n' | sfdisk -q "$work/disk.raw"
          mkfs.fat -F 32 -n REACTOS --offset 2048 "$work/disk.raw" >/dev/null
          (cd "$work/tree" && MTOOLS_SKIP_CHECK=1 mcopy -s -Q -i "$work/disk.raw@@1M" ./* ::/)
          rm -rf "$work/tree"
        fi
        exec qemu-system-x86_64 -enable-kvm -m "''${MEM:-2G}" \
          -kernel ${efi-emulation.packages.${system}.x86_64}/boot/efi-emulation.bzImage \
          -initrd "$work/initrd.cpio" \
          -drive file="$work/disk.raw",format=raw,if=ide,snapshot=on \
          -vga std -nic user,model=e1000 -serial stdio "$@"
      '';
    };
  in {
    apps.${system} = {
      uefi = app uefiBoot;
      qemu = app qemu;
      gcc = app runGcc;
      clang = app runClang18;
      clang21 = app runClang21;
    };
    packages.${system} = {
      default = fhs;
      inherit (rosbe) toolchain toolchain64 cmake ninja bison flex;
      inherit qemu;
      reactos-gcc = runGcc;
      reactos-clang = runClang18;
      reactos-clang21 = runClang21;
      # efi-emulation bzImage with uefildr.efi built in, the loader lives in the
      # gitignored build tree so this needs --impure from the flake dir, UEFILDR overrides it
      uefi-kernel = efi-emulation.packages.${system}.x86_64.overrideAttrs (old: {
        cmakeFlags = old.cmakeFlags ++ [ "-DEFIEMU_EMBED_INITRD=${uefiInitrd}" ];
      });
    };
    devShells.${system} = {
      default = fhs.env;
      # pure Nix RosBE, same env RosBE.sh sets up with the toolchain from the store
      # host-tools are built with the host compiler, so the shell carries GCC 13
      native = (pkgs.mkShell.override { stdenv = pkgs.gcc13Stdenv; }) {
        packages = rosbe.all;
        # wrapper hardening breaks host-tools (fortify vs hhpcomp, format-security vs mkisofs)
        hardeningDisable = [ "all" ];
        ROS_ARCH = "i386";
        BISON_PKGDATADIR = "${rosbe.bison}/share/bison";
        shellHook = "unset CFLAGS CXXFLAGS LDFLAGS HOST";
      };
      clang = clangShell pkgs.llvmPackages_18;
      clang21 = clangShell pkgs.llvmPackages_21;
      # GCC 8.4 amd64 build, the reference the clang amd64 build is compared against
      native-amd64 = (pkgs.mkShell.override { stdenv = pkgs.gcc13Stdenv; }) {
        # the amd64 SEH gcc plugin builds against GCC plugin headers that include gmp.h
        packages = rosbe.all64 ++ [ pkgs.gmp pkgs.mpfr pkgs.libmpc ];
        hardeningDisable = [ "all" ];
        ROS_ARCH = "amd64";
        BISON_PKGDATADIR = "${rosbe.bison}/share/bison";
        shellHook = "unset CFLAGS CXXFLAGS LDFLAGS HOST";
      };
      # amd64 target, RosBE x86_64 toolchain for asm, linking and resources
      # arm64 through msvc.cmake with clang-cl, LLVM stands in for the MSVC tools
      clang21-arm64 = (pkgs.mkShell.override { stdenv = pkgs.gcc13Stdenv; }) {
        packages = [ rosbe.cmake rosbe.ninja rosbe.bison rosbe.flex
          (pkgs.writeShellScriptBin "mc" ''exec ${rosbe.toolchain}/bin/i686-w64-mingw32-windmc "$@"'')
        ] ++ import ./nix/msvc-llvm.nix { inherit pkgs; llvm = pkgs.llvmPackages_21; };
        hardeningDisable = [ "all" ];
        ROS_ARCH = "arm64";
        BISON_PKGDATADIR = "${rosbe.bison}/share/bison";
        shellHook = "unset CFLAGS CXXFLAGS LDFLAGS HOST";
      };
      # arm32 the same way, clang-cl targets Thumb-2 like Windows RT
      clang21-arm = (pkgs.mkShell.override { stdenv = pkgs.gcc13Stdenv; }) {
        packages = [ rosbe.cmake rosbe.ninja rosbe.bison rosbe.flex
          (pkgs.writeShellScriptBin "mc" ''exec ${rosbe.toolchain}/bin/i686-w64-mingw32-windmc "$@"'')
        ] ++ import ./nix/msvc-llvm.nix { inherit pkgs; llvm = pkgs.llvmPackages_21; arch = "arm"; };
        hardeningDisable = [ "all" ];
        ROS_ARCH = "arm";
        BISON_PKGDATADIR = "${rosbe.bison}/share/bison";
        shellHook = "unset CFLAGS CXXFLAGS LDFLAGS HOST";
      };
      clang21-amd64 = clangShellFor { arch = "amd64"; tools = rosbe.all64; root = rosbeRoot64; } pkgs.llvmPackages_21;
    };
  };
}
