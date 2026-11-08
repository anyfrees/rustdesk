use hbb_common::{config::{self, Config}, log};

pub fn resume_stopped_service() {
    if !crate::nnu::is_nnu_server()
        || config::is_outgoing_only()
        || Config::get_option("stop-service") != "Y"
    {
        return;
    }
    if crate::platform::is_cur_exe_the_installed() {
        log::info!("Resuming the stopped service on explicit client launch");
        // Reuse the existing start-service action, including its UAC and failure handling.
        crate::platform::install_service();
    } else if !crate::platform::is_installed() {
        Config::set_option("stop-service".to_owned(), String::new());
    }
}
