use std::{
    ffi::c_void,
    io,
    os::windows::{ffi::OsStringExt, process::CommandExt},
    ptr,
    time::Duration,
};
use winreg::{enums::*, RegKey};

#[repr(C)]
struct Action {
    kind: u32,
    delay: u32,
}
#[repr(C)]
struct FailureActions {
    reset_period: u32,
    reboot_message: *mut u16,
    command: *mut u16,
    count: u32,
    actions: *mut Action,
}
#[link(name = "advapi32")]
extern "system" {
    fn OpenSCManagerW(machine: *const u16, database: *const u16, access: u32) -> *mut c_void;
    fn OpenServiceW(manager: *mut c_void, name: *const u16, access: u32) -> *mut c_void;
    fn ChangeServiceConfig2W(service: *mut c_void, level: u32, info: *const c_void) -> i32;
    fn CloseServiceHandle(handle: *mut c_void) -> i32;
}
#[link(name = "kernel32")]
extern "system" {
    fn CreateMutexW(attributes: *const c_void, owned: i32, name: *const u16) -> *mut c_void;
    fn OpenMutexW(access: u32, inherit: i32, name: *const u16) -> *mut c_void;
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> *mut c_void;
    fn QueryFullProcessImageNameW(
        process: *mut c_void,
        flags: u32,
        name: *mut u16,
        size: *mut u32,
    ) -> i32;
    fn WaitForSingleObject(handle: *mut c_void, milliseconds: u32) -> u32;
    fn GetExitCodeProcess(process: *mut c_void, code: *mut u32) -> i32;
    fn CloseHandle(handle: *mut c_void) -> i32;
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}
fn key_path(app_name: &str) -> String {
    format!("Software\\NNU\\{}\\TeachingProtection", app_name)
}

pub struct UpdatePause(*mut c_void);
impl Drop for UpdatePause {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

fn update_mutex_name(app_name: &str) -> Vec<u16> {
    wide(&format!("Global\\NNU.{}.Updating", app_name))
}

pub fn pause_for_update(app_name: &str) -> io::Result<Option<UpdatePause>> {
    if !enabled(app_name) {
        return Ok(None);
    }
    let handle = unsafe { CreateMutexW(ptr::null(), 0, update_mutex_name(app_name).as_ptr()) };
    if handle.is_null() {
        Err(io::Error::last_os_error())
    } else {
        Ok(Some(UpdatePause(handle)))
    }
}

fn updating(app_name: &str) -> bool {
    let handle = unsafe { OpenMutexW(0x100000, 0, update_mutex_name(app_name).as_ptr()) };
    if handle.is_null() {
        return io::Error::last_os_error().raw_os_error() != Some(2);
    }
    unsafe {
        CloseHandle(handle);
    }
    true
}

pub fn enabled(app_name: &str) -> bool {
    RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(key_path(app_name), KEY_READ | KEY_WOW64_64KEY)
        .and_then(|key| key.get_value::<u32, _>("CrashRecovery"))
        .map(|value| value == 1)
        .unwrap_or(false)
}

pub fn configure(app_name: &str, enable: bool) -> io::Result<()> {
    let (key, _) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .create_subkey_with_flags(key_path(app_name), KEY_READ | KEY_WRITE | KEY_WOW64_64KEY)?;
    apply_service_policy(app_name, enable)?;
    key.set_value("CrashRecovery", &u32::from(enable))
}

pub fn apply_service_policy(app_name: &str, enable: bool) -> io::Result<()> {
    let manager = unsafe { OpenSCManagerW(ptr::null(), ptr::null(), 1) };
    if manager.is_null() {
        return Err(io::Error::last_os_error());
    }
    let service = unsafe { OpenServiceW(manager, wide(app_name).as_ptr(), 2 | 0x10) };
    unsafe {
        CloseServiceHandle(manager);
    }
    if service.is_null() {
        return Err(io::Error::last_os_error());
    }
    let mut actions = [
        Action {
            kind: 1,
            delay: 5_000,
        },
        Action {
            kind: 1,
            delay: 15_000,
        },
        Action {
            kind: 1,
            delay: 60_000,
        },
        Action { kind: 0, delay: 0 },
    ];
    let info = FailureActions {
        reset_period: 3_600,
        reboot_message: ptr::null_mut(),
        command: ptr::null_mut(),
        count: if enable { actions.len() as u32 } else { 0 },
        actions: actions.as_mut_ptr(),
    };
    let result = unsafe { ChangeServiceConfig2W(service, 2, &info as *const _ as _) };
    let result = if result == 0 {
        Err(io::Error::last_os_error())
    } else {
        // Only a crash triggers SCM recovery; a clean service stop stays stopped.
        let non_crash_failures: i32 = 0;
        if unsafe { ChangeServiceConfig2W(service, 4, &non_crash_failures as *const _ as _) } == 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    };
    unsafe {
        CloseServiceHandle(service);
    }
    result
}

pub fn start_monitor() -> io::Result<()> {
    std::process::Command::new(std::env::current_exe()?)
        .args(["--nnu-watch-client", &std::process::id().to_string()])
        .creation_flags(0x08000000)
        .spawn()?;
    Ok(())
}

pub fn monitor(pid: u32, app_name: &str, service_running: impl Fn() -> bool) -> io::Result<()> {
    let executable = std::env::current_exe()?;
    let process = unsafe { OpenProcess(0x100000 | 0x1000, 0, pid) };
    if process.is_null() {
        return Err(io::Error::last_os_error());
    }
    let mut name = vec![0u16; 32_768];
    let mut length = name.len() as u32;
    let queried = unsafe { QueryFullProcessImageNameW(process, 0, name.as_mut_ptr(), &mut length) };
    let expected = executable.to_string_lossy().to_lowercase();
    let actual = std::ffi::OsString::from_wide(&name[..length as usize])
        .to_string_lossy()
        .to_lowercase();
    if queried == 0 || actual != expected {
        unsafe {
            CloseHandle(process);
        }
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Recovery target is not this client",
        ));
    }
    let mut code = 0;
    let waited = unsafe { WaitForSingleObject(process, u32::MAX) };
    let read = unsafe { GetExitCodeProcess(process, &mut code) };
    unsafe {
        CloseHandle(process);
    }
    if waited != 0 || read == 0 {
        return Err(io::Error::last_os_error());
    }
    for _ in 0..3 {
        if !should_restart(
            code,
            enabled(app_name),
            service_running(),
            updating(app_name),
        ) {
            return Ok(());
        }
        std::thread::sleep(Duration::from_secs(5));
        // Installers stop the service before replacing files; leave upgrades alone.
        if !enabled(app_name) || !service_running() || updating(app_name) {
            return Ok(());
        }
        let status = std::process::Command::new(&executable)
            .arg("--nnu-recovered")
            .creation_flags(0x08000000)
            .status()?;
        code = status.code().unwrap_or(1) as u32;
    }
    Ok(())
}

fn should_restart(exit_code: u32, enabled: bool, service_running: bool, updating: bool) -> bool {
    exit_code != 0 && enabled && service_running && !updating
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn update_lock_pauses_recovery_and_does_not_leave_a_stale_marker() {
        let name = format!("recovery-unit-test-{}", std::process::id());
        assert!(!updating(&name));
        let handle = unsafe { CreateMutexW(ptr::null(), 0, update_mutex_name(&name).as_ptr()) };
        assert!(!handle.is_null());
        let pause = UpdatePause(handle);
        assert!(updating(&name));
        drop(pause);
        assert!(!updating(&name));
    }

    #[test]
    fn only_unexpected_exit_with_opt_in_and_running_service_restarts() {
        assert!(should_restart(0xc0000005, true, true, false));
        assert!(!should_restart(0, true, true, false));
        assert!(!should_restart(1, false, true, false));
        assert!(!should_restart(1, true, false, false));
        assert!(!should_restart(1, true, true, true));
    }
}
