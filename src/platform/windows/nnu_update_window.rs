use std::collections::HashMap;
use winapi::{shared::{minwindef::*,windef::*},um::winuser::*};

#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub enum State { Hidden, Minimized, Maximized, Normal }

impl State {
    pub fn name(self)->&'static str {
        match self {Self::Hidden=>"hidden",Self::Minimized=>"minimized",Self::Maximized=>"maximized",Self::Normal=>"normal"}
    }
    pub fn args(self)->Vec<&'static str> {
        match self {Self::Hidden=>vec!["--nnu-update-window=hidden"],Self::Minimized=>vec!["--nnu-update-window=minimized"],
            Self::Maximized=>vec!["--nnu-update-window=maximized"],Self::Normal=>vec!["--nnu-update-window=normal"]}
    }
}

pub fn startup_argument(argument:&str)->bool {
    ["--nnu-update-window=hidden","--nnu-update-window=minimized","--nnu-update-window=maximized","--nnu-update-window=normal"].contains(&argument)
}

pub fn capture(pids:&[u32])->HashMap<u32,State> {
    unsafe extern "system" fn visit(window:HWND,parameter:LPARAM)->BOOL {
        let states=&mut *(parameter as *mut HashMap<u32,State>);
        let mut pid=0;
        GetWindowThreadProcessId(window,&mut pid);
        if !states.contains_key(&pid) || !GetWindow(window,GW_OWNER).is_null() { return 1; }
        let mut class=[0u16;128];
        let size=GetClassNameW(window,class.as_mut_ptr(),class.len() as i32);
        let class=String::from_utf16_lossy(&class[..size.max(0) as usize]);
        if !class.starts_with("FLUTTER_RUNNER") && !class.starts_with("SciterWindow") { return 1; }
        let state=if IsWindowVisible(window)==0 {State::Hidden} else if IsIconic(window)!=0 {State::Minimized}
            else if IsZoomed(window)!=0 {State::Maximized} else {State::Normal};
        if states.get(&pid).map(|old| priority(state) > priority(*old)).unwrap_or(false) {
            states.insert(pid,state);
        }
        1
    }
    let mut states=pids.iter().map(|pid|(*pid,State::Hidden)).collect::<HashMap<_,_>>();
    if unsafe { EnumWindows(Some(visit),&mut states as *mut _ as LPARAM) }==0 {
        hbb_common::log::warn!("Could not capture update window state: {}",std::io::Error::last_os_error());
    }
    states
}

fn priority(state:State)->u8 {
    match state {State::Hidden=>0,State::Minimized=>1,State::Normal=>2,State::Maximized=>3}
}

pub fn current(executable:&str)->State {
    let states=capture(&main_pids(executable));
    [State::Normal,State::Maximized,State::Minimized,State::Hidden].into_iter().find(|state|states.values().any(|value|value==state)).unwrap_or(State::Hidden)
}

pub fn main_pids(executable:&str)->Vec<u32> {
    let name=std::path::Path::new(executable).file_name().map(|name|name.to_string_lossy().into_owned()).unwrap_or_default();
    let mut pids=crate::platform::get_pids_of_process_with_args::<_,&str>(&name,&[]).into_iter().map(|pid|pid.as_u32()).collect::<Vec<_>>();
    for argument in ["--nnu-update-window=hidden","--nnu-update-window=minimized","--nnu-update-window=maximized","--nnu-update-window=normal"] {
        pids.extend(crate::platform::get_pids_of_process_with_args(&name,&[argument]).into_iter().map(|pid|pid.as_u32()));
    }
    pids.sort_unstable();pids.dedup();pids
}

pub fn apply_startup(window:HWND)->bool {
    let state=std::env::args().find_map(|argument|match argument.as_str() {
        "--nnu-update-window=hidden"=>Some(SW_HIDE),"--nnu-update-window=minimized"=>Some(SW_SHOWMINNOACTIVE),
        "--nnu-update-window=maximized"=>Some(SW_SHOWMAXIMIZED),
        "--nnu-update-window=normal"=>Some(SW_SHOWNORMAL),_=>None,
    });
    if let Some(state)=state {unsafe { ShowWindow(window,state); }true} else {false}
}

pub(super) fn msi_properties() -> String {
    let restore = current(&super::get_install_info().3);
    format!(" /qn LAUNCH_TRAY_APP=Y NNU_UPDATE_WINDOW={}", restore.name())
}
