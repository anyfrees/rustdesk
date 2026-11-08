use std::path::Path;
use winapi::{
    shared::{minwindef::*, windef::HWND},
    um::{
        handleapi::CloseHandle,
        processthreadsapi::OpenProcess,
        winbase::QueryFullProcessImageNameW,
        winnt::PROCESS_QUERY_LIMITED_INFORMATION,
        winuser::*,
    },
};

// tray-icon 0a5835b: these messages call set_visible(false/true) on its UI thread.
const HIDE_ICON: UINT = 6006;
const SHOW_ICON: UINT = 6005;

pub(crate) struct HiddenTrayIcons(Vec<(HWND, DWORD)>);

impl Drop for HiddenTrayIcons {
    fn drop(&mut self) {
        for &(window, owner) in &self.0 {
            let mut current = 0;
            unsafe { GetWindowThreadProcessId(window, &mut current) };
            if current == owner && unsafe { IsWindow(window) } != 0 {
                send_visibility(window, SHOW_ICON);
            }
        }
    }
}

fn send_visibility(window: HWND, message: UINT) -> bool {
    let mut result = 0;
    unsafe {
        SendMessageTimeoutW(
            window, message, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, &mut result,
        ) != 0
    }
}

pub(crate) fn hide_for_update(executable: &Path) -> HiddenTrayIcons {
    struct Search<'a> {
        executable: &'a Path,
        hidden: Vec<(HWND, DWORD)>,
    }
    unsafe extern "system" fn visit(window: HWND, parameter: LPARAM) -> BOOL {
        let search = &mut *(parameter as *mut Search<'_>);
        let mut class = [0u16; 64];
        let count = GetClassNameW(window, class.as_mut_ptr(), class.len() as i32);
        if String::from_utf16_lossy(&class[..count.max(0) as usize]) != "tray_icon_app" {
            return 1;
        }
        let mut owner = 0;
        GetWindowThreadProcessId(window, &mut owner);
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, owner);
        if process.is_null() {
            return 1;
        }
        let mut name = [0u16; 32768];
        let mut length = name.len() as DWORD;
        let found = QueryFullProcessImageNameW(process, 0, name.as_mut_ptr(), &mut length);
        CloseHandle(process);
        if found != 0 {
            let image = String::from_utf16_lossy(&name[..length as usize]);
            if image.eq_ignore_ascii_case(&search.executable.to_string_lossy()) {
                if send_visibility(window, HIDE_ICON) {
                    search.hidden.push((window, owner));
                } else {
                    hbb_common::log::warn!("Could not hide tray icon before updating (PID {owner})");
                }
            }
        }
        1
    }
    let mut search = Search { executable, hidden: Vec::new() };
    if unsafe { EnumWindows(Some(visit), &mut search as *mut _ as LPARAM) } == 0 {
        hbb_common::log::warn!("Could not enumerate tray windows before updating: {}", std::io::Error::last_os_error());
    }
    HiddenTrayIcons(search.hidden)
}
