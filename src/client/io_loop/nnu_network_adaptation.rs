use super::*;

impl<T: InvokeUiSession> Remote<T> {
    pub(super) fn nnu_protect_clipboard_transfer(&mut self, clip: &clipboard::ClipboardFile) {
        let files = match clip {
            clipboard::ClipboardFile::FormatList { format_list } => format_list.iter().any(
                |(id, name)| *id == 15 || name == "FileGroupDescriptorW" || name == "FileContents"),
            clipboard::ClipboardFile::FileContentsRequest { .. }
                | clipboard::ClipboardFile::FileContentsResponse { .. } => true,
            clipboard::ClipboardFile::Files { files } => !files.is_empty(),
            _ => false,
        };
        if files {
            // Completion is not observable on every clipboard backend. Keep this window
            // on its current transport after file activity rather than interrupt a paste.
            self.nnu_link_health.block_for_session();
        }
    }

    pub(super) fn nnu_retry_stable_transport(&mut self, delay_ms: u32, peer: &Stream) -> bool {
        if hbb_common::config::Config::get_option("nnu-network-adaptation") != "Y"
            || !matches!(peer, Stream::WebRTC(_))
            || !self.handler.is_default()
            || !self.is_connected
            || !self.first_frame
            || self.handler.lc.read().unwrap().nnu_native_fallback
        {
            return false;
        }
        let busy = !self.read_jobs.is_empty() || !self.write_jobs.is_empty()
            || self.stop_voice_call_sender.is_some()
            || self.voice_call_request_timestamp.is_some()
            || crate::nnu_voice_call::outgoing()
            || self.last_record_state || self.elevation_requested;
        if !self.nnu_link_health.observe(delay_ms,
            self.nnu_network_started.elapsed().as_millis() as u64, busy)
        {
            return false;
        }
        {
            let mut login = self.handler.lc.write().unwrap();
            login.nnu_native_fallback = true;
            login.force_relay = true;
        }
        log::warn!("Network adaptation: sustained WebRTC delay={delay_ms} ms; retrying native relay for this window");
        peer.close_webrtc();
        self.handler.msgbox("restarting-show", "Connecting...", "Connection in progress. Please wait.", "");
        true
    }
}
