{ pkgs }:

let
  # GCC 13 as host, newer GCC defaults to C23 and breaks the GCC 8 era sources
  stdenv = pkgs.gcc13Stdenv;
  hostCflags = "-pipe -O2 -g0";

  # upstream package, carries the pinned source tarballs under sources/
  rosbeSrc = pkgs.fetchurl {
    url = "https://downloads.sourceforge.net/project/reactos/RosBE-Unix/2.2.1/RosBE-Unix-2.2.1.tar.bz2";
    hash = "sha256-1yDAp33AjG2jkp/Sgt4/569taXtvsQSImgNi53B0JWU=";
  };

  # builds one module from the RosBE bundle, extra tarballs unpack into the module dir
  mkModule = { name, extra ? [ ], ... }@args:
    stdenv.mkDerivation ({
      pname = "rosbe-${name}";
      version = "2.2.1";
      src = rosbeSrc;
      hardeningDisable = [ "all" ];
      enableParallelBuilding = true;
      CFLAGS = hostCflags;
      CXXFLAGS = hostCflags;
      unpackPhase = ''
        tar xjf $src
        tar xjf RosBE-Unix-2.2.1/sources/${name}.tar.bz2
        ${pkgs.lib.concatMapStrings (e: "tar -C ${name} -xjf RosBE-Unix-2.2.1/sources/${e}.tar.bz2\n") extra}
        patchShebangs ${name}
        mkdir build
        cd build
      '';
    } // builtins.removeAttrs args [ "name" "extra" ]);

  bison = mkModule {
    name = "bison";
    nativeBuildInputs = [ pkgs.m4 pkgs.perl ];
    configurePhase = "../bison/configure --prefix=$out --disable-nls";
  };

  flex = mkModule {
    name = "flex";
    nativeBuildInputs = [ pkgs.m4 bison ];
    configurePhase = "../flex/configure --prefix=$out --disable-nls";
  };

  cmake = mkModule {
    name = "cmake";
    configurePhase = "../cmake/bootstrap --prefix=$out --parallel=$NIX_BUILD_CORES -- -DCMAKE_USE_OPENSSL=OFF";
  };

  ninja = mkModule {
    name = "ninja";
    # ninja configure.py needs the pipes module, gone in Python 3.13
    nativeBuildInputs = [ pkgs.python312 ];
    configurePhase = "true";
    buildPhase = "cd ../ninja && python configure.py --bootstrap";
    installPhase = "install -Dm755 ninja $out/bin/ninja";
  };

  # binutils, GCC and mingw-w64 share one prefix and bootstrap off each other
  # so they live in one derivation
  mkToolchain = { target, targetCflags, gccFlags, crtFlags ? "", pname ? null, binutilsSrc ? null }: mkModule ({
    name = "gcc";
    extra = [ "gmp" "mpc" "mpfr" ];
    nativeBuildInputs = with pkgs; [ m4 perl texinfo bison flex zlib ];
    buildInputs = [ pkgs.zlib ];
    # target archives must not be stripped by the host strip
    dontStrip = true;
    configurePhase = "true";
    buildPhase = ''
      top=$PWD/..
      ${if binutilsSrc == null then "tar -C $top -xjf $top/RosBE-Unix-2.2.1/sources/binutils.tar.bz2" else ''
        # newer binutils than RosBE ships, unpacked under the name the steps below use
        mkdir $top/binutils && tar -C $top/binutils --strip-components=1 -xf ${binutilsSrc}''}
      tar -C $top -xjf $top/RosBE-Unix-2.2.1/sources/mingw_w64.tar.bz2
      patchShebangs $top/binutils $top/mingw_w64
      sysroot=$out
      jobs=$NIX_BUILD_CORES

      mkdir $top/binutils-build && cd $top/binutils-build
      ../binutils/configure --prefix=$out --target=${target} --with-sysroot=$sysroot \
        --disable-multilib --disable-werror --enable-lto --enable-plugins --with-zlib=yes --disable-nls
      make -j$jobs && make install

      export PATH=$out/bin:$PATH

      mkdir $top/headers-build && cd $top/headers-build
      ../mingw_w64/mingw-w64-headers/configure --prefix=$out/${target} --host=${target}
      make -j$jobs && make install
      ln -sf $out/${target} $out/mingw

      cd $top/build
      export CFLAGS_FOR_TARGET="${targetCflags}" CXXFLAGS_FOR_TARGET="${targetCflags}"
      ../gcc/configure --prefix=$out --target=${target} --with-sysroot=$sysroot \
        --with-pkgversion="RosBE-Unix" --enable-languages=c,c++ --enable-fully-dynamic-string \
        --enable-version-specific-runtime-libs --disable-shared --disable-multilib --disable-nls \
        --disable-werror --disable-win32-registry ${gccFlags} --disable-libstdcxx-verbose
      make -j$jobs all-gcc && make install-gcc && make install-lto-plugin

      mkdir $top/crt-build && cd $top/crt-build
      (
        export AR=${target}-ar AS=${target}-as CC=${target}-gcc CXX=${target}-g++ \
          DLLTOOL=${target}-dlltool RANLIB=${target}-ranlib STRIP=${target}-strip \
          CFLAGS="${targetCflags}" CXXFLAGS="${targetCflags}"
        ../mingw_w64/mingw-w64-crt/configure --prefix=$out/${target} --host=${target} --with-sysroot=$sysroot${crtFlags}
        make -j$jobs && make install
      )

      cd $top/build
      make -j$jobs && make install
    '';
    installPhase = ''
      rm -rf $out/share $out/${target}/share $out/${target}/doc
    '';
  } // pkgs.lib.optionalAttrs (pname != null) { inherit pname; });

  # i386 keeps the exact RosBE flags, sjlj exceptions as RosBE ships them
  toolchain = mkToolchain {
    target = "i686-w64-mingw32";
    targetCflags = "-pipe -O2 -Wl,-S -g0 -march=pentium -mtune=i686";
    gccFlags = "--enable-sjlj-exceptions";
  };

  # amd64 uses native SEH, the CRT is built for 64 bit only
  toolchain64 = mkToolchain {
    target = "x86_64-w64-mingw32";
    targetCflags = "-pipe -O2 -Wl,-S -g0";
    gccFlags = "";
    crtFlags = " --disable-lib32 --enable-lib64";
    pname = "rosbe-gcc-x86_64";
    # amd64 asm needs ".seh_pushframe code", binutils 2.34 from RosBE rejects it
    binutilsSrc = pkgs.binutils-unwrapped.src;
  };
in {
  inherit bison flex cmake ninja toolchain toolchain64;
  all = [ toolchain cmake ninja bison flex ];
  all64 = [ toolchain64 cmake ninja bison flex ];
}
