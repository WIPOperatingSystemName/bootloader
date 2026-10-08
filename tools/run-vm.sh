#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repo_root"

usage() {
    cat <<'USAGE'
Usage: ./tools/run-vm.sh [--offline] [--no-build] [--linux|--sample]
                         [--boot ID] [--serial] [--headless] [--cpus N]

Build the Telorgon EFI application and open its menu in a QEMU window.
  --offline   Build using cached Cargo dependencies.
  --no-build  Launch the existing staged EFI application without rebuilding.
  --linux     Require the prepared real Linux VM profile.
  --sample    Use the original sample target configuration.
  --boot ID   Boot one Linux profile target automatically.
  --serial    Show the guest serial console in this terminal.
  --headless  Run without a window, with the serial console (Ctrl+C stops it).
  --cpus N    Allocate N virtual CPUs (default: up to 8 host CPUs).
  --help      Show this help.

The staged EFI/Telorgon/boot.toml is preserved. Each run uses a disposable
private copy of the boot disk and firmware settings; the originals are untouched.
The prepared target/boot-vm/linux profile is selected when present. Its media.tsv
lists target IDs and absolute ISO paths, separated by one tab; CDs are read-only.

Overrides: CARGO_TARGET_DIR, QEMU_SYSTEM_X86_64, OVMF_CODE, OVMF_VARS,
           QEMU_DATA_DIR, QEMU_DISPLAY (default: gtk,gl=off),
           QEMU_ACCEL (default: kvm:tcg; also accepts kvm or tcg),
           QEMU_CPUS (same as --cpus), QEMU_CPU (CPU model override).
The default checks KVM, using the host CPU model when available. Otherwise,
it uses multithreaded TCG CPU emulation with the max CPU model.
The EFI renderer currently draws on one CPU; extra CPUs do not parallelize it.
With TCG emulation, drawing the first menu can still take about a minute.
Set both OVMF_CODE and OVMF_VARS to a matching firmware pair when overriding.
If system QEMU is absent, a prepared target/boot-vm/qemu-runtime is used.
No packages are downloaded or installed by this script.
USAGE
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

build=true
offline=false
display="${QEMU_DISPLAY:-gtk,gl=off}"
acceleration="${QEMU_ACCEL:-kvm:tcg}"
cpus="${QEMU_CPUS:-}"
profile=auto
boot_target=
serial=none
while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline) offline=true ;;
        --no-build) build=false ;;
        --headless) display=none; serial=stdio ;;
        --serial) serial=stdio ;;
        --linux|--sample)
            [[ "$profile" == auto || "$profile" == "${1#--}" ]] || die "Choose either --linux or --sample."
            profile="${1#--}"
            ;;
        --boot)
            [[ $# -ge 2 ]] || die "--boot requires a target ID."
            boot_target="$2"
            [[ "$boot_target" =~ ^[a-zA-Z0-9_.-]{1,64}$ ]] || die "--boot requires a valid target ID."
            shift
            ;;
        --cpus)
            [[ $# -ge 2 ]] || die "--cpus requires a positive integer."
            cpus="$2"
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: $1. Use --help for usage." ;;
    esac
    shift
done
case "$acceleration" in
    kvm:tcg|kvm|tcg) ;;
    *) die "QEMU_ACCEL must be kvm:tcg, kvm, or tcg." ;;
esac
if [[ -z "$cpus" ]]; then
    host_cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
    [[ "$host_cpus" =~ ^[1-9][0-9]*$ ]] || host_cpus=1
    cpus=8
    if (( host_cpus < cpus )); then
        cpus="$host_cpus"
    fi
fi
[[ "$cpus" =~ ^[1-9][0-9]*$ ]] || die "QEMU_CPUS/--cpus must be a positive integer."

output_root="${CARGO_TARGET_DIR:-$repo_root/target}"
if [[ "$output_root" != /* ]]; then
    output_root="$repo_root/$output_root"
fi
original_esp="$output_root/x86_64-unknown-uefi/release/esp"
linux_profile="$output_root/boot-vm/linux"
if [[ "$profile" == auto ]]; then
    if [[ -f "$linux_profile/esp/EFI/Telorgon/boot.toml" ]]; then
        profile=linux
    else
        profile=sample
    fi
fi
esp="$original_esp"
media_paths=()
if [[ "$profile" == linux ]]; then
    esp="$linux_profile/esp"
    [[ -f "$esp/EFI/Telorgon/boot.toml" && -r "$esp/EFI/Telorgon/boot.toml" ]] || die "The Linux VM profile is missing. Prepare $esp/EFI/Telorgon/boot.toml first."
    manifest="$linux_profile/media.tsv"
    [[ -f "$manifest" && -r "$manifest" ]] || die "The Linux VM media manifest is missing: $manifest"
    declare -A media_ids=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *$'\t'* ]] || die "Each media.tsv row must contain a target ID, one tab, and an absolute ISO path."
        media_id="${line%%$'\t'*}"
        media_path="${line#*$'\t'}"
        [[ "$media_id" =~ ^[a-zA-Z0-9_.-]{1,64}$ ]] || die "Invalid media target ID: $media_id"
        [[ -z "${media_ids[$media_id]:-}" ]] || die "Duplicate media target ID: $media_id"
        [[ "$media_path" == /* && "$media_path" != *$'\t'* && "$media_path" != *$'\r'* ]] || die "Invalid absolute ISO path for $media_id."
        [[ "$media_path" != *,* ]] || die "QEMU drive paths must not contain commas: $media_path"
        [[ -f "$media_path" && -r "$media_path" ]] || die "Cannot read the ISO for $media_id: $media_path"
        media_ids[$media_id]=1
        media_paths+=("$media_path")
    done < "$manifest"
    # q35 provides six SATA/IDE ports; the private EFI boot disk uses the first.
    (( ${#media_paths[@]} <= 5 )) || die "The q35 VM supports at most five ISO images alongside its boot disk."
elif [[ -n "$boot_target" ]]; then
    die "--boot requires the prepared Linux VM profile; it cannot be used with --sample."
fi
local_runtime="$output_root/boot-vm/qemu-runtime"
using_local_runtime=false

if [[ -n "${QEMU_SYSTEM_X86_64:-}" ]]; then
    qemu="$(command -v -- "$QEMU_SYSTEM_X86_64")" || die "Cannot execute QEMU_SYSTEM_X86_64=$QEMU_SYSTEM_X86_64."
elif qemu="$(command -v qemu-system-x86_64)"; then
    :
elif [[ -x "$local_runtime/usr/bin/qemu-system-x86_64" ]]; then
    qemu="$local_runtime/usr/bin/qemu-system-x86_64"
    using_local_runtime=true
else
    die "qemu-system-x86_64 is missing. On Ubuntu install qemu-system-x86 and qemu-system-gui, or set QEMU_SYSTEM_X86_64."
fi

if $using_local_runtime; then
    export LD_LIBRARY_PATH="$local_runtime/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export QEMU_MODULE_DIR="${QEMU_MODULE_DIR:-$local_runtime/usr/lib/x86_64-linux-gnu/qemu}"
fi
data_dir="${QEMU_DATA_DIR:-}"
if [[ -z "$data_dir" ]] && $using_local_runtime; then
    data_dir="$local_runtime/usr/share/qemu"
fi
if [[ -n "$data_dir" && ! -d "$data_dir" ]]; then
    die "QEMU data directory does not exist: $data_dir"
fi

if [[ "$acceleration" == kvm:tcg ]]; then
    # Probe the accelerator without firmware or disks before choosing a CPU
    # model: the host model cannot be used by the TCG fallback.
    if [[ -r /dev/kvm && -w /dev/kvm ]] &&
        printf 'quit\n' | "$qemu" -machine none -accel kvm -nodefaults \
            -display none -monitor stdio -S >/dev/null 2>&1; then
        acceleration=kvm
    else
        acceleration=tcg
    fi
fi
cpu_model="${QEMU_CPU:-}"
if [[ -z "$cpu_model" ]]; then
    if [[ "$acceleration" == kvm ]]; then
        cpu_model=host
    else
        cpu_model=max
    fi
fi
accelerator_arguments=(-accel kvm)
if [[ "$acceleration" == tcg ]]; then
    accelerator_arguments=(-accel tcg,thread=multi)
fi

code="${OVMF_CODE:-}"
vars="${OVMF_VARS:-}"
if [[ -n "$code" || -n "$vars" ]]; then
    [[ -n "$code" && -n "$vars" ]] || die "Set both OVMF_CODE and OVMF_VARS to a matching firmware pair."
else
    firmware_dirs=(/usr/share/OVMF /usr/share/edk2/ovmf /usr/share/edk2/x64 /usr/share/edk2-ovmf/x64 /usr/share/qemu)
    if $using_local_runtime; then
        firmware_dirs=("$local_runtime/usr/share/OVMF" "${firmware_dirs[@]}")
    fi
    for directory in "${firmware_dirs[@]}"; do
        for suffix in _4M .4m ''; do
            candidate_code="$directory/OVMF_CODE$suffix.fd"
            candidate_vars="$directory/OVMF_VARS$suffix.fd"
            if [[ -r "$candidate_code" && -r "$candidate_vars" ]]; then
                code="$candidate_code"
                vars="$candidate_vars"
                break 2
            fi
        done
    done
    [[ -n "$code" ]] || die "Unsigned OVMF firmware is missing. On Ubuntu install ovmf-generic, or set OVMF_CODE and OVMF_VARS."
fi
[[ -f "$code" && -r "$code" ]] || die "Cannot read OVMF code: $code"
[[ -f "$vars" && -r "$vars" ]] || die "Cannot read OVMF variable template: $vars"

# QEMU's -drive argument treats commas as option delimiters, including in paths.
for drive_path in "$esp" "$code" "$output_root"; do
    [[ "$drive_path" != *,* ]] || die "QEMU drive paths must not contain commas: $drive_path"
done

display_backend="${display%%,*}"
if [[ "$display_backend" != none ]]; then
    display_backends="$("$qemu" -display help 2>&1)" || die "QEMU could not list display backends: $display_backends"
    display_available=false
    while IFS= read -r backend; do
        if [[ "${backend//[[:space:]]/}" == "$display_backend" ]]; then
            display_available=true
            break
        fi
    done <<< "$display_backends"
    $display_available || die "QEMU display '$display_backend' is unavailable. On Ubuntu install qemu-system-gui; alternatively set QEMU_DISPLAY=sdl or use --headless."
    if [[ "$display_backend" == gtk || "$display_backend" == sdl ]]; then
        [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] || die "No desktop display is available. Run this command from a terminal in your desktop session, or use --headless."
    fi
fi

if $build; then
    build_arguments=()
    if $offline; then
        build_arguments+=(--offline)
    fi
    "$repo_root/tools/build-efi.sh" "${build_arguments[@]}"
fi
[[ -f "$original_esp/EFI/BOOT/BOOTX64.EFI" ]] || die "The EFI application is missing at $original_esp/EFI/BOOT/BOOTX64.EFI. Run without --no-build to build it."

mkdir -p -- "$output_root/boot-vm"
run_dir="$(mktemp -d -- "$output_root/boot-vm/run.XXXXXXXX")"
trap 'rm -rf -- "$run_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -- "$vars" "$run_dir/OVMF_VARS.fd"
# QEMU's virtual FAT disk needs a writable block backend. Only this private copy
# is writable. Dereference symlinks so they cannot point back at staged files.
cp -aL -- "$esp" "$run_dir/esp"
if [[ "$profile" == linux ]]; then
    mkdir -p -- "$run_dir/esp/EFI/BOOT"
    cp -- "$original_esp/EFI/BOOT/BOOTX64.EFI" "$run_dir/esp/EFI/BOOT/BOOTX64.EFI"
fi
if [[ -n "$boot_target" ]]; then
    command -v python3 >/dev/null || die "--boot requires Python 3.11 or newer with tomllib."
    python3 - "$run_dir/esp/EFI/Telorgon/boot.toml" "$boot_target" <<'PY'
import json
import pathlib
import sys

try:
    import tomllib
except ImportError:
    sys.exit("Error: --boot requires Python 3.11 or newer with tomllib.")

path = pathlib.Path(sys.argv[1])
target_id = sys.argv[2]
try:
    config = tomllib.loads(path.read_text(encoding="utf-8"))
    if set(config) - {"theme", "selection", "default", "targets"}:
        raise ValueError("the profile contains unsupported configuration fields")
    targets = config.get("targets", [])
    if not isinstance(targets, list) or not all(isinstance(target, dict) for target in targets):
        raise ValueError("targets must be an array of tables")
    matches = [target for target in targets if target.get("id") == target_id]
    if len(matches) != 1:
        raise ValueError(f"target {target_id!r} must appear exactly once in the profile")
    selected = matches[0]
    fields = ("id", "name", "kind", "detail", "image", "arguments", "icon", "splash", "embedded_splash")
    if set(selected) - set(fields):
        raise ValueError("the selected target contains unsupported fields")
    if not {"id", "name"}.issubset(selected):
        raise ValueError("the selected target needs id and name")
    theme = config.get("theme", "disks")
    if not isinstance(theme, str) or not all(
        isinstance(value, bool) if field == "embedded_splash" else isinstance(value, str)
        for field, value in selected.items()
    ):
        raise ValueError("boot configuration fields must contain strings, except embedded_splash (boolean)")
    quote = lambda value: json.dumps(value, ensure_ascii=False)
    lines = [f"theme = {quote(theme)}", 'selection = "auto"', f"default = {quote(target_id)}", "", "[[targets]]"]
    lines.extend(f"{field} = {quote(selected[field])}" for field in fields if field in selected)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot select boot target: {error}")
PY
fi

arguments=(
    -name 'Telorgon EFI preview'
    -machine q35
    "${accelerator_arguments[@]}"
    -cpu "$cpu_model"
    -smp "cpus=$cpus,sockets=1,cores=$cpus,threads=1"
    -m 2048
    -nodefaults
    -vga std
    -no-reboot
    -display "$display"
    -serial "$serial"
    -monitor none
    -nic none
    -drive "if=pflash,format=raw,readonly=on,file=$code"
    -drive "if=pflash,format=raw,file=$run_dir/OVMF_VARS.fd"
    -drive "id=bootesp,if=none,format=raw,file=fat:rw:$run_dir/esp"
    -device ide-hd,drive=bootesp,bus=ide.0,bootindex=1
    -device qemu-xhci,id=xhci
    -device usb-kbd,bus=xhci.0
)
media_index=1
for media_path in "${media_paths[@]}"; do
    arguments+=(
        -drive "id=media$media_index,if=none,format=raw,readonly=on,media=cdrom,file=$media_path"
        -device "ide-cd,drive=media$media_index,bus=ide.$media_index"
    )
    (( media_index += 1 ))
done
if [[ -n "$data_dir" ]]; then
    arguments+=(-L "$data_dir")
fi

printf 'Starting Telorgon in QEMU (%s; acceleration: %s; CPUs: %s; model: %s).\nConfiguration: %s\n' "$display" "$acceleration" "$cpus" "$cpu_model" "$esp/EFI/Telorgon/boot.toml"
if [[ -n "$boot_target" ]]; then
    printf 'Automatically booting Linux profile target: %s\n' "$boot_target"
fi
if [[ "$acceleration" == tcg ]]; then
    printf 'With TCG CPU emulation, the first menu can take about a minute to appear.\n'
fi
if [[ "$display_backend" != none ]]; then
    printf 'Use arrows and Enter to select a target; T changes the theme. Close the window to stop.\n'
fi
"$qemu" "${arguments[@]}"
