use super::{decode, keys, now, valid_device, VerifiedIdentity};
use base::message_proto::LoginRequest;
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine},
    config::Config,
    protobuf::Message,
    rendezvous_proto::{rendezvous_message, RendezvousMessage, RequestRelay},
    socket_client::connect_tcp,
    sha2::{Digest, Sha256},
    sodiumoxide::crypto::{sealedbox, sign},
};
use serde::Deserialize;
use std::{collections::HashMap, sync::Mutex};

pub const PREFIX: &str = "nnu1:";
pub const REFERENCE: &str = "nnu2:";
const MAX_TICKET: usize = 13000;

/// The rendezvous request carries an encrypted ticket/reference until `open`
/// replaces it with the ordinary relay UUID. Authentication still happens there.
pub fn check_request_uuid(value: &str, secure: bool) -> hbb_common::ResultType<()> {
    if let Some(reference) = value.strip_prefix(REFERENCE) {
        if secure && uuid::Uuid::parse_str(reference).ok().is_some_and(|id| id.get_version_num() == 4)
            && reference.len() == 36
        {
            return Ok(());
        }
    } else if let Some(ticket) = value.strip_prefix(PREFIX) {
        if secure && !ticket.is_empty() && ticket.len() <= MAX_TICKET
            && URL_SAFE_NO_PAD.decode(ticket).is_ok_and(|raw| !raw.is_empty())
        {
            return Ok(());
        }
    } else {
        return crate::common::check_relay_uuid(value);
    }
    hbb_common::anyhow::bail!("invalid official support relay request")
}

lazy_static::lazy_static! {
    static ref CLAIMED: Mutex<HashMap<String, u64>> = Default::default();
}

#[derive(Clone)]
pub struct Identity {
    source: String,
    expires: u64,
    identity: VerifiedIdentity,
}

impl Identity {
    pub fn for_login(self, login: &LoginRequest) -> Option<VerifiedIdentity> {
        (login.my_id == self.source && login.union.is_none() && now() < self.expires)
            .then_some(self.identity)
    }
}

#[derive(Deserialize)]
struct Ticket {
    uuid: String,
    proof: String,
    initiate: bool,
    #[serde(default)]
    relay_server: Option<String>,
    #[serde(default)]
    socket_addr: Option<Vec<u8>>,
}

pub async fn fetch(request: &mut RequestRelay, host: &str) -> Option<()> {
    let id = request.uuid.strip_prefix(REFERENCE)?;
    if !request.secure || id.len() != 36 || uuid::Uuid::parse_str(id).ok()?.get_version_num() != 4 {
        return None;
    }
    let mut connection = connect_tcp(host, 1200).await.ok()?;
    let mut message = RendezvousMessage::new();
    message.set_request_relay(RequestRelay {
        uuid: format!("nnu2-fetch:{id}"),
        ..Default::default()
    });
    connection.send(&message).await.ok()?;
    let data = connection.next_timeout(1200).await?.ok()?;
    let Some(rendezvous_message::Union::RelayResponse(response)) =
        RendezvousMessage::parse_from_bytes(&data).ok()?.union else {
        return None;
    };
    if !response.uuid.starts_with(PREFIX) || response.uuid.len() > MAX_TICKET + PREFIX.len() {
        return None;
    }
    request.uuid = response.uuid;
    Some(())
}

pub fn open(request: &mut RequestRelay) -> Option<(Identity, bool)> {
    let raw = request.uuid.strip_prefix(PREFIX)?;
    if raw.len() > MAX_TICKET || !request.secure {
        return None;
    }
    let (secret, public) = Config::get_key_pair();
    let secret = sign::SecretKey::from_slice(&secret)?;
    let public = sign::PublicKey::from_slice(&public)?;
    let raw = URL_SAFE_NO_PAD.decode(raw).ok()?;
    let raw = sealedbox::open(
        &raw,
        &sign::to_curve25519_pk(&public).ok()?,
        &sign::to_curve25519_sk(&secret).ok()?,
    ).ok()?;
    let ticket: Ticket = serde_json::from_slice(&raw).ok()?;
    if ticket.relay_server.as_deref().is_some_and(|relay| relay != request.relay_server)
        || ticket.socket_addr.as_deref().is_some_and(|addr| addr != request.socket_addr.as_ref())
    {
        return None;
    }
    if uuid::Uuid::parse_str(&ticket.uuid).ok()?.get_version_num() != 4 {
        return None;
    }
    let claims = decode(&ticket.proof, keys())?;
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(
        [b"nnu-stock-relay-v1\0".as_slice(), ticket.uuid.as_bytes()].concat(),
    ));
    let current = now();
    if !valid_device(&claims.source)
        || !claims.matches(&claims.source, &Config::get_id(), &public.0, &challenge, current)
    {
        return None;
    }
    let mut claimed = CLAIMED.lock().ok()?;
    claimed.retain(|_, expires| *expires > current);
    if claimed.len() >= 256 || claimed.contains_key(&ticket.uuid) {
        return None;
    }
    claimed.insert(ticket.uuid.clone(), claims.exp);
    request.uuid = ticket.uuid;
    Some((Identity {
        source: claims.source,
        expires: claims.exp,
        identity: claims.identity,
    }, ticket.initiate))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_relay_envelopes_reach_identity_verification() {
        let reference = "nnu2:e4c181d0-41c7-4ae6-8ef0-36581b6b2b12";
        let encrypted = format!("nnu1:{}", URL_SAFE_NO_PAD.encode([7u8; 300]));
        assert!(check_request_uuid(reference, true).is_ok());
        assert!(check_request_uuid(&encrypted, true).is_ok());
        // Admission does not grant an identity: an invalid sealed ticket is rejected.
        let mut request = RequestRelay { uuid: encrypted, secure: true, ..Default::default() };
        assert!(open(&mut request).is_none());
        assert!(check_request_uuid("ordinary-relay-uuid", false).is_ok());
    }

    #[test]
    fn store_relay_envelopes_reject_unsecured_or_malformed_input() {
        for (value, secure) in [
            ("nnu2:e4c181d0-41c7-4ae6-8ef0-36581b6b2b12".to_owned(), false),
            ("nnu2:invalid".to_owned(), true),
            ("nnu1:".to_owned(), true),
            ("nnu1:a\r\nb".to_owned(), true),
            (format!("nnu1:{}", "A".repeat(MAX_TICKET + 1)), true),
            ("ordinary\r\nuuid".to_owned(), false),
        ] {
            assert!(check_request_uuid(&value, secure).is_err());
        }
    }
}
