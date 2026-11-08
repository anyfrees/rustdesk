#[cfg(target_os = "linux")]
use crate::ipc::start_pa;
use crate::ui_cm_interface::{start_ipc, ConnectionManager, InvokeUiCM};

use hbb_common::{allow_err, log};
use sciter::{make_args, Element, Value, HELEMENT};
use std::sync::Mutex;
use std::{ops::Deref, sync::Arc};

lazy_static::lazy_static! {
    pub static ref HIDE_CM: Arc<Mutex<bool>> = Arc::new(Mutex::new(false));
}

#[derive(Clone, Default)]
pub struct SciterHandler {
    pub element: Arc<Mutex<Option<Element>>>,
}

impl InvokeUiCM for SciterHandler {
    fn add_connection(&self, client: &crate::ui_cm_interface::Client) {
        self.call(
            "addConnection",
            &make_args!(
                client.id,
                client.is_file_transfer,
                client.is_view_camera,
                client.is_terminal,
                client.port_forward.clone(),
                client.peer_id.clone(),
                client.name.clone(),
                client.avatar.clone(),
                client.authorized,
                client.keyboard,
                client.clipboard,
                client.audio,
                client.file,
                client.restart,
                client.recording,
                client.block_input,
                client.privacy_mode
            ),
        );
    }

    fn remove_connection(&self, id: i32, close: bool) {
        self.call("removeConnection", &make_args!(id, close));
        if crate::ui_cm_interface::get_clients_length().eq(&0) {
            crate::platform::quit_gui();
        }
    }

    fn new_message(&self, id: i32, text: String) {
        self.call("newMessage", &make_args!(id, text));
    }

    fn change_theme(&self, dark: String) {
        self.call("changeTheme", &make_args!(dark));
    }

    fn change_language(&self) {
        self.call("changeLanguage", &make_args!());
    }

    fn show_elevation(&self, show: bool) {
        self.call("showElevation", &make_args!(show));
    }

    fn update_voice_call_state(&self, client: &crate::ui_cm_interface::Client) {
        self.call(
            "updateVoiceCallState",
            &make_args!(client.id, client.in_voice_call, client.incoming_voice_call),
        );
    }

    fn file_transfer_log(&self, _action: &str, _log: &str) {}
}

impl SciterHandler {
    #[inline]
    fn call(&self, func: &str, args: &[Value]) {
        if let Some(e) = self.element.lock().unwrap().as_ref() {
            allow_err!(e.call_method(func, &super::value_crash_workaround(args)[..]));
        }
    }
}

pub struct SciterConnectionManager(ConnectionManager<SciterHandler>,
    #[cfg(windows)] super::nnu_cm::Frame);

impl Deref for SciterConnectionManager {
    type Target = ConnectionManager<SciterHandler>;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl SciterConnectionManager {
    pub fn new() -> Self {
        #[cfg(target_os = "linux")]
        std::thread::spawn(start_pa);
        let cm = ConnectionManager {
            ui_handler: SciterHandler::default(),
        };
        let cloned = cm.clone();
        std::thread::spawn(move || start_ipc(cloned));
        SciterConnectionManager(cm, #[cfg(windows)] Default::default())
    }

    fn get_icon(&mut self) -> String {
        super::get_icon()
    }

    fn check_click_time(&mut self, id: i32) {
        crate::ui_cm_interface::check_click_time(id);
    }

    fn get_click_time(&self) -> f64 {
        crate::ui_cm_interface::get_click_time() as _
    }

    fn switch_permission(&self, id: i32, name: String, enabled: bool) {
        crate::ui_cm_interface::switch_permission(id, name, enabled);
    }

    fn close(&self, id: i32) {
        crate::ui_cm_interface::close(id);
    }

    fn remove_disconnected_connection(&self, id: i32) {
        crate::ui_cm_interface::remove(id);
    }

    fn quit(&self) {
        crate::platform::quit_gui();
    }

    fn authorize(&self, id: i32) {
        crate::ui_cm_interface::authorize(id);
    }

    fn send_msg(&self, id: i32, text: String) {
        crate::ui_cm_interface::send_chat(id, text);
    }

    fn t(&self, name: String) -> String {
        crate::client::translate(name)
    }

    fn can_elevate(&self) -> bool {
        crate::ui_cm_interface::can_elevate()
    }

    fn elevate_portable(&self, id: i32) {
        crate::ui_cm_interface::elevate_portable(id);
    }

    fn get_option(&self, key: String) -> String {
        crate::ui_interface::get_option(key)
    }

    fn get_builtin_option(&self, key: String) -> String {
        crate::ui_interface::get_builtin_option(&key)
    }

    fn hide_cm(&self) -> bool {
        *crate::ui::cm::HIDE_CM.lock().unwrap()
    }

    fn nnu_clients(&self) -> String {
        #[cfg(windows)]
        return crate::ui_cm_interface::get_clients_state();
        #[cfg(not(windows))]
        "[]".to_owned()
    }

    fn nnu_layout(&mut self, mode: i32) -> bool {
        #[cfg(windows)]
        {
            let window=self.ui_handler.element.lock().unwrap().as_ref().map(|root|root.get_hwnd(true));
            if let Some(window)=window { return self.1.layout(window as _,mode); }
        }
        false
    }

    fn nnu_drag(&mut self) -> bool {
        #[cfg(windows)]
        {
            let window=self.ui_handler.element.lock().unwrap().as_ref().map(|root|root.get_hwnd(true));
            if let Some(window)=window { return self.1.drag(window as _); }
        }
        false
    }

    fn nnu_motion(&self) -> bool {
        #[cfg(windows)]
        return super::nnu_cm::Frame::motion_allowed();
        #[cfg(not(windows))]
        false
    }

    fn nnu_glass(&self) -> bool {
        #[cfg(windows)]
        return super::nnu_cm::Frame::glass_supported();
        #[cfg(not(windows))]
        false
    }

    fn nnu_transfer(&self,id:i32)->bool {
        let clients:Vec<serde_json::Value> = match serde_json::from_str(&self.nnu_clients()) {
            Ok(clients)=>clients,
            Err(error)=>{ log::warn!("Could not read the certified file transfer state: {error}");return false; }
        };
        let Some(client)=clients.into_iter().find(|client|client["id"].as_i64()==Some(id as i64) && client["authorized"].as_bool()==Some(true) && client["disconnected"].as_bool()==Some(false)) else { return false; };
        if client["file"].as_bool()!=Some(true) || hbb_common::config::is_incoming_only() || !client["official_support"].is_object() || client["official_support"]["peer_platform"].as_str().is_some_and(|platform|platform.eq_ignore_ascii_case("ios")) { return false; }
        let Some(peer)=client["peer_id"].as_str() else { return false; };
        match crate::run_me(vec!["--file-transfer",peer]) {
            Ok(_)=>true,
            Err(error)=>{ log::warn!("Could not open certified file transfer: {error}");false }
        }
    }

    fn get_supported_privacy_mode_impls(&self) -> String {
        serde_json::to_string(&crate::privacy_mode::get_supported_privacy_mode_impl())
            .unwrap_or_default()
    }
}

impl sciter::EventHandler for SciterConnectionManager {
    fn attached(&mut self, root: HELEMENT) {
        #[cfg(windows)]
        super::nnu_cm::load_font();
        *self.ui_handler.element.lock().unwrap() = Some(Element::from(root));
    }

    sciter::dispatch_script_call! {
        fn t(String);
        fn check_click_time(i32);
        fn get_click_time();
        fn get_icon();
        fn close(i32);
        fn remove_disconnected_connection(i32);
        fn quit();
        fn authorize(i32);
        fn switch_permission(i32, String, bool);
        fn send_msg(i32, String);
        fn can_elevate();
        fn elevate_portable(i32);
        fn get_option(String);
        fn get_builtin_option(String);
        fn hide_cm();
        fn nnu_clients();
        fn nnu_layout(i32);
        fn nnu_drag();
        fn nnu_motion();
        fn nnu_glass();
        fn nnu_transfer(i32);
        fn get_supported_privacy_mode_impls();
    }
}
