# MSVC tool names backed by LLVM, so msvc.cmake with USE_CLANG_CL runs on Linux
# the compiler shims pin the target, CMake probes the compiler without one
{ pkgs, llvm, arch ? "arm64" }:
let
  arm32 = arch == "arm";
  target = if arm32 then "thumbv7-pc-windows-msvc" else "arm64-pc-windows-msvc";
  asTarget = if arm32 then "thumbv7-pc-windows-msvc" else "aarch64-pc-windows-msvc";
  asName = if arm32 then "armasm" else "armasm64";
  # Windows on ARM is Thumb-2 only
  asPrologue = if arm32 then ".syntax unified\\n.thumb\\n" else "";
  major = pkgs.lib.versions.major llvm.clang-unwrapped.version;
  clang = "${llvm.clang-unwrapped}/bin";
  res = "${llvm.clang-unwrapped.lib}/lib/clang/${major}";
  # -nostdinc drops the builtin headers, arm_neon.h and friends come back last
  resdir = "-resource-dir=${res} -Xclang -idirafter -Xclang ${res}/include";
  shim = name: text: pkgs.writeShellScriptBin name text;
in [
  (shim "clang-cl" ''exec ${clang}/clang-cl ${resdir} --target=${target} "$@"'')
  # add_asm_files preprocesses with cl /EP, armasm64 below wants the GAS side of kxarm64.h
  (shim "cl" ''
    for a in "$@"; do
      case "$a" in /EP|-EP) exec ${clang}/clang-cl ${resdir} --target=${target} /U_MSC_VER /TC -Wno-unicode -Wno-unused-command-line-argument "$@" ;; esac
    done
    exec ${clang}/clang-cl ${resdir} --target=${target} "$@"
  '')
  # armasm(64) -nologo -o <obj> <src>, the source is already preprocessed
  (shim asName ''
    out= src=
    while [ $# -gt 0 ]; do
      case "$1" in
        -nologo|/nologo) ;;
        -o|/o) out="$2"; shift ;;
        *) src="$1" ;;
      esac
      shift
    done
    # spec2def stubs come out in armasm syntax, rewrite the few forms it emits
    if head -1 "$src" | grep -q '^; File generated automatically'; then
      ${pkgs.gnused}/bin/sed -E -e 's|^;|//|' -e 's/^\s*AREA \|\.text\|.*/${asPrologue}.text\n.p2align 2/' \
        -e 's/^\s*EXPORT \|([^|]*)\|.*/.global "\1"/' -e 's/^\|([^|]*)\|\s*$/"\1":/' -e 's/^\s*IMPORT ([^,]+), WEAK (\S+)/.weak \1\n.set \1, \2/' -e '/^\s*END\s*$/d' \
        "$src" | ${clang}/clang --target=${asTarget} -c -x assembler - -o "$out"
      exit
    fi
    # a bare armasm END closes files that have nothing for GAS
    ${pkgs.gnused}/bin/sed -E '/^\s*END\s*$/d' "$src" | ${clang}/clang --target=${asTarget} -c -x assembler - -o "$out"
  '')
  # lld-link has no ! to clear section flags, .rsrc is never D or P to begin with
  (shim "link" ''
    args=()
    for a in "$@"; do
      case "$a" in /SECTION:*,!*|/section:*,!*) ;; *) args+=("$a") ;; esac
    done
    exec ${llvm.lld}/bin/lld-link "''${args[@]}"
  '')
  (shim "lib" ''exec ${llvm.llvm}/bin/llvm-lib "$@"'')
  # rc.exe reads 8-bit sources as ANSI 1252, llvm-rc defaults to ASCII only
  (shim "rc" ''exec ${llvm.llvm}/bin/llvm-rc /C 1252 "$@"'')
  llvm.lld
  llvm.llvm
]
