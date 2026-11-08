use base::message_proto::{Hash, LoginRequest};
use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine},
    config::{Config, LocalConfig},
    sodiumoxide::{crypto::sign, randombytes::randombytes},
    Stream,
};
use serde::{Deserialize, Serialize};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const DOMAIN: &[u8] = b"nnu-rustdesk-official-support-v1\0";
const LIFETIME: u64 = 45;
const MAX_FUTURE_CLOCK_SKEW: u64 = 30;
const MAX_PROOF: usize = 8192;
pub mod stock;
const API_ORIGIN: &str = match option_env!("NNU_OFFICIAL_SUPPORT_API_ORIGIN") {
    Some(origin) => origin,
    None => "https://rd.nnu.cn",
};

pub const REJECTED: &str = "The remote device rejected official support verification";
pub const UNSUPPORTED: &str = "The remote device does not support verified official support";
pub const UNAVAILABLE: &str = "The official support service is unavailable";
pub const DENIED: &str = "Sign in again or check your official support authorization";
pub const CLICK_REQUIRED: &str =
    "The remote device must use click confirmation for official support";
pub const SECURE_REQUIRED: &str = "Official support requires an authenticated device connection";

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct VerifiedIdentity {
    pub display_name: String,
    pub introduction: String,
    #[serde(default)]
    pub badge_color: BadgeColor,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub account_name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub avatar_jpeg: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub peer_platform: String,
    #[serde(default)]
    pub click_prompt: bool,
    #[serde(default)]
    pub full_control_on_accept: bool,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BadgeColor {
    #[default]
    Blue,
    Red,
    Yellow,
    #[serde(rename = "black_gold")]
    BlackGold,
}

#[derive(Deserialize)]
struct Claims {
    account: u64,
    source: String,
    target: String,
    target_key: String,
    challenge: String,
    iat: u64,
    exp: u64,
    #[serde(flatten)]
    identity: VerifiedIdentity,
}

pub(crate) fn keys() -> impl Iterator<Item = sign::PublicKey> {
    option_env!("NNU_OFFICIAL_SUPPORT_PUBLIC_KEYS")
        .unwrap_or_default()
        .split(',')
        .take(4)
        .filter_map(|raw| sign::PublicKey::from_slice(&crate::decode64(raw.trim()).ok()?))
}

pub(crate) fn origin() -> Option<String> {
    let configured = crate::ui_interface::get_api_server();
    let configured = configured.trim_end_matches('/');
    let canonical = API_ORIGIN.trim_end_matches('/');
    if keys().next().is_none()
        || (configured != canonical
            && !(canonical == "https://rd.nnu.cn" && configured == "https://rd.0vk.com"))
    {
        return None;
    }
    let parsed = reqwest::Url::parse(configured).ok()?;
    let fixture = option_env!("NNU_OFFICIAL_SUPPORT_TEST_LOOPBACK") == Some("Y")
        && parsed.host_str() == Some("127.0.0.1")
        && parsed.scheme() == "http";
    if (parsed.scheme() != "https" && !fixture)
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.path() != "/"
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }
    Some(configured.to_owned())
}

pub fn can_attach() -> bool {
    origin().is_some() && !LocalConfig::get_option("access_token").is_empty()
}

pub fn challenge(stream: &Stream) -> String {
    if cfg!(all(any(feature = "flutter", target_os = "windows"), not(target_os = "ios")))
        && stream.is_secured()
        && keys().next().is_some()
    {
        URL_SAFE_NO_PAD.encode(randombytes(32))
    } else {
        String::new()
    }
}

fn valid_device(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 100
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn decode(proof: &str, trust: impl Iterator<Item = sign::PublicKey>) -> Option<Claims> {
    if proof.len() > MAX_PROOF {
        return None;
    }
    let (payload, signature) = proof.split_once('.')?;
    let payload = URL_SAFE_NO_PAD.decode(payload).ok()?;
    let signature = sign::Signature::from_bytes(&URL_SAFE_NO_PAD.decode(signature).ok()?).ok()?;
    let mut message = DOMAIN.to_vec();
    message.extend_from_slice(&payload);
    if !trust
        .into_iter()
        .any(|key| sign::verify_detached(&signature, &message, &key))
    {
        return None;
    }
    serde_json::from_slice(&payload).ok()
}

impl Claims {
    fn matches(
        &self,
        source: &str,
        target: &str,
        target_key: &[u8],
        challenge: &str,
        now: u64,
    ) -> bool {
        self.account != 0
            && !challenge.is_empty()
            && self.source == source
            && self.target == target
            && self.target_key == URL_SAFE_NO_PAD.encode(target_key)
            && self.challenge == challenge
            && self.iat <= now.saturating_add(MAX_FUTURE_CLOCK_SKEW)
            && now < self.exp
            && self.exp.checked_sub(self.iat) == Some(LIFETIME)
            && !self.identity.display_name.is_empty()
            && self.identity.display_name.len() <= 240
            && !self.identity.introduction.is_empty()
            && self.identity.introduction.len() <= 480
            && self.identity.account_name.len() <= 180
            && self.identity.avatar_jpeg.len() <= 3600
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

pub fn verify_login(lr: &LoginRequest, proof: &str, challenge: &str) -> Option<VerifiedIdentity> {
    let target = Config::get_id();
    let (_, key) = Config::get_key_pair();
    if lr.username != target
        || !matches!(lr.union.as_ref(), None | Some(base::message_proto::login_request::Union::NnuVoiceCall(_)))
        || key.len() != sign::PUBLICKEYBYTES
        || challenge.is_empty()
    {
        return None;
    }
    let claims = decode(proof, keys())?;
    claims
        .matches(&lr.my_id, &target, &key, challenge, now())
        .then_some(claims.identity)
}

#[derive(Deserialize)]
struct ProofResponse {
    proof: String,
}

async fn issue(target: &str, target_key: &[u8], hash: &Hash) -> Result<String, &'static str> {
    let challenge = &hash.nnu_official_support_challenge;
    if URL_SAFE_NO_PAD
        .decode(challenge)
        .map_or(true, |v| v.len() != 32)
    {
        return Err(UNSUPPORTED);
    }
    if !valid_device(target) || target_key.len() != sign::PUBLICKEYBYTES {
        return Err(SECURE_REQUIRED);
    }
    let origin = origin().ok_or(UNAVAILABLE)?;
    let token = LocalConfig::get_option("access_token");
    if token.is_empty() {
        return Err(DENIED);
    }
    let source = Config::get_id();
    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(1500))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .map_err(|_| UNAVAILABLE)?;
    let mut response = client
        .post(format!("{origin}/api/nnu/official-support/issue"))
        .bearer_auth(token)
        .json(&serde_json::json!({
            "source": source,
            "target": target,
            "target_key": URL_SAFE_NO_PAD.encode(target_key),
            "challenge": challenge,
        }))
        .send()
        .await
        .map_err(|_| UNAVAILABLE)?;
    match response.status().as_u16() {
        200 => {}
        400 | 401 | 403 => return Err(DENIED),
        _ => return Err(UNAVAILABLE),
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| UNAVAILABLE)? {
        if body.len() + chunk.len() > MAX_PROOF + 32 {
            return Err(REJECTED);
        }
        body.extend_from_slice(&chunk);
    }
    let response: ProofResponse = serde_json::from_slice(&body).map_err(|_| REJECTED)?;
    let claims = decode(&response.proof, keys()).ok_or(REJECTED)?;
    if !claims.matches(&source, target, target_key, challenge, now()) {
        return Err(REJECTED);
    }
    Ok(response.proof)
}

pub async fn optional_proof(target: &str, target_key: &[u8], hash: &Hash) -> String {
    if !hash.nnu_verified_identity_supported {
        return String::new();
    }
    match issue(target, target_key, hash).await {
        Ok(proof) => proof,
        Err(reason) => {
            hbb_common::log::trace!("Official support identity omitted: {reason}");
            String::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proof_authenticates_one_target_and_challenge_until_expiry() {
        sodium_init();
        let (key, secret) = sign::gen_keypair();
        let target_key = [41; 32];
        let challenge = URL_SAFE_NO_PAD.encode([3; 32]);
        let other_challenge = URL_SAFE_NO_PAD.encode([4; 32]);
        let raw = serde_json::to_vec(&serde_json::json!({
            "account": 7,
            "source": "controller",
            "target": "target",
            "target_key": URL_SAFE_NO_PAD.encode(target_key),
            "challenge": challenge,
            "iat": 100,
            "exp": 145,
            "display_name": "合成认证人员",
            "introduction": "用于隔离测试",
            "badge_color": "black_gold",
        }))
        .unwrap();
        let signature = sign::sign_detached(&[DOMAIN, raw.as_slice()].concat(), &secret);
        let proof = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(&raw),
            URL_SAFE_NO_PAD.encode(signature.as_ref())
        );
        let claims = decode(&proof, std::iter::once(key)).unwrap();
        assert!(matches!(claims.identity.badge_color, BadgeColor::BlackGold));
        assert!(claims.matches("controller", "target", &target_key, &challenge, 120));
        assert!(claims.matches("controller", "target", &target_key, &challenge, 92));
        assert!(claims.matches("controller", "target", &target_key, &challenge, 70));
        assert!(!claims.matches("controller", "target", &target_key, &challenge, 69));
        assert!(!claims.matches("controller", "target", &target_key, &challenge, 145));
        assert!(!claims.matches("controller", "target", &target_key, &other_challenge, 120));
        assert!(!claims.matches("controller", "target", &target_key, "", 120));
        assert!(!claims.matches("controller", "wrong", &target_key, &challenge, 120));
        assert!(!claims.matches("controller", "target", &[9; 32], &challenge, 120));
        assert!(!claims.matches("wrong", "target", &target_key, &challenge, 120));
        let tampered = proof.replacen(
            &URL_SAFE_NO_PAD.encode(&raw),
            &URL_SAFE_NO_PAD.encode(b"{}"),
            1,
        );
        assert!(decode(&tampered, std::iter::once(key)).is_none());
        let (other_key, _) = sign::gen_keypair();
        assert!(decode(&proof, std::iter::once(other_key)).is_none());
        assert!(decode(&proof, [other_key, key].into_iter()).is_some());
    }

    fn sodium_init() {
        assert!(hbb_common::sodiumoxide::init().is_ok());
    }
}
