use hbb_common::config;

pub fn load_defaults() {
    config::DEFAULT_SETTINGS.write().unwrap().extend(
        [
            ("custom-rendezvous-server", "rd.nnu.cn:21116"),
            ("relay-server", "rd.nnu.cn:22222"),
            ("api-server", "https://rd.nnu.cn"),
            ("key", "137858006"),
            ("allow-auto-update", "N"),
        ]
        .map(|(key, value)| (key.to_owned(), value.to_owned())),
    );
    config::DEFAULT_LOCAL_SETTINGS.write().unwrap().extend(
        [("enable-check-update", "N")]
            .map(|(key, value)| (key.to_owned(), value.to_owned())),
    );
}

#[cfg(windows)]
pub fn initialize_portable_password() {
    use config::Config;

    const MARKER: &str = "nnu-portable-password-initialized";
    if crate::platform::is_installed() || Config::get_option(MARKER) == "Y" {
        return;
    }
    // Existing passwords, including presets, belong to the user.
    if Config::has_permanent_password() {
        Config::set_option(MARKER.to_owned(), "Y".to_owned());
        return;
    }
    let Some(password) = option_env!("NNU_PORTABLE_PASSWORD").filter(|value| !value.is_empty())
    else {
        return;
    };
    if !Config::set_permanent_password(password) {
        hbb_common::log::error!("Failed to initialize NNU portable password");
        return;
    }
    Config::set_option(
        "verification-method".to_owned(),
        "use-permanent-password".to_owned(),
    );
    Config::set_option("approve-mode".to_owned(), "password".to_owned());
    Config::set_option(MARKER.to_owned(), "Y".to_owned());
}
