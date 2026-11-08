use hbb_common::{
    anyhow::anyhow,
    bail,
    config::Config,
    log,
    sha2::{Digest, Sha256},
    sodiumoxide::crypto::sign,
    ResultType,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::Mutex,
    time::Duration,
};

const BASE: &str = "https://rd.nnu.cn/client-updates/";
const PUBLIC_KEY: &str = "1umorhoB3pej9Cu4Jlvi/n1JHPdLd6XxcdxDSFaWYGQ=";
const MAX_PACKAGE: u64 = 512 * 1024 * 1024;
pub const CHECK_INTERVAL: Duration = Duration::from_secs(5 * 60);
pub const RETRY_INTERVAL: Duration = Duration::from_secs(60);
pub const MIN_INTERVAL: Duration = Duration::from_secs(30);

static UPDATE_RUN: Mutex<()> = Mutex::new(());
static UPDATE_PROGRESS: Mutex<String> = Mutex::new(String::new());

fn set_progress(value: impl Into<String>) {
    if let Ok(mut progress) = UPDATE_PROGRESS.lock() {
        *progress = value.into();
    }
}

pub fn progress() -> String {
    UPDATE_PROGRESS.lock().map(|value| value.clone()).unwrap_or_default()
}

#[derive(Clone, Copy)]
enum Outcome {
    Latest,
    Waiting,
    Handoff,
}

impl Outcome {
    fn status(self) -> &'static str {
        match self {
            Self::Latest => "latest",
            Self::Waiting => "waiting",
            Self::Handoff => "handoff",
        }
    }
}

#[path = "nnu_update_external.rs"]
mod external;

#[path = "nnu_update_install.rs"]
mod install;

#[derive(Deserialize)]
struct Envelope {
    payload: String,
    signature: String,
    certificate: Option<serde_json::Value>,
}

#[derive(Deserialize)]
struct Release {
    schema: u32,
    channel: String,
    build: u64,
    version: String,
    notes: String,
    artifacts: HashMap<String, Artifact>,
}

#[derive(Deserialize)]
struct Artifact {
    name: String,
    sha256: String,
    size: u64,
    url: String,
    #[serde(default)]
    mirrors: Vec<String>,
}

fn verify_release(raw: &[u8], public_key: &str) -> ResultType<Release> {
    if raw.len() > 65536 {
        bail!("NNU update manifest too large");
    }
    let envelope: Envelope = serde_json::from_slice(raw)?;
    let payload = crate::decode64(envelope.payload)?;
    let signature = sign::Signature::from_bytes(&crate::decode64(envelope.signature)?)
        .map_err(|_| anyhow!("Invalid NNU update signature"))?;
    let key = if let Some(certificate) = &envelope.certificate {
        external::certified_key(certificate, public_key)?
    } else {
        sign::PublicKey::from_slice(&crate::decode64(public_key)?)
            .ok_or_else(|| anyhow!("Invalid NNU update public key"))?
    };
    if !sign::verify_detached(&signature, &payload, &key) {
        bail!("NNU update signature mismatch");
    }
    let release: Release = serde_json::from_slice(&payload)?;
    if envelope.certificate.is_some() {
        let claims: serde_json::Value = serde_json::from_slice(&payload)?;
        if claims["delivery"].as_str() != Some("external") || release.artifacts.values().any(|a| a.mirrors.is_empty()) {
            bail!("Certified update must use external delivery");
        }
    }
    if release.schema != 1
        || release.channel != "stable"
        || release.build == 0
        || release.build >= (1u64 << 53)
        || release.version.is_empty()
        || release.version.chars().count() > 80
        || release.notes.chars().count() > 8000
        || release.artifacts.len() != 4
    {
        bail!("Invalid NNU update manifest");
    }
    let mut names = HashSet::new();
    for (kind, extension) in [
        ("portable", ".exe"),
        ("install", ".exe"),
        ("msi", ".msi"),
        ("zip", ".zip"),
    ] {
        let artifact = release
            .artifacts
            .get(kind)
            .ok_or_else(|| anyhow!("NNU package missing"))?;
        if artifact.mirrors.len() > 3 { bail!("Too many external download mirrors"); }
        for mirror in &artifact.mirrors { external::validate_url(mirror)?; }
        if artifact.name.is_empty()
            || !artifact.name.ends_with(extension)
            || !artifact
                .name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"._-".contains(&c))
            || !names.insert(&artifact.name)
            || artifact.size == 0
            || artifact.size > MAX_PACKAGE
            || artifact.sha256.len() != 64
            || !artifact
                .sha256
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
            || artifact.url != format!("{}releases/{}/{}", BASE, release.build, artifact.name)
        {
            bail!("Invalid NNU update package");
        }
    }
    Ok(release)
}

pub fn is_nnu_server() -> bool {
    let server = Config::get_option("custom-rendezvous-server");
    let host = server.strip_suffix(":21116").unwrap_or(&server);
    host.eq_ignore_ascii_case("rd.nnu.cn") || host.eq_ignore_ascii_case("rd.0vk.com")
}

fn current_build(executable: &Path) -> ResultType<u64> {
    let directory = executable
        .parent()
        .ok_or_else(|| anyhow!("Missing application directory"))?;
    let bytes = fs::read(directory.join("data/flutter_assets/assets/nnu-release.json"))?;
    if bytes.len() > 4096 {
        bail!("Invalid installed NNU version metadata");
    }
    let metadata: serde_json::Value = serde_json::from_slice(&bytes)?;
    metadata["build"]
        .as_u64()
        .filter(|b| *b > 0 && *b < (1u64 << 53))
        .ok_or_else(|| anyhow!("Missing installed NNU build"))
}

fn user_is_idle() -> bool {
    use winapi::um::{
        sysinfoapi::GetTickCount,
        winuser::{GetLastInputInfo, LASTINPUTINFO},
    };
    let mut input = LASTINPUTINFO {
        cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32,
        dwTime: 0,
    };
    unsafe {
        GetLastInputInfo(&mut input) != 0
            && GetTickCount().wrapping_sub(input.dwTime) >= 5 * 60 * 1000
    }
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
struct PortablePlan<'a> {
    kind: &'a str,
    package_path: &'a Path,
    target_path: &'a Path,
    running_exe: &'a Path,
    digest: &'a str,
    build: u64,
    session_id: u32,
    window_state: &'static str,
}

fn apply_portable(
    kind: &str,
    package: &Path,
    artifact: &Artifact,
    build: u64,
    executable: &Path,
) -> ResultType<()> {
    use std::os::windows::{fs::OpenOptionsExt, process::CommandExt};
    let target = if kind == "portable" {
        PathBuf::from(
            std::env::var_os("NNU_PORTABLE_EXE")
                .ok_or_else(|| anyhow!("Missing portable launcher path"))?,
        )
    } else {
        executable.to_owned()
    };
    if !target.is_absolute() || !target.is_file() {
        bail!("Invalid NNU portable update target");
    }
    let directory = package
        .parent()
        .ok_or_else(|| anyhow!("Missing staging directory"))?;
    let script = directory.join("apply-update.ps1");
    let plan_path = directory.join("update-plan.json");
    let plan = PortablePlan {
        kind,
        package_path: package,
        target_path: &target,
        running_exe: executable,
        digest: &artifact.sha256,
        build,
        session_id: crate::platform::get_current_process_session_id()
            .ok_or_else(|| anyhow!("Cannot determine Windows session"))?,
        window_state: crate::platform::nnu_update_window::current(executable.to_string_lossy().as_ref()).name(),
    };
    let script_bytes = include_bytes!("../res/nnu/apply-portable-update.ps1");
    let plan_bytes = serde_json::to_vec(&plan)?;
    fs::write(&script, script_bytes)?;
    fs::write(&plan_path, &plan_bytes)?;
    let mut script_lock = fs::OpenOptions::new()
        .read(true)
        .share_mode(winapi::um::winnt::FILE_SHARE_READ)
        .open(&script)?;
    let mut plan_lock = fs::OpenOptions::new()
        .read(true)
        .share_mode(winapi::um::winnt::FILE_SHARE_READ)
        .open(&plan_path)?;
    let mut checked_script = Vec::new();
    let mut checked_plan = Vec::new();
    script_lock.read_to_end(&mut checked_script)?;
    plan_lock.read_to_end(&mut checked_plan)?;
    if checked_script != script_bytes || checked_plan != plan_bytes {
        bail!("NNU update helper changed before launch");
    }
    let powershell = PathBuf::from(
        std::env::var_os("SystemRoot").ok_or_else(|| anyhow!("Missing Windows directory"))?,
    )
    .join("System32/WindowsPowerShell/v1.0/powershell.exe");
    let _tray_icons=crate::platform::windows::nnu_hide_update_tray(executable);
    let status = std::process::Command::new(powershell)
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(script)
        .arg("-PlanPath")
        .arg(plan_path)
        .creation_flags(winapi::um::winbase::CREATE_NO_WINDOW)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?
        .wait()?;
    drop((script_lock, plan_lock));
    if !status.success() {
        bail!("NNU portable update postponed or failed; see ClientUpdates/update.log");
    }
    Ok(())
}

pub fn check_update(manually: bool) -> ResultType<()> {
    if !manually && Config::get_option("nnu-auto-update") != "Y" {
        return Ok(());
    }
    match run_update(manually)? {
        Some(Outcome::Waiting) | None => bail!("NNU update postponed"),
        _ => Ok(()),
    }
}

pub fn request_update() -> String {
    match run_update(true) {
        Ok(Some(outcome)) => outcome.status().to_owned(),
        Ok(None) => "busy".to_owned(),
        Err(error) => {
            log::warn!("NNU manual update failed: {error}");
            "failed".to_owned()
        }
    }
}

fn run_update(manually: bool) -> ResultType<Option<Outcome>> {
    let Ok(_guard) = UPDATE_RUN.try_lock() else {
        return Ok(None);
    };
    set_progress("checking");
    let result = perform_update(manually);
    set_progress(result.as_ref().map(|outcome| outcome.status()).unwrap_or("failed"));
    result.map(Some)
}

fn perform_update(manually: bool) -> ResultType<Outcome> {
    let executable = std::env::current_exe()?;
    let installed_build = current_build(&executable)?;
    let client = reqwest::blocking::Client::builder()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(1800))
        .build()?;
    let mut raw = Vec::new();
    client
        .get(format!("{}stable.json?protocol=2", BASE))
        .timeout(Duration::from_secs(30))
        .send()?
        .error_for_status()?
        .take(65537)
        .read_to_end(&mut raw)?;
    let release = verify_release(&raw, PUBLIC_KEY)?;
    if release.build <= installed_build {
        return Ok(Outcome::Latest);
    }
    if !crate::updater::has_no_active_conns() || (!manually && !user_is_idle()) {
        return Ok(Outcome::Waiting);
    }
    let installed = crate::platform::is_installed();
    if !installed && crate::platform::is_root() {
        bail!("Elevated portable clients require manual update");
    }
    let kind = if installed {
        if crate::platform::is_msi_installed()? {
            "msi"
        } else {
            "install"
        }
    } else if std::env::var_os("NNU_PORTABLE_EXE").is_some() {
        "portable"
    } else {
        "zip"
    };
    let artifact = release
        .artifacts
        .get(kind)
        .ok_or_else(|| anyhow!("Missing matching NNU package"))?;
    let directory =
        std::env::temp_dir().join(format!("nnu-client-update-{}", uuid::Uuid::new_v4()));
    fs::create_dir(&directory)?;
    let path = directory.join(&artifact.name);
    let result = (|| -> ResultType<Outcome> {
        set_progress("downloading:0");
        let mut response = if artifact.mirrors.is_empty() {
            client.get(&artifact.url).send()?.error_for_status()?
        } else {
            external::open(&artifact.mirrors)?
        };
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)?;
        let mut digest = Sha256::new();
        let mut size = 0u64;
        let mut percent = 0;
        let mut buffer = [0u8; 65536];
        loop {
            let count = response.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            size += count as u64;
            if size > artifact.size {
                bail!("NNU update download exceeds signed size");
            }
            digest.update(&buffer[..count]);
            file.write_all(&buffer[..count])?;
            let next_percent = size * 100 / artifact.size;
            if next_percent != percent {
                percent = next_percent;
                set_progress(format!("downloading:{percent}"));
            }
        }
        set_progress("verifying");
        file.sync_all()?;
        drop(file);
        if size != artifact.size || format!("{:x}", digest.finalize()) != artifact.sha256 {
            bail!("NNU package checksum mismatch");
        }
        use std::os::windows::fs::OpenOptionsExt;
        let mut package_lock = fs::OpenOptions::new()
            .read(true)
            .share_mode(winapi::um::winnt::FILE_SHARE_READ)
            .open(&path)?;
        let mut locked_digest = Sha256::new();
        loop {
            let count = package_lock.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            locked_digest.update(&buffer[..count]);
        }
        if format!("{:x}", locked_digest.finalize()) != artifact.sha256 {
            bail!("NNU update package changed before launch");
        }
        if Config::get_option("nnu-auto-update") != "Y" && !manually {
            bail!("NNU automatic update disabled");
        }
        if !crate::updater::has_no_active_conns() || (!manually && !user_is_idle()) {
            return Ok(Outcome::Waiting);
        }
        set_progress("installing");
        log::info!("Applying verified NNU build {}", release.build);
        if installed {
            install::launch(manually, kind == "msi", &release.version, &path, &artifact.sha256, artifact.size)?;
        } else {
            apply_portable(kind, &path, artifact, release.build, &executable)?;
        }
        drop(package_lock);
        Ok(Outcome::Handoff)
    })();
    if !matches!(result, Ok(Outcome::Handoff)) {
        let _ = fs::remove_file(&path);
        let _ = fs::remove_dir(&directory);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture(build: u64) -> (serde_json::Value, sign::SecretKey, String) {
        let (pk, sk) = sign::gen_keypair();
        let artifacts: serde_json::Map<String, serde_json::Value> = [("portable", "exe"), ("install", "exe"), ("msi", "msi"), ("zip", "zip")].into_iter()
            .map(|(kind, ext)| { let name = format!("test-{}.{}", kind, ext);(kind.into(), serde_json::json!({"name":name,"size":10,"sha256":"0".repeat(64),"url":format!("{}releases/{}/{}",BASE,build,name)})) }).collect();
        (
            serde_json::json!({"schema":1,"channel":"stable","build":build,"version":"NNU test","notes":"test","artifacts":artifacts}),
            sk,
            crate::encode64(pk.0),
        )
    }
    fn envelope(value: &serde_json::Value, key: &sign::SecretKey) -> Vec<u8> {
        let payload = serde_json::to_vec(value).unwrap();
        serde_json::to_vec(&serde_json::json!({"payload":crate::encode64(&payload),"signature":crate::encode64(sign::sign_detached(&payload,key).as_ref())})).unwrap()
    }
    #[test]
    fn signed_release_rejects_tampering_and_untrusted_package_urls() {
        let (mut manifest, sk, pk) = fixture(108);
        assert_eq!(
            verify_release(&envelope(&manifest, &sk), &pk)
                .unwrap()
                .build,
            108
        );
        let (_, wrong, _) = fixture(108);
        assert!(verify_release(&envelope(&manifest, &wrong), &pk).is_err());
        manifest["artifacts"]["portable"]["url"] =
            serde_json::json!("https://evil.example/test.exe");
        assert!(verify_release(&envelope(&manifest, &sk), &pk).is_err());
    }
    #[test]
    fn signed_release_rejects_paths_invalid_sizes_and_builds() {
        for field in ["name", "size", "build"] {
            let (mut manifest, sk, pk) = fixture(108);
            match field {
                "name" => manifest["artifacts"]["zip"]["name"] = serde_json::json!("../bad.zip"),
                "size" => manifest["artifacts"]["zip"]["size"] = serde_json::json!(MAX_PACKAGE + 1),
                _ => manifest["build"] = serde_json::json!(0),
            }
            assert!(verify_release(&envelope(&manifest, &sk), &pk).is_err());
        }
    }

    #[test]
    fn certified_external_release_accepts_mirrors_and_rejects_untrusted_certificates() {
        let (mut manifest, root_key, root_public) = fixture(109);
        let (online_public, online_key) = sign::gen_keypair();
        manifest["delivery"] = serde_json::json!("external");
        for value in manifest["artifacts"].as_object_mut().unwrap().values_mut() {
            value["mirrors"] = serde_json::json!(["https://files.example.com/download"]);
        }
        let certificate = envelope(&serde_json::json!({"schema":1,"purpose":"nnu-external-updates",
            "origin":"https://rd.nnu.cn","public_key":crate::encode64(online_public.0)}), &root_key);
        let mut signed: serde_json::Value = serde_json::from_slice(&envelope(&manifest, &online_key)).unwrap();
        signed["certificate"] = serde_json::from_slice(&certificate).unwrap();
        assert_eq!(verify_release(&serde_json::to_vec(&signed).unwrap(), &root_public).unwrap().build, 109);
        signed["certificate"]["signature"] = serde_json::json!(crate::encode64([0u8;64]));
        assert!(verify_release(&serde_json::to_vec(&signed).unwrap(), &root_public).is_err());
    }

    #[test]
    fn external_update_blocks_private_networks_and_invalid_redirect_urls() {
        for value in ["http://files.example.com/a", "https://127.0.0.1/a", "https://[::1]/a",
            "https://192.168.1.1/a", "https://198.18.0.1/a", "https://user:password@files.example.com/a"] {
            assert!(external::validate_url(value).is_err(), "{value}");
        }
        for ip in ["10.0.0.1", "169.254.169.254", "172.16.0.1", "100.64.0.1", "2001:db8::1", "fc00::1"] {
            assert!(!external::public_address(ip.parse().unwrap()), "{ip}");
        }
        assert!(external::validate_url("https://files.example.com/download?id=1").is_ok());
        assert!(external::public_address("8.8.8.8".parse().unwrap()));
    }
}
