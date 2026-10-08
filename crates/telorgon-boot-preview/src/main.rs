use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use telorgon::boot::artwork::{MAX_BOOT_ARTWORK_BYTES, MAX_EFI_ARTWORK_SOURCE_BYTES};
use telorgon::boot::config::{BootConfig, MAX_CONFIG_BYTES};
use telorgon::boot::{
    BootApplication, BootResult, BootSelectionMode, BootTarget, PreviewScenario, PreviewTheme,
    TargetId,
};

fn configure_boot_ui(
    theme: PreviewTheme,
    target: &str,
    single: bool,
    show_selector: bool,
) -> BootResult<BootApplication> {
    let targets = [
        BootTarget::linux("linux", "Linux")?.detail("Daily driver · shared startup splash"),
        BootTarget::windows("windows", "Windows")?.detail("Windows Boot Manager · system splash"),
        BootTarget::custom("my-os", "My OS")?.detail("Your kernel · your interface"),
    ];
    let mut app = BootApplication::new()
        .default_target(target)
        .theme(theme)
        .selection_mode(if show_selector {
            BootSelectionMode::Always
        } else {
            BootSelectionMode::Auto
        });
    for entry in targets {
        if !single || entry.id.as_str() == target {
            app = app.target(entry);
        }
    }
    Ok(app)
}

fn inferred_esp_root(config: &Path) -> Option<PathBuf> {
    let telorgon = config.parent()?;
    let efi = telorgon.parent()?;
    if config
        .file_name()?
        .to_str()?
        .eq_ignore_ascii_case("boot.toml")
        && telorgon
            .file_name()?
            .to_str()?
            .eq_ignore_ascii_case("Telorgon")
        && efi.file_name()?.to_str()?.eq_ignore_ascii_case("EFI")
    {
        Some(efi.parent()?.to_owned())
    } else {
        None
    }
}

fn read_artwork_range(
    root: Option<&Path>,
    efi_path: &str,
    offset: u64,
    length: usize,
) -> io::Result<Vec<u8>> {
    let invalid = |message| io::Error::new(io::ErrorKind::InvalidInput, message);
    let root = root.ok_or_else(|| invalid("cannot infer the EFI volume; use --esp-root PATH"))?;
    let relative = efi_path.replace('\\', "/");
    if !relative.starts_with('/')
        || relative[1..]
            .split('/')
            .any(|part| matches!(part, "" | "." | ".."))
    {
        return Err(invalid("artwork paths must be absolute EFI volume paths"));
    }
    if length > MAX_BOOT_ARTWORK_BYTES + 1 {
        return Err(invalid("artwork read exceeds the supported size"));
    }
    let path = root.join(&relative[1..]).canonicalize()?;
    if !path.starts_with(root) {
        return Err(invalid("artwork path escapes the EFI volume"));
    }
    let mut file = File::open(path)?;
    let metadata = file.metadata()?;
    let file_length = metadata.len();
    if !metadata.is_file() || file_length > MAX_EFI_ARTWORK_SOURCE_BYTES as u64 {
        return Err(invalid("artwork source exceeds the supported size"));
    }
    if offset > file_length {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "artwork read starts past the file",
        ));
    }
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    file.take(length as u64).read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn configure_from_file(
    path: &Path,
    esp_root: Option<&Path>,
    theme: Option<PreviewTheme>,
    target: Option<&str>,
    single: bool,
    show_selector: bool,
) -> Result<BootApplication, Box<dyn std::error::Error>> {
    let path = path.canonicalize()?;
    let mut text = String::new();
    File::open(&path)?
        .take(MAX_CONFIG_BYTES as u64 + 1)
        .read_to_string(&mut text)?;
    let mut config = BootConfig::from_toml(&text)?;
    let root = esp_root
        .map(Path::to_owned)
        .or_else(|| inferred_esp_root(&path))
        .map(|root| root.canonicalize())
        .transpose()?;
    for warning in config.load_artwork(|path, offset, length| {
        read_artwork_range(root.as_deref(), path, offset, length)
    }) {
        eprintln!("boot-preview: {warning}");
    }
    if let Some(theme) = theme {
        config.theme = theme;
    }
    if let Some(target) = target {
        config.default_target = Some(target.to_owned());
    }
    if single {
        let selected = config
            .default_target
            .clone()
            .unwrap_or_else(|| config.targets[0].id.as_str().to_owned());
        config
            .targets
            .retain(|target| target.id.as_str() == selected);
    }
    if show_selector {
        config.selection_mode = BootSelectionMode::Always;
    }
    Ok(config.application()?)
}

fn main() {
    if let Err(error) = run() {
        eprintln!("boot-preview: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut theme = None;
    let mut scenario = PreviewScenario::Startup;
    let mut target = None;
    let mut single = false;
    let mut show_selector = false;
    let mut render = None;
    let mut config = None;
    let mut esp_root = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--help" | "-h" => {
                println!(
                    "Telorgon Boot Preview\n\nUsage: boot-preview [OPTIONS]\n  --config PATH       Preview a real boot.toml, including artwork\n  --esp-root PATH     EFI volume root (inferred from EFI/Telorgon/boot.toml)\n  --theme disks|voxel\n  --target ID         Select a configured target; demo: linux|windows|my-os\n  --single            Keep only the selected target and start its splash\n  --show-selector     Show the picker even for one target\n  --scenario startup|selecting|loading|os|complete|failed\n  --render PATH.png    Render one frame without opening a window\n\nStartup is the default scenario. All boot targets and progress are simulated."
                );
                return Ok(());
            }
            "--theme" => {
                theme = Some(match args.next().as_deref() {
                    Some("disks") => PreviewTheme::Disks,
                    Some("voxel") => PreviewTheme::Voxel,
                    _ => return Err("--theme requires disks or voxel".into()),
                });
            }
            "--scenario" => {
                scenario = match args.next().as_deref() {
                    Some("startup") => PreviewScenario::Startup,
                    Some("selecting") => PreviewScenario::Selecting,
                    Some("loading") => PreviewScenario::Loading,
                    Some("os") => PreviewScenario::OsStarting,
                    Some("complete") => PreviewScenario::Complete,
                    Some("failed") => PreviewScenario::Failed,
                    _ => {
                        return Err(
                            "--scenario requires startup, selecting, loading, os, complete, or failed"
                                .into(),
                        );
                    }
                }
            }
            "--target" => {
                let id = args.next().ok_or("--target requires a target ID")?;
                TargetId::new(&id)?;
                target = Some(id);
            }
            "--config" => {
                config = Some(PathBuf::from(
                    args.next().ok_or("--config requires a path")?,
                ));
            }
            "--esp-root" => {
                esp_root = Some(PathBuf::from(
                    args.next().ok_or("--esp-root requires a path")?,
                ));
            }
            "--single" => single = true,
            "--show-selector" => show_selector = true,
            "--render" => {
                render = Some(PathBuf::from(
                    args.next().ok_or("--render requires a PNG path")?,
                ))
            }
            _ => return Err(format!("unknown option {arg}; use --help").into()),
        }
    }
    let app = if let Some(config) = config {
        configure_from_file(
            &config,
            esp_root.as_deref(),
            theme,
            target.as_deref(),
            single,
            show_selector,
        )?
    } else {
        if esp_root.is_some() {
            return Err("--esp-root requires --config".into());
        }
        configure_boot_ui(
            theme.unwrap_or(PreviewTheme::Disks),
            target.as_deref().unwrap_or("linux"),
            single,
            show_selector,
        )?
    }
    .build()?;
    if let Some(path) = render {
        let frame = app.render_preview(
            scenario,
            telorgon::SizeI {
                width: 1100,
                height: 760,
            },
        )?;
        image::save_buffer_with_format(
            &path,
            &frame.pixels,
            1100,
            760,
            image::ColorType::Rgba8,
            image::ImageFormat::Png,
        )?;
        println!("Rendered {}", path.display());
    } else {
        app.preview(scenario)?;
    }
    Ok(())
}
