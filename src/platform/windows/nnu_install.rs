use std::sync::Mutex;

static STATUS: Mutex<String> = Mutex::new(String::new());

pub fn start() -> String {
    let mut status = STATUS.lock().unwrap();
    if *status == "installing" {
        return status.clone();
    }
    *status = "installing".to_owned();
    std::thread::spawn(|| {
        let result = request();
        *STATUS.lock().unwrap() = result;
    });
    status.clone()
}

pub fn status() -> String {
    STATUS.lock().unwrap().clone()
}

pub fn request() -> String {
    use hbb_common::{config, log};
    if config::is_disable_installation() {
        return "disabled".to_owned();
    }
    if super::is_installed() {
        return "installed".to_owned();
    }
    if !crate::updater::has_no_active_conns() {
        return "busy".to_owned();
    }
    let options = super::get_silent_install_options(None);
    match super::install_me(options, String::new(), true, false) {
        Ok(()) if super::is_installed() => "installed".to_owned(),
        Ok(()) => {
            log::warn!("Silent install completed without an installed executable");
            "failed".to_owned()
        }
        Err(error) => {
            log::warn!("Silent installation did not complete: {error}");
            "failed".to_owned()
        }
    }
}
