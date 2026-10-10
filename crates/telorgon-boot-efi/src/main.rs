#![cfg_attr(target_os = "uefi", feature(uefi_std))]

#[cfg(target_os = "uefi")]
fn main() {
    use telorgon::boot::config::{BootConfig, MAX_CONFIG_BYTES};
    use telorgon::platform::uefi::{Status, SystemTable, UefiContext, UefiError};

    // Rust's native UEFI startup initializes its allocator, single-thread TLS, and exit
    // observation before main. Keep that startup rather than calling std from a raw entry.
    let image = std::os::uefi::env::image_handle().as_ptr();
    let table = std::os::uefi::env::system_table()
        .as_ptr()
        .cast::<SystemTable>();
    let firmware = match unsafe { UefiContext::from_raw(image, table) } {
        Ok(context) => context,
        Err(error) => {
            eprintln!("Telorgon could not initialize firmware: {error}");
            std::process::exit(1);
        }
    };
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        let bytes = match firmware.read_file(r"\EFI\Telorgon\boot.toml", MAX_CONFIG_BYTES) {
            Ok(bytes) => bytes,
            Err(UefiError::Firmware { status, .. }) if status == Status::NOT_FOUND.as_usize() => {
                include_bytes!("boot.toml").to_vec()
            }
            Err(error) => return Err(error.into()),
        };
        let text = std::str::from_utf8(&bytes)?;
        let mut config = BootConfig::from_toml(text)?;
        let _warnings = config
            .load_artwork(|path, offset, length| firmware.read_file_range(path, offset, length));
        config.application()?.build()?.run_uefi_with(
            &firmware,
            telorgon::host::uefi::UefiBootOptions {
                preferred_resolution: Some((1280, 720)),
                ..Default::default()
            },
        )?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = firmware.clear_text();
        let _ = firmware.write_text(&format!(
            "Telorgon boot error:\n{error}\n\nPress a key to return to firmware.\n"
        ));
        let _ = firmware.wait_for_input(None);
    }
}

#[cfg(not(target_os = "uefi"))]
fn main() {
    eprintln!(
        "Build this executable with cargo +nightly-2026-10-06 build -p telorgon-boot-efi --release --target x86_64-unknown-uefi"
    );
    std::process::exit(1);
}
