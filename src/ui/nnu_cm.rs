use std::{mem, ptr, sync::Once};
use winapi::{
    shared::{minwindef::*, windef::*},
    um::{libloaderapi::{GetModuleHandleW, GetProcAddress}, wingdi::*, winuser::*},
};

#[derive(Default)]
pub(super) struct Frame {
    mode: i32,
    dock: Option<RECT>,
}

#[repr(C)]
struct Blur { flags:DWORD,enabled:BOOL,region:HRGN,transition:BOOL }
#[link(name="dwmapi")]
extern "system" {
    fn DwmIsCompositionEnabled(enabled:*mut BOOL)->i32;
    fn DwmEnableBlurBehindWindow(window:HWND,blur:*const Blur)->i32;
}

fn set_glass(window:HWND,mode:i32,width:i32,height:i32,dpi:f64) {
    if !Frame::glass_supported() { return; }
    unsafe {
        let inset=(16.*dpi).round() as i32;
        let radius=(48.*dpi).round() as i32;
        let enabled=mode==1 || mode==3 || mode==4;
        let region=if enabled {CreateRoundRectRgn(inset,inset,width-inset,height-inset,radius,radius)} else {ptr::null_mut()};
        let blur=Blur {flags:3,enabled:enabled as BOOL,region,transition:0};
        let result=DwmEnableBlurBehindWindow(window,&blur);
        if !region.is_null() {DeleteObject(region as _);}
        if result<0 {hbb_common::log::trace!("Desktop glass unavailable for certified window: {result}");}
    }
}

pub(super) fn load_font() {
    static LOAD: Once = Once::new();
    LOAD.call_once(|| {
        let font = include_bytes!("../../flutter/assets/fonts/DouyinSansBold.ttf");
        let mut count = 0;
        if unsafe { AddFontMemResourceEx(font.as_ptr() as _, font.len() as _, ptr::null_mut(), &mut count) }.is_null() {
            hbb_common::log::warn!("Could not load the certified interface font: {}", std::io::Error::last_os_error());
        }
    });
}

fn scale(window: HWND) -> f64 {
    unsafe {
        let module = GetModuleHandleW([117u16,115,101,114,51,50,0].as_ptr());
        let function = GetProcAddress(module,b"GetDpiForWindow\0".as_ptr() as _);
        if !function.is_null() {
            let get_dpi: unsafe extern "system" fn(HWND)->UINT = mem::transmute(function);
            let dpi=get_dpi(window);
            if dpi!=0 { return dpi as f64/96.; }
        }
        let dc=GetDC(window);
        if dc.is_null() { return 1.; }
        let dpi=GetDeviceCaps(dc,LOGPIXELSX);
        ReleaseDC(window,dc);
        (dpi.max(96) as f64)/96.
    }
}

fn bounds(window: HWND) -> Option<RECT> {
    let mut rect=unsafe { mem::zeroed() };
    (unsafe { GetWindowRect(window,&mut rect) }!=0).then_some(rect)
}

fn monitor_info(window: HWND) -> Option<MONITORINFO> {
    unsafe {
        let monitor=MonitorFromWindow(window,MONITOR_DEFAULTTONEAREST);
        let mut info:MONITORINFO=mem::zeroed();
        info.cbSize=mem::size_of::<MONITORINFO>() as _;
        (GetMonitorInfoW(monitor,&mut info)!=0).then_some(info)
    }
}

impl Frame {
    pub(super) fn layout(&mut self,window:HWND,mode:i32)->bool {
        let Some(info)=monitor_info(window) else { return false; };
        let area=info.rcWork;
        let Some(current)=bounds(window) else { return false; };
        let dpi=scale(window);
        let entering=self.mode!=mode;
        let (logical_w,logical_h)=match mode {
            1=>(446.,326.),2=>(86.,86.),3=>(342.,350.),4=>(342.,478.),_=>{
                set_glass(window,0,0,0,dpi);
                unsafe { SetWindowPos(window,HWND_NOTOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE); }
                self.mode=0;
                return true;
            }
        };
        let width=((logical_w*dpi).round() as i32).min(area.right-area.left).max(1);
        let height=((logical_h*dpi).round() as i32).min(area.bottom-area.top).max(1);
        let (x,y)=if mode==1 {
            (area.left+(area.right-area.left-width)/2,area.top+(area.bottom-area.top-height)/2)
        } else {
            if self.mode==2 { self.dock=Some(current); }
            let anchor=self.dock.unwrap_or(RECT { left:area.right-(86.*dpi) as i32-4,
                top:area.top+((area.bottom-area.top) as f64*0.48) as i32,
                right:area.right-4,bottom:area.top+((area.bottom-area.top) as f64*0.48) as i32+(86.*dpi) as i32 });
            let left_edge=(anchor.left-area.left).abs() < (area.right-anchor.right).abs();
            let x=if left_edge {area.left+4} else {area.right-width-4};
            let y=if mode==2 {anchor.top} else {anchor.top-12};
            (x.clamp(area.left,area.right-width),y.clamp(area.top,area.bottom-height))
        };
        unsafe {
            let style=GetWindowLongPtrW(window,GWL_STYLE);
            SetWindowLongPtrW(window,GWL_STYLE,((style as isize) & !(WS_OVERLAPPEDWINDOW as isize)) as _);
            if IsIconic(window)!=0 || IsZoomed(window)!=0 {
                let mut placement:WINDOWPLACEMENT=mem::zeroed();
                placement.length=mem::size_of::<WINDOWPLACEMENT>() as _;
                if GetWindowPlacement(window,&mut placement)!=0 {
                    let tool=((GetWindowLongPtrW(window,GWL_EXSTYLE) as isize) & (WS_EX_TOOLWINDOW as isize))!=0;
                    let dx=if tool {0} else {area.left-info.rcMonitor.left};
                    let dy=if tool {0} else {area.top-info.rcMonitor.top};
                    placement.showCmd=SW_SHOWNOACTIVATE as _;
                    placement.rcNormalPosition=RECT {left:x-dx,top:y-dy,right:x-dx+width,bottom:y-dy+height};
                    if SetWindowPlacement(window,&placement)==0 {
                        hbb_common::log::warn!("Could not restore the certified window: {}",std::io::Error::last_os_error());
                        return false;
                    }
                }
            }
            if entering || current.left!=x || current.top!=y || current.right-current.left!=width || current.bottom-current.top!=height {
                if SetWindowPos(window,HWND_TOPMOST,x,y,width,height,SWP_NOACTIVATE|SWP_FRAMECHANGED)==0 {
                    hbb_common::log::warn!("Could not position the certified window: {}",std::io::Error::last_os_error());
                    return false;
                }
                set_glass(window,mode,width,height,dpi);
            }
            ShowWindow(window,if mode==1 && entering {SW_SHOWNORMAL} else {SW_SHOWNOACTIVATE});
            if mode==1 && entering { SetForegroundWindow(window); }
        }
        self.mode=mode;
        if mode==2 { self.dock=bounds(window); }
        true
    }

    pub(super) fn drag(&mut self,window:HWND)->bool {
        let Some(before)=bounds(window) else { return false; };
        unsafe {
            ReleaseCapture();
            SendMessageW(window,WM_NCLBUTTONDOWN,HTCAPTION as _,0);
        }
        let Some(after)=bounds(window) else { return false; };
        let moved=(after.left-before.left).abs()+(after.top-before.top).abs()>4;
        if self.mode==2 { self.dock=Some(after); }
        moved
    }

    pub(super) fn motion_allowed()->bool {
        let mut enabled=1i32;
        unsafe { SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION,0,&mut enabled as *mut _ as _,0); }
        enabled!=0
    }

    pub(super) fn glass_supported()->bool {
        let mut enabled=0;
        unsafe {DwmIsCompositionEnabled(&mut enabled)>=0 && enabled!=0}
    }
}
