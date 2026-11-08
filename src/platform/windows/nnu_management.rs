use std::{ffi::c_void, io, ptr};
use winreg::{enums::*, RegKey, RegValue};

const ITERATIONS: u64 = 600_000;
const POLICY_BYTES: usize = 49;

const AUTHORIZED_EXIT: i32 = 0x4e4e55;

#[link(name = "bcrypt")]
extern "system" {
    fn BCryptOpenAlgorithmProvider(
        handle: *mut *mut c_void,
        name: *const u16,
        implementation: *const u16,
        flags: u32,
    ) -> i32;
    fn BCryptCloseAlgorithmProvider(handle: *mut c_void, flags: u32) -> i32;
    fn BCryptGenRandom(handle: *mut c_void, buffer: *mut u8, length: u32, flags: u32) -> i32;
    fn BCryptDeriveKeyPBKDF2(
        handle: *mut c_void,
        password: *const u8,
        password_len: u32,
        salt: *const u8,
        salt_len: u32,
        iterations: u64,
        result: *mut u8,
        result_len: u32,
        flags: u32,
    ) -> i32;
}

#[link(name = "user32")]
extern "system" {
    fn MessageBoxW(owner: *mut c_void, message: *const u16, caption: *const u16, flags: u32)
        -> i32;
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

pub fn notice(message: &str) {
    message_box(message, 0x10);
}

fn message_box(message: &str, flags: u32) {
    unsafe {
        MessageBoxW(
            ptr::null_mut(),
            wide(message).as_ptr(),
            wide("管理保护").as_ptr(),
            flags,
        );
    }
}

struct Pin(Vec<u16>);
impl Drop for Pin {
    fn drop(&mut self) {
        for word in &mut self.0 {
            unsafe {
                ptr::write_volatile(word, 0);
            }
        }
        std::sync::atomic::compiler_fence(std::sync::atomic::Ordering::SeqCst);
    }
}

impl Pin {
    fn len(&self) -> usize {
        self.0
            .iter()
            .position(|word| *word == 0)
            .unwrap_or(self.0.len())
    }
}

fn key_path(app_name: &str) -> String {
    format!("Software\\NNU\\{}\\TeachingProtection", app_name)
}

fn load(app_name: &str) -> io::Result<Option<Vec<u8>>> {
    let result = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(key_path(app_name), KEY_READ | KEY_WOW64_64KEY)
        .and_then(|key| key.get_raw_value("PinVerifier"));
    match result {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
        Ok(value)
            if value.vtype == REG_BINARY
                && value.bytes.len() == POLICY_BYTES
                && [1, 2].contains(&value.bytes[0]) =>
        {
            Ok(Some(value.bytes))
        }
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "管理保护配置损坏，请由系统管理员恢复。",
        )),
    }
}

pub fn status(app_name: &str) -> &'static str {
    match load(app_name) {
        Ok(None) => "disabled",
        Ok(Some(_)) => "enabled",
        Err(_) => "error",
    }
}

fn derive(pin: &Pin, salt: &[u8]) -> io::Result<[u8; 32]> {
    let mut provider = ptr::null_mut();
    let opened = unsafe {
        BCryptOpenAlgorithmProvider(&mut provider, wide("SHA256").as_ptr(), ptr::null(), 8)
    };
    if opened < 0 {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            "无法初始化 PIN 校验。",
        ));
    }
    let mut result = [0u8; 32];
    let code = unsafe {
        BCryptDeriveKeyPBKDF2(
            provider,
            pin.0.as_ptr() as *const u8,
            (pin.len() * 2) as u32,
            salt.as_ptr(),
            salt.len() as u32,
            ITERATIONS,
            result.as_mut_ptr(),
            result.len() as u32,
            0,
        )
    };
    unsafe {
        BCryptCloseAlgorithmProvider(provider, 0);
    }
    if code < 0 {
        return Err(io::Error::new(io::ErrorKind::Other, "无法校验 PIN。"));
    }
    Ok(result)
}

fn matches(pin: &Pin, policy: &[u8]) -> io::Result<bool> {
    let candidate = derive(pin, &policy[1..17])?;
    let difference = candidate
        .iter()
        .zip(&policy[17..])
        .fold(0u8, |diff, (a, b)| diff | (a ^ b));
    Ok(difference == 0)
}

fn shared_policy(pin: &str) -> io::Result<Vec<u8>> {
    if pin.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "请先在上方“使用 PIN 码解锁设置”中设置 PIN。",
        ));
    }
    let mut policy = vec![2u8; POLICY_BYTES];
    if unsafe { BCryptGenRandom(ptr::null_mut(), policy[1..17].as_mut_ptr(), 16, 2) } < 0 {
        return Err(io::Error::new(io::ErrorKind::Other, "无法生成 PIN 盐值。"));
    }
    let hash = derive(&Pin(wide(pin.trim())), &policy[1..17])?;
    policy[17..].copy_from_slice(&hash);
    Ok(policy)
}

pub fn sync_unlock_pin(app_name: &str, pin: &str) -> io::Result<()> {
    if let Some(existing) = load(app_name)? {
        if pin.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "请先关闭退出与卸载保护，再清除设置 PIN。",
            ));
        }
        if existing[0] == 2 && matches(&Pin(wide(pin.trim())), &existing)? {
            return Ok(());
        }
        let key = RegKey::predef(HKEY_LOCAL_MACHINE)
            .open_subkey_with_flags(key_path(app_name), KEY_WRITE | KEY_WOW64_64KEY)?;
        key.set_raw_value(
            "PinVerifier",
            &RegValue {
                vtype: REG_BINARY,
                bytes: shared_policy(pin)?,
            },
        )?;
    }
    Ok(())
}

pub fn authorize(app_name: &str, action: &str, interactive: bool) -> bool {
    match load(app_name) {
        Ok(None) => return true,
        Ok(Some(_)) => (),
        Err(error) => {
            if interactive {
                notice(&error.to_string());
            }
            return false;
        }
    }
    if !interactive {
        return false;
    }
    let result = std::env::current_exe().and_then(|exe| {
        std::process::Command::new(exe)
            .args(["--nnu-pin-dialog", action])
            .status()
    });
    match result {
        Ok(status) => status.code() == Some(AUTHORIZED_EXIT),
        Err(_) => {
            notice("无法打开 PIN 验证窗口，请重新启动客户端后重试。");
            false
        }
    }
}

pub fn confirm_pin(app_name: &str, pin: &str) -> String {
    let result = load(app_name).and_then(|policy| match policy {
        Some(policy) => matches(&Pin(wide(pin.trim())), &policy),
        None => Ok(true),
    });
    match result {
        // A normal Flutter exit, cancellation or startup failure must never authorize an action.
        Ok(true) => std::process::exit(AUTHORIZED_EXIT),
        Ok(false) => "PIN 不正确，请重试。".to_owned(),
        Err(_) => "无法验证 PIN，请联系系统管理员。".to_owned(),
    }
}

pub fn configure(app_name: &str, action: &str) -> io::Result<()> {
    if !["enable", "change", "disable", "recover"].contains(&action) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "未知的管理保护操作。",
        ));
    }
    // Opening HKLM for writing also enforces administrator authorization for recovery.
    let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .create_subkey_with_flags(key_path(app_name), KEY_READ | KEY_WRITE | KEY_WOW64_64KEY)?;
    if action == "recover" {
        let answer = unsafe {
            MessageBoxW(
                ptr::null_mut(),
                wide("系统管理员恢复将关闭管理保护。是否继续？").as_ptr(),
                wide("管理员恢复").as_ptr(),
                0x34 | 0x100,
            )
        };
        if answer != 6 {
            return Ok(());
        }
    } else if action == "disable" && !authorize(app_name, "关闭退出与卸载保护", true) {
        return Ok(());
    }
    if action == "disable" || action == "recover" {
        match key.delete_value("PinVerifier") {
            Ok(()) => (),
            Err(error) if error.kind() == io::ErrorKind::NotFound => (),
            Err(error) => return Err(error),
        }
        return Ok(());
    }
    #[cfg(feature = "flutter")]
    let settings_pin = crate::ipc::get_unlock_pin();
    #[cfg(not(feature = "flutter"))]
    let settings_pin = hbb_common::config::Config::get_unlock_pin();
    key.set_raw_value(
        "PinVerifier",
        &RegValue {
            vtype: REG_BINARY,
            bytes: shared_policy(&settings_pin)?,
        },
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pin_verifier_accepts_only_the_configured_pin() {
        let pin = Pin(wide("583917"));
        let salt = [31; 16];
        let mut policy = vec![1];
        policy.extend_from_slice(&salt);
        policy.extend_from_slice(&derive(&pin, &salt).unwrap());
        assert!(matches(&pin, &policy).unwrap());
        assert!(!matches(&Pin(wide("583918")), &policy).unwrap());
        assert_ne!(
            derive(&pin, &[32; 16]).unwrap(),
            derive(&pin, &salt).unwrap()
        );
    }

    #[test]
    fn protection_reuses_the_settings_pin_without_a_second_pin() {
        let policy = shared_policy("Ab12").unwrap();
        assert_eq!(policy[0], 2);
        assert!(matches(&Pin(wide("Ab12")), &policy).unwrap());
        assert!(!matches(&Pin(wide("old-pin")), &policy).unwrap());
        assert!(shared_policy("").is_err());
    }
}
