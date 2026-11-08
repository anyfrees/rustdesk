use hbb_common::{bail, ResultType};
use std::path::PathBuf;

pub(super) fn launch(manually: bool, msi: bool, version: &str, package: &PathBuf, sha256: &str, size: u64) -> ResultType<()> {
    if !manually || crate::platform::is_root() {
        if !crate::updater::update_new_version(msi, version, package, sha256) {
            bail!("NNU installer could not be started");
        }
        return Ok(());
    }
    let package = package.to_str().ok_or_else(|| std::io::Error::new(
        std::io::ErrorKind::InvalidInput, "Invalid installer path"))?;
    if msi {
        crate::platform::update_me_msi(package, sha256, true)
    } else {
        crate::platform::update_to_verified(package, sha256, size)
    }
}
