#!/usr/bin/env python3
"""Prepare real, RAM-based Linux boot targets without installing them."""

import argparse
import ctypes
import ctypes.util
import hashlib
import os
from pathlib import Path
import shutil
import struct
import sys
import urllib.request


PROJECT = Path(__file__).resolve().parent.parent
DISTROS = (
    {
        "id": "alpine",
        "name": "Alpine Linux 3.24.2",
        "url": "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/x86_64/alpine-virt-3.24.2-x86_64.iso",
        "sha256": "3ab424762af704b2c2a9e57df1dc37f982af260071504d977f2fb96822e7130b",
        "kernel": "boot/vmlinuz-virt",
        "initrd": "boot/initramfs-virt",
    },
    {
        "id": "tinycore",
        "name": "Tiny Core Pure64 17.1",
        "url": "https://distro.ibiblio.org/tinycorelinux/17.x/x86_64/release/TinyCorePure64-17.1.iso",
        # SHA256 pinned after matching the release's published .iso.md5.txt.
        "sha256": "5efd0a01e7014e4986738ea4e73348e3f5a71848079dbdad1c9b95c1ac3a3114",
        "kernel": "boot/vmlinuz64",
        "initrd": "boot/corepure64.gz",
    },
    {
        "id": "talos",
        "name": "Talos Linux 1.14.1",
        "url": "https://github.com/siderolabs/talos/releases/download/v1.14.1/metal-amd64-uki.efi",
        "filename": "talos-1.14.1-metal-amd64-uki.efi",
        "sha256": "c4b83b15fd273809e011ea3d48a979f7661a39e014a499afb1fa4bb640098f3d",
    },
)


def checksum(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def obtain_artifact(distro, cache, offline):
    path = cache / distro.get("filename", distro["url"].rsplit("/", 1)[1])
    if not path.is_file():
        if offline:
            raise RuntimeError(f"Missing cached boot artifact: {path}; rerun without --offline")
        temporary = path.with_name(f"{path.name}.partial")
        print(f"Downloading {distro['name']}…", flush=True)
        try:
            request = urllib.request.Request(distro["url"], headers={"User-Agent": "Telorgon-bootloader/0.1"})
            with urllib.request.urlopen(request, timeout=30) as source, temporary.open("wb") as output:
                size = 0
                while chunk := source.read(1024 * 1024):
                    size += len(chunk)
                    if size > 512 * 1024 * 1024:
                        raise RuntimeError("Boot artifact exceeded the download size limit")
                    output.write(chunk)
            if checksum(temporary) != distro["sha256"]:
                raise RuntimeError(f"Downloaded boot artifact checksum mismatch: {distro['name']}")
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    if checksum(path) != distro["sha256"]:
        raise RuntimeError(f"Cached boot artifact checksum mismatch: {path}")
    return path


def iso_library():
    name = ctypes.util.find_library("archive")
    if not name:
        raise RuntimeError("ISO extraction requires libarchive (normally included with Linux desktops)")
    library = ctypes.CDLL(name)
    signatures = {
        "archive_read_new": (ctypes.c_void_p, []),
        "archive_read_support_format_iso9660": (ctypes.c_int, [ctypes.c_void_p]),
        "archive_read_open_filename": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]),
        "archive_read_next_header": (ctypes.c_int, [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]),
        "archive_entry_pathname": (ctypes.c_char_p, [ctypes.c_void_p]),
        "archive_entry_filetype": (ctypes.c_uint, [ctypes.c_void_p]),
        "archive_entry_size": (ctypes.c_int64, [ctypes.c_void_p]),
        "archive_read_data": (ctypes.c_ssize_t, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]),
        "archive_read_free": (ctypes.c_int, [ctypes.c_void_p]),
        "archive_error_string": (ctypes.c_char_p, [ctypes.c_void_p]),
    }
    for symbol, (result, arguments) in signatures.items():
        function = getattr(library, symbol)
        function.restype = result
        function.argtypes = arguments
    return library


def extract_boot_files(library, iso, members):
    # Extract only explicitly selected regular files to fixed destinations. ISO
    # directory names, links, and permissions never become host filesystem paths.
    archive = library.archive_read_new()
    if not archive:
        raise RuntimeError("Could not allocate ISO reader")

    def check(status):
        if status < 0:
            message = library.archive_error_string(archive)
            raise RuntimeError(message.decode(errors="replace") if message else "Could not read ISO")

    try:
        check(library.archive_read_support_format_iso9660(archive))
        check(library.archive_read_open_filename(archive, os.fsencode(iso), 64 * 1024))
        remaining = dict(members)
        entry = ctypes.c_void_p()
        buffer = ctypes.create_string_buffer(64 * 1024)
        while remaining:
            status = library.archive_read_next_header(archive, ctypes.byref(entry))
            if status == 1:  # ARCHIVE_EOF
                break
            check(status)
            name = library.archive_entry_pathname(entry).decode().removeprefix("./").lower()
            if name not in remaining:
                continue
            size = library.archive_entry_size(entry)
            if library.archive_entry_filetype(entry) != 0o100000 or not 0 < size <= 256 * 1024 * 1024:
                raise RuntimeError(f"Invalid boot artifact in ISO: {name}")
            destination = remaining.pop(name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("wb") as output:
                written = 0
                while count := library.archive_read_data(archive, buffer, len(buffer)):
                    check(count)
                    written += count
                    if written > size:
                        raise RuntimeError(f"ISO artifact exceeded declared size: {name}")
                    output.write(buffer.raw[:count])
            if written != size:
                raise RuntimeError(f"Truncated ISO artifact: {name}")
        if remaining:
            raise RuntimeError(f"Missing boot files in {iso.name}: {', '.join(remaining)}")
    finally:
        library.archive_read_free(archive)


def validate_efi_kernel(path):
    with path.open("rb") as source:
        header = source.read(4096)
    if header[:2] != b"MZ" or len(header) < 64:
        raise RuntimeError(f"Kernel has no EFI stub: {path}")
    pe = struct.unpack_from("<I", header, 0x3C)[0]
    if pe + 94 > len(header) or header[pe:pe + 4] != b"PE\0\0":
        raise RuntimeError(f"Invalid EFI kernel: {path}")
    if struct.unpack_from("<H", header, pe + 4)[0] != 0x8664:
        raise RuntimeError(f"Kernel is not x86_64: {path}")
    if struct.unpack_from("<H", header, pe + 24)[0] != 0x20B or struct.unpack_from("<H", header, pe + 92)[0] != 10:
        raise RuntimeError(f"Kernel is not a PE32+ EFI application: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="Use only cached, checksum-verified boot artifacts")
    args = parser.parse_args()
    output = Path(os.environ.get("CARGO_TARGET_DIR", "target"))
    if not output.is_absolute():
        output = PROJECT / output
    output = output.resolve()
    if any(character in str(output) for character in ",\t\n\r"):
        raise RuntimeError("VM output paths must not contain commas, tabs, or newlines")
    efi = output / "x86_64-unknown-uefi/release/esp/EFI/BOOT/BOOTX64.EFI"
    if not efi.is_file():
        raise RuntimeError("Build the EFI application first: ./tools/build-efi.sh")
    library = iso_library()
    profile = output / "boot-vm/linux"
    cache = output / "boot-vm/downloads"
    cache.mkdir(parents=True, exist_ok=True)
    media = []
    for distro in DISTROS:
        artifact = obtain_artifact(distro, cache, args.offline)
        boot = profile / "esp/EFI/Linux" / distro["id"]
        if "kernel" in distro:
            extract_boot_files(library, artifact, {
                distro["kernel"]: boot / "kernel.efi",
                distro["initrd"]: boot / "initrd.img",
            })
            media.append(f"{distro['id']}\t{artifact}\n")
        else:
            boot.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(artifact, boot / "kernel.efi")
        validate_efi_kernel(boot / "kernel.efi")
        print(f"Prepared {distro['name']} ({artifact.stat().st_size // (1024 * 1024)} MiB boot artifact)")
    staged_efi = profile / "esp/EFI/BOOT/BOOTX64.EFI"
    staged_efi.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(efi, staged_efi)
    config = profile / "esp/EFI/Telorgon/boot.toml"
    config.parent.mkdir(parents=True, exist_ok=True)
    if not config.exists():
        shutil.copyfile(PROJECT / "configs/linux-vm.toml", config)
    (profile / "media.tsv").write_text("".join(media))
    print(f"Editable boot configuration: {config}")
    print("Run ./tools/run-vm.sh --no-build to choose and boot a real Linux system.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
