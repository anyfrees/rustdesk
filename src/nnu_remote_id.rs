use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine},
    config::Config,
    sodiumoxide::{crypto::sign, randombytes::randombytes},
};
use serde::{Deserialize, Serialize};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const REQUEST_DOMAIN: &[u8] = b"NNU-REMOTE-ID-DEVICE-V1\0";
const COMMAND_DOMAIN: &[u8] = b"NNU-REMOTE-ID-COMMAND-V1\0";

#[derive(Serialize)]
struct DeviceRequest<'a> {
    id: String,
    uuid: String,
    nonce: &'a str,
    iat: u64,
    platform: &'static str,
    busy: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    failed_job: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<&'a str>,
}

#[derive(Deserialize)]
struct Envelope {
    payload: String,
    signature: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct Command {
    schema: u8,
    job_id: String,
    old_id: String,
    new_id: String,
    uuid: String,
    nonce: String,
    iat: u64,
    exp: u64,
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn valid_id(id: &str) -> bool {
    (6..=16).contains(&id.len()) && id.as_bytes()[0].is_ascii_alphabetic()
        && id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
}

fn verify_command(envelope: &Envelope, nonce: &str, id: &str, uuid: &str,
    current: u64, keys: impl Iterator<Item = sign::PublicKey>) -> Option<Command> {
    let raw = URL_SAFE_NO_PAD.decode(&envelope.payload).ok()?;
    if raw.len() > 2048 { return None; }
    let signature = sign::Signature::from_bytes(&URL_SAFE_NO_PAD.decode(&envelope.signature).ok()?).ok()?;
    let message = [COMMAND_DOMAIN, raw.as_slice()].concat();
    if !keys.into_iter().any(|key| sign::verify_detached(&signature, &message, &key)) { return None; }
    let command: Command = serde_json::from_slice(&raw).ok()?;
    (command.schema == 1 && command.job_id.len() == 48
        && command.job_id.bytes().all(|c| c.is_ascii_hexdigit())
        && command.old_id == id && command.uuid == uuid && command.nonce == nonce
        && valid_id(&command.new_id) && !command.new_id.eq_ignore_ascii_case(id)
        && command.iat <= current.saturating_add(30) && current < command.exp
        && command.exp > command.iat && command.exp - command.iat <= 60)
        .then_some(command)
}

async fn request(client: &reqwest::Client, origin: &str, secret: &sign::SecretKey,
    nonce: &str, failed: Option<(&str, &str)>) -> Option<Envelope> {
    let payload = serde_json::to_vec(&DeviceRequest {
        id: Config::get_id(), uuid: crate::encode64(hbb_common::get_uuid()), nonce,
        iat: now(), platform: std::env::consts::OS,
        busy: !crate::updater::has_no_active_conns(),
        failed_job: failed.map(|v| v.0), error: failed.map(|v| v.1),
    }).ok()?;
    let signature = sign::sign_detached(&[REQUEST_DOMAIN, payload.as_slice()].concat(), secret);
    let mut response = client.post(format!("{origin}/api/nnu/remote-id/poll"))
        .json(&serde_json::json!({"payload":URL_SAFE_NO_PAD.encode(payload),
            "signature":URL_SAFE_NO_PAD.encode(signature.as_ref())})).send().await.ok()?;
    if response.status() != reqwest::StatusCode::OK { return None; }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.ok()? {
        if bytes.len() + chunk.len() > 4096 { return None; }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).ok()
}

pub(crate) async fn poll() {
    let Some(origin) = crate::nnu_official_support::origin() else { return; };
    let Ok(raw) = crate::nnu_id::registered_desktop_key().await else { return; };
    let Some(secret) = sign::SecretKey::from_slice(&raw) else { return; };
    let Ok(client) = reqwest::Client::builder().timeout(Duration::from_secs(4))
        .redirect(reqwest::redirect::Policy::none()).build() else { return; };
    let nonce = URL_SAFE_NO_PAD.encode(randombytes(24));
    let Some(envelope) = request(&client, &origin, &secret, &nonce, None).await else { return; };
    let Some(command) = verify_command(&envelope, &nonce, &Config::get_id(),
        &crate::encode64(hbb_common::get_uuid()), now(), crate::nnu_official_support::keys()) else { return; };
    if !crate::updater::has_no_active_conns() {
        let _ = request(&client, &origin, &secret, &nonce, Some((&command.job_id, "busy"))).await;
        return;
    }
    let error = crate::ui_interface::change_id_shared_(command.new_id.clone(), command.old_id).await;
    let result = match error {
        "" => None,
        "Not available" => Some("not_available"),
        "Too frequent" => Some("too_frequent"),
        "server_not_support" => Some("unsupported"),
        _ => Some("change_failed"),
    };
    // A signed callback plus a later poll under the new ID confirms both ends.
    if let Some(code) = result {
        let _ = request(&client, &origin, &secret, &nonce, Some((&command.job_id, code))).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn command_requires_signature_current_device_nonce_and_lifetime() {
        let (public, secret) = sign::gen_keypair();
        let command = Command { schema:1,job_id:"a".repeat(48),old_id:"610000001".into(),new_id:"Office_PC".into(),
            uuid:"device-fixture".into(),nonce:"fresh-nonce".into(),iat:100,exp:160 };
        let raw = serde_json::to_vec(&command).unwrap();
        let signature = sign::sign_detached(&[COMMAND_DOMAIN, raw.as_slice()].concat(), &secret);
        let envelope = Envelope { payload:URL_SAFE_NO_PAD.encode(&raw),signature:URL_SAFE_NO_PAD.encode(signature.as_ref()) };
        let verify = |nonce,id,uuid,at| verify_command(&envelope,nonce,id,uuid,at,std::iter::once(public));
        assert!(verify("fresh-nonce","610000001","device-fixture",120).is_some());
        assert!(verify("replayed-nonce","610000001","device-fixture",120).is_none());
        assert!(verify("fresh-nonce","otherpc","device-fixture",120).is_none());
        assert!(verify("fresh-nonce","610000001","other-device",120).is_none());
        assert!(verify("fresh-nonce","610000001","device-fixture",160).is_none());
        assert!(verify_command(&envelope,"fresh-nonce","610000001","device-fixture",120,
            std::iter::once(sign::gen_keypair().0)).is_none());
    }
}
