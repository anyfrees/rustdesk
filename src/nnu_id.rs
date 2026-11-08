use hbb_common::{anyhow::anyhow, sodiumoxide::crypto::sign, ResultType};

pub async fn change_proof(old_id: &str, new_id: &str, uuid: &[u8]) -> ResultType<Vec<u8>> {
    #[cfg(not(target_os="android"))]
    let secret = registered_desktop_key().await?;
    #[cfg(target_os="android")]
    let secret = hbb_common::config::Config::get_key_pair().0;
    let key = sign::SecretKey::from_slice(&secret)
        .ok_or_else(|| anyhow!("Invalid device signing key"))?;
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();
    let mut proof = timestamp.to_le_bytes().to_vec();
    proof.extend_from_slice(sign::sign_detached(&crate::nnu::id_change_message(old_id,new_id,uuid,timestamp),&key).as_ref());
    Ok(proof)
}

#[cfg(not(target_os="android"))]
pub(crate) async fn registered_desktop_key()->ResultType<Vec<u8>> {
    let mut connection = crate::ipc::connect(1_000, "").await?;
    connection
        .send(&crate::ipc::Data::ConfirmedKey(None))
        .await?;
    let secret = match connection.next_timeout(1_000).await? {
        Some(crate::ipc::Data::ConfirmedKey(Some((secret, _)))) => secret,
        _ => return Err(anyhow!("Device signing key has not been registered")),
    };
    Ok(secret)
}
