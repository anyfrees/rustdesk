use hbb_common::config;

pub fn load_defaults() {
    #[cfg(windows)]
    let server_key="137858006";
    #[cfg(not(windows))]
    let server_key="LDreH+COXYXaGqA6YwCFpiZ/xw3l8mWk5YI03axe34o=";
    config::DEFAULT_SETTINGS.write().unwrap().extend(
        [
            ("custom-rendezvous-server", "rd.nnu.cn:21116"),
            ("relay-server", "rd.nnu.cn:22222"),
            ("api-server", "https://rd.nnu.cn"),
            ("key", server_key),
            ("allow-websocket", "N"),
            ("allow-auto-update", "N"),
            ("nnu-auto-update", "Y"),
            ("nnu-network-adaptation", "Y"),
            ("direct-server", "Y"),
            ("ice-servers", "stun:rd.nnu.cn:21116,stun:stun.cloudflare.com:3478,stun:stun.nextcloud.com:443"),
        ]
        .map(|(key, value)| (key.to_owned(), value.to_owned())),
    );
    config::DEFAULT_LOCAL_SETTINGS.write().unwrap().extend(
        [("enable-check-update", "N")].map(|(key, value)| (key.to_owned(), value.to_owned())),
    );
    config::OVERWRITE_SETTINGS
        .write()
        .unwrap()
        .insert("allow-auto-update".to_owned(), "N".to_owned());
    config::OVERWRITE_LOCAL_SETTINGS
        .write()
        .unwrap()
        .insert("enable-check-update".to_owned(), "N".to_owned());
}

pub fn is_nnu_server() -> bool {
    let server=config::Config::get_option("custom-rendezvous-server");
    let host=server.strip_suffix(":21116").unwrap_or(&server);
    host.eq_ignore_ascii_case("rd.nnu.cn") || host.eq_ignore_ascii_case("rd.0vk.com")
}

pub fn rendezvous_token<'a>(server: &str, key: &str, token: &'a str) -> &'a str {
    let host = server.strip_suffix(":21116").unwrap_or(server);
    if key == "137858006"
        && (host.eq_ignore_ascii_case("rd.nnu.cn") || host.eq_ignore_ascii_case("rd.0vk.com"))
    {
        // This OSS server does not authenticate API bearer tokens.
        // Keep API credentials on HTTPS instead of sending them to its rendezvous port.
        ""
    } else {
        token
    }
}

pub fn legacy_peer_signing_key(server: &str, key: &str) -> Option<&'static str> {
    let host = server.strip_suffix(":21116").unwrap_or(server);
    if key == "137858006"
        && (host.eq_ignore_ascii_case("rd.nnu.cn") || host.eq_ignore_ascii_case("rd.0vk.com"))
    {
        Some("LDreH+COXYXaGqA6YwCFpiZ/xw3l8mWk5YI03axe34o=")
    } else {
        None
    }
}

pub fn id_change_message(old_id: &str, new_id: &str, uuid: &[u8], timestamp: u64) -> Vec<u8> {
    let mut message = b"NNU-ID-CHANGE-V1\0".to_vec();
    for field in [old_id.as_bytes(), new_id.as_bytes(), uuid] {
        message.extend_from_slice(&(field.len() as u32).to_le_bytes());
        message.extend_from_slice(field);
    }
    message.extend_from_slice(&timestamp.to_le_bytes());
    message
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
