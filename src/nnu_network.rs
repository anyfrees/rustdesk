use hbb_common::{
    config::{Config, LocalConfig},
    protobuf::Message,
    rendezvous_proto::RendezvousMessage,
    sodiumoxide::crypto::sign,
    ResultType, Stream,
};

pub fn is_nnu_host(server: &str) -> bool {
    let host = server.split(':').next().unwrap_or_default();
    host.eq_ignore_ascii_case("rd.nnu.cn") || host.eq_ignore_ascii_case("rd.0vk.com")
}

pub fn sign_signal(message: &mut RendezvousMessage, challenge: &[u8]) -> ResultType<()> {
    if !is_nnu_host(&Config::get_rendezvous_server()) { return Ok(()); }
    let id = Config::get_id();
    let (secret, _) = Config::get_key_pair();
    let secret = sign::SecretKey::from_slice(&secret)
        .ok_or_else(|| hbb_common::anyhow::anyhow!("Device signing key unavailable"))?;
    let raw = message.write_to_bytes()?;
    let mut signed = b"NNU-SIGNAL-V1\0".to_vec();
    for part in [id.as_bytes(), challenge, raw.as_slice()] {
        signed.extend_from_slice(&(part.len() as u32).to_le_bytes());
        signed.extend_from_slice(part);
    }
    let fields = message.special_fields.mut_unknown_fields();
    fields.add_length_delimited(92, challenge.to_vec());
    fields.add_length_delimited(93, sign::sign_detached(&signed, &secret).as_ref().to_vec());
    fields.add_length_delimited(94, id.into_bytes());
    Ok(())
}

pub fn open_signal(message: Option<hbb_common::rendezvous_proto::rendezvous_message::Union>) -> Result<Option<hbb_common::rendezvous_proto::rendezvous_message::Union>, hbb_common::anyhow::Error> {
    use hbb_common::{rendezvous_proto::rendezvous_message::Union, sodiumoxide::crypto::sealedbox};
    let Some(Union::SealedSignal(signal)) = &message else { return Ok(message); };
    if signal.payload.len() > 4096 { hbb_common::bail!("Invalid sealed signalling size"); }
    let (secret, public) = Config::get_key_pair();
    let secret = sign::SecretKey::from_slice(&secret).ok_or_else(|| hbb_common::anyhow::anyhow!("Missing device key"))?;
    let public = sign::PublicKey::from_slice(&public).ok_or_else(|| hbb_common::anyhow::anyhow!("Missing device public key"))?;
    let secret = sign::to_curve25519_sk(&secret).map_err(|_| hbb_common::anyhow::anyhow!("Invalid device key"))?;
    let public = sign::to_curve25519_pk(&public).map_err(|_| hbb_common::anyhow::anyhow!("Invalid device public key"))?;
    let raw = sealedbox::open(&signal.payload, &public, &secret).map_err(|_| hbb_common::anyhow::anyhow!("Invalid sealed signalling"))?;
    let message = RendezvousMessage::parse_from_bytes(&raw)?;
    match message.union {
        Some(Union::PunchHole(_) | Union::IceCandidate(_)) => Ok(message.union),
        _ => hbb_common::bail!("Unexpected sealed signalling message"),
    }
}

pub fn prepare_registration(message: &mut RendezvousMessage, challenge: &[u8]) -> ResultType<()> {
    if !is_nnu_host(&Config::get_rendezvous_server()) { return Ok(()); }
    use hbb_common::rendezvous_proto::rendezvous_message::Union;
    match message.union.as_mut() {
        Some(Union::RegisterPk(request)) => request.special_fields.mut_unknown_fields().add_varint(92, 1),
        Some(Union::RegisterPeer(request)) => request.special_fields.mut_unknown_fields().add_varint(92, 1),
        _ => return Ok(()),
    }
    if !challenge.is_empty() { sign_signal(message, challenge)?; }
    Ok(())
}

pub fn fallback_url(server: &str) -> Option<String> {
    if !is_nnu_host(server) { return None; }
    let (host, port) = hbb_common::socket_client::split_host_port(server)?;
    let path = match port { 21116 | 21115 => "id", 22222 | 21117 => "relay", _ => return None };
    Some(format!("wss://{host}/ws/{path}"))
}

pub fn punch_default(server: &str, option: &str, value: &str) -> Option<&'static str> {
    (value.is_empty() && is_nnu_host(server)
        && matches!(option, "enable-udp-punch" | "enable-ipv6-punch" | "enable-webrtc"))
        .then_some("Y")
}

pub async fn connect(server: &str, timeout: u64) -> ResultType<Stream> {
    if matches!(server, "wss://rd.nnu.cn/ws/id" | "wss://rd.nnu.cn/ws/relay" | "wss://rd.0vk.com/ws/id" | "wss://rd.0vk.com/ws/relay") {
        return Ok(Stream::WebSocket(hbb_common::websocket::WsFramedStream::new_strict(server, timeout.min(5000)).await?));
    }
    if hbb_common::config::use_ws() {
        if let Some(url) = fallback_url(server) {
            return Ok(Stream::WebSocket(hbb_common::websocket::WsFramedStream::new_strict(&url, timeout.min(5000)).await?));
        }
    }
    let fallback = if LocalConfig::get_option("nnu-tls-fallback") == "N" { None } else { fallback_url(server) };
    let dial_timeout = if fallback.is_some() { timeout.min(1000) } else { timeout };
    match hbb_common::socket_client::connect_tcp(server, dial_timeout).await {
        Ok(stream) => Ok(stream),
        Err(error) => {
            let Some(url) = fallback else { return Err(error); };
            Ok(Stream::WebSocket(hbb_common::websocket::WsFramedStream::new_strict(&url, timeout.min(5000)).await?))
        }
    }
}

pub fn tls_fallback(stream: &Stream) -> bool {
    matches!(stream, Stream::WebSocket(socket) if socket.is_verified_tls())
}

#[cfg(test)]
#[path = "nnu_network_tests.rs"]
mod tests;
