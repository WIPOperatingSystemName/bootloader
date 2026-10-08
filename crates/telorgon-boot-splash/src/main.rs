#[cfg(target_os = "linux")]
mod linux {
    use std::error::Error;
    use std::os::fd::AsFd;
    use std::path::PathBuf;

    use telorgon::boot::config::{BootConfig, MAX_CONFIG_BYTES};
    use telorgon::host::linux_boot_splash::{self, LinuxSplashConfig, LinuxSplashExit};

    pub fn run() -> Result<(), Box<dyn Error>> {
        let mut config_path = PathBuf::from("/etc/telorgon/boot.toml");
        let mut framebuffer = PathBuf::from("/dev/fb0");
        let mut target = String::from("linux");
        let mut scale = 1.0f64;
        let mut arguments = std::env::args().skip(1);
        while let Some(argument) = arguments.next() {
            if argument == "--help" || argument == "-h" {
                println!(
                    "boot-splash [--config FILE] [--target ID] [--framebuffer DEVICE] [--scale NUMBER]\n\nRun with display ownership in an initramfs. Send UTF-8 milestones on stdin:\n  status Mounting root\n  progress 2 5\n  ready\n  fail Could not mount root\n\nOnly ready confirms completion. EOF keeps the last frame and exits unsuccessfully."
                );
                return Ok(());
            }
            let value = arguments.next().ok_or("option needs a value")?;
            match argument.as_str() {
                "--config" => config_path = value.into(),
                "--framebuffer" => framebuffer = value.into(),
                "--target" => target = value,
                "--scale" => scale = value.parse()?,
                _ => return Err(format!("unknown option {argument}").into()),
            }
        }
        // Limit the read itself, rather than allocating an arbitrarily large file first.
        use std::io::Read;
        let mut text = String::new();
        std::fs::File::open(config_path)?
            .take(MAX_CONFIG_BYTES as u64 + 1)
            .read_to_string(&mut text)?;
        let configuration = BootConfig::from_toml(&text)?;
        let session = configuration
            .application()?
            .build()?
            .into_splash_session(&target)?;
        let mut options = LinuxSplashConfig::new(framebuffer);
        options.scale_factor = scale;
        let input = std::io::stdin();
        match linux_boot_splash::run_fd(session, options, input.as_fd())? {
            LinuxSplashExit::Ready => Ok(()),
            LinuxSplashExit::Failed(message) => Err(message.into()),
            LinuxSplashExit::InputClosed => Err("milestone stream closed before ready".into()),
        }
    }
}

fn main() {
    #[cfg(target_os = "linux")]
    if let Err(error) = linux::run() {
        eprintln!("boot-splash: {error}");
        std::process::exit(1);
    }
    #[cfg(not(target_os = "linux"))]
    {
        eprintln!("boot-splash requires Linux");
        std::process::exit(1);
    }
}
