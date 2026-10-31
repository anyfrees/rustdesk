extern crate self as hbb_common;

pub mod config {
    use std::{
        collections::HashMap,
        sync::{Mutex, OnceLock, RwLock},
    };

    pub struct Settings(OnceLock<RwLock<HashMap<String, String>>>);
    impl Settings {
        pub fn read(
            &self,
        ) -> std::sync::LockResult<std::sync::RwLockReadGuard<'_, HashMap<String, String>>>
        {
            self.0.get_or_init(Default::default).read()
        }
        pub fn write(
            &self,
        ) -> std::sync::LockResult<std::sync::RwLockWriteGuard<'_, HashMap<String, String>>>
        {
            self.0.get_or_init(Default::default).write()
        }
    }
    pub static DEFAULT_SETTINGS: Settings = Settings(OnceLock::new());
    pub static DEFAULT_LOCAL_SETTINGS: Settings = Settings(OnceLock::new());
    pub fn options() -> &'static Mutex<HashMap<String, String>> {
        static OPTIONS: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();
        OPTIONS.get_or_init(Default::default)
    }
    pub static PASSWORD: Mutex<String> = Mutex::new(String::new());
    pub struct Config;
    impl Config {
        pub fn get_option(key: &str) -> String {
            options()
                .lock()
                .unwrap()
                .get(key)
                .cloned()
                .unwrap_or_default()
        }
        pub fn set_option(key: String, value: String) {
            options().lock().unwrap().insert(key, value);
        }
        pub fn has_permanent_password() -> bool {
            !PASSWORD.lock().unwrap().is_empty()
        }
        pub fn set_permanent_password(value: &str) -> bool {
            *PASSWORD.lock().unwrap() = value.to_owned();
            true
        }
    }
}

pub mod platform {
    pub static INSTALLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    pub fn is_installed() -> bool {
        INSTALLED.load(std::sync::atomic::Ordering::Relaxed)
    }
}

#[macro_export]
macro_rules! error { ($($arg:tt)*) => { eprintln!($($arg)*) }; }
pub mod log {
    pub use crate::error;
}

#[path = "../../src/nnu.rs"]
mod nnu;

#[test]
fn portable_first_start_preserves_user_choices_and_installed_devices() {
    use config::Config;
    use std::sync::atomic::Ordering;
    nnu::load_defaults();
    let defaults = config::DEFAULT_SETTINGS.read().unwrap();
    assert_eq!(defaults.get("relay-server").unwrap(), "rd.nnu.cn:22222");
    assert_eq!(defaults.get("api-server").unwrap(), "https://rd.nnu.cn");
    assert_eq!(defaults.get("allow-auto-update").unwrap(), "N");
    drop(defaults);

    nnu::initialize_portable_password();
    assert!(Config::has_permanent_password());
    assert_eq!(
        Config::get_option("verification-method"),
        "use-permanent-password"
    );
    assert_eq!(Config::get_option("approve-mode"), "password");
    Config::set_permanent_password("user-changed-password");
    nnu::initialize_portable_password();
    assert_eq!(*config::PASSWORD.lock().unwrap(), "user-changed-password");
    Config::set_permanent_password("");
    nnu::initialize_portable_password();
    assert!(
        !Config::has_permanent_password(),
        "explicitly cleared passwords must stay cleared"
    );

    config::options().lock().unwrap().clear();
    Config::set_permanent_password("existing-password");
    nnu::initialize_portable_password();
    assert_eq!(*config::PASSWORD.lock().unwrap(), "existing-password");
    assert!(Config::get_option("verification-method").is_empty());

    config::options().lock().unwrap().clear();
    Config::set_permanent_password("");
    platform::INSTALLED.store(true, Ordering::Relaxed);
    nnu::initialize_portable_password();
    assert!(!Config::has_permanent_password());
    assert!(config::options().lock().unwrap().is_empty());
}
