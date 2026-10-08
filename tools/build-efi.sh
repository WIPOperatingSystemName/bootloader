#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repo_root"

usage() {
    cat <<'USAGE'
Usage: ./tools/build-efi.sh [Cargo build options]

Build the Telorgon EFI application and stage a bootable EFI system partition.
Additional options such as --offline are forwarded to cargo build.
  --help, -h  Show this help.

Output: target/x86_64-unknown-uefi/release/esp/EFI/BOOT/BOOTX64.EFI
Configuration: target/x86_64-unknown-uefi/release/esp/EFI/Telorgon/boot.toml
An existing staged configuration is preserved.

Overrides: CARGO_TARGET_DIR, TELORGON_EFI_TOOLCHAIN
The default toolchain is nightly-2026-10-06.
USAGE
}

for argument in "$@"; do
    case "$argument" in
        --help|-h) usage; exit 0 ;;
    esac
done

# Rust's UEFI std startup owns allocator initialization. The env accessors currently
# require this pinned nightly; no change to the workspace's default toolchain is made.
toolchain="${TELORGON_EFI_TOOLCHAIN:-nightly-2026-10-06}"
target="x86_64-unknown-uefi"
output_root="${CARGO_TARGET_DIR:-$repo_root/target}"
if [[ "$output_root" != /* ]]; then
    output_root="$repo_root/$output_root"
fi
esp="$output_root/$target/release/esp"

cargo "+$toolchain" build --locked --release --target "$target" -p telorgon-boot-efi "$@"
mkdir -p -- "$esp/EFI/BOOT" "$esp/EFI/Telorgon"
cp -- "$output_root/$target/release/boot-efi.efi" "$esp/EFI/BOOT/BOOTX64.EFI"
if [[ ! -e "$esp/EFI/Telorgon/boot.toml" ]]; then
    cp -- crates/telorgon-boot-efi/src/boot.toml "$esp/EFI/Telorgon/boot.toml"
fi
printf 'EFI application: %s\nEditable configuration: %s\n' "$esp/EFI/BOOT/BOOTX64.EFI" "$esp/EFI/Telorgon/boot.toml"
