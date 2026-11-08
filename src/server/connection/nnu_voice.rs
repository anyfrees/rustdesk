use super::*;

impl Connection {
    pub(super) fn nnu_voice_only(&self) -> bool {
        matches!(self.lr.union, Some(login_request::Union::NnuVoiceCall(_)))
    }

    pub(super) fn nnu_voice_message(msg: &Message) -> bool {
        matches!(msg.union.as_ref(),
            Some(message::Union::VoiceCallRequest(_) | message::Union::AudioFrame(_)))
            || matches!(msg.union.as_ref(), Some(message::Union::Misc(m))
                if matches!(m.union.as_ref(), Some(misc::Union::AudioFormat(_))))
    }

    pub(super) async fn nnu_start_voice_channel(&mut self) -> bool {
        // Signalling is separate from desktop authorization. No capture/input/clipboard
        // services are subscribed, and microphones start only after an explicit answer.
        #[cfg(any(target_os = "android", target_os = "ios"))]
        {
            self.send_login_error("Direct voice calls require a desktop client").await;
            return false;
        }
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        {
            if !Self::permission(keys::OPTION_ENABLE_AUDIO, &self.control_permissions)
                || crate::platform::is_prelogin() || crate::platform::is_locked()
            {
                self.send_login_error("Voice calls are unavailable on this device").await;
                return false;
            }
            self.keyboard = false;
            self.clipboard = false;
            self.file = false;
            self.restart = false;
            self.recording = false;
            self.block_input = false;
            self.privacy_mode = false;
            self.options_in_login = None;
            self.authorized = true;
            self.authed_conn_id = Some(raii::AuthedConnID::new(
                self.inner.id(), AuthConnType::NnuVoiceCall, self.session_key(),
                self.tx_from_authed.clone(), self.lr.clone()));
            self.unauthorized_id = None;
            self.try_start_cm(self.lr.my_id.clone(), self.lr.my_name.clone(), true);
            let mut response = LoginResponse::new();
            response.set_peer_info(PeerInfo {
                username: crate::username(), version: VERSION.to_owned(),
                platform: hbb_common::whoami::platform().to_string(),
                ..Default::default()
            });
            let mut msg = Message::new();
            msg.set_login_response(response);
            self.send(msg).await;
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn voice_channel_cannot_control_or_observe_desktop() {
        let mut msg = Message::new();
        msg.set_voice_call_request(VoiceCallRequest::new());
        assert_eq!(Connection::authorized_message_scope_violation(AuthConnType::NnuVoiceCall, &msg), None);
        msg.set_mouse_event(MouseEvent::new());
        assert!(Connection::authorized_message_scope_violation(AuthConnType::NnuVoiceCall, &msg).is_some());
        msg.set_clipboard(Clipboard::new());
        assert!(Connection::authorized_message_scope_violation(AuthConnType::NnuVoiceCall, &msg).is_some());
        msg.set_screenshot_request(ScreenshotRequest::new());
        assert!(Connection::authorized_message_scope_violation(AuthConnType::NnuVoiceCall, &msg).is_some());
        let mut misc = Misc::new();
        misc.set_refresh_video(true);
        msg.set_misc(misc);
        assert!(Connection::authorized_message_scope_violation(AuthConnType::NnuVoiceCall, &msg).is_some());
    }

    #[test]
    fn voice_login_cannot_retry_as_desktop_login() {
        let mut lr = LoginRequest::new();
        let desktop = Connection::login_scope_digest(&lr);
        lr.set_nnu_voice_call(NnuVoiceCall::new());
        assert_ne!(desktop, Connection::login_scope_digest(&lr));
        let (option, _) = Connection::scoped_login_option(AuthConnType::NnuVoiceCall, &OptionMessage::new());
        assert!(option.is_none());
    }
}
