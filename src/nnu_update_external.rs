use hbb_common::{anyhow::anyhow, bail, sodiumoxide::crypto::sign, ResultType};
use std::{
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    time::Duration,
};

pub(super) fn certified_key(
    certificate: &serde_json::Value,
    root: &str,
) -> ResultType<sign::PublicKey> {
    if serde_json::to_vec(certificate)?.len() > 4096 {
        bail!("External update certificate too large");
    }
    let payload = crate::decode64(
        certificate["payload"]
            .as_str()
            .ok_or_else(|| anyhow!("Missing certificate payload"))?,
    )?;
    let signature = sign::Signature::from_bytes(&crate::decode64(
        certificate["signature"]
            .as_str()
            .ok_or_else(|| anyhow!("Missing certificate signature"))?,
    )?)
    .map_err(|_| anyhow!("Invalid certificate signature"))?;
    let key = sign::PublicKey::from_slice(&crate::decode64(root)?)
        .ok_or_else(|| anyhow!("Invalid root key"))?;
    if !sign::verify_detached(&signature, &payload, &key) {
        bail!("External update certificate is not trusted");
    }
    let claims: serde_json::Value = serde_json::from_slice(&payload)?;
    if claims["schema"].as_u64() != Some(1)
        || claims["purpose"].as_str() != Some("nnu-external-updates")
        || claims["origin"].as_str() != Some("https://rd.nnu.cn")
    {
        bail!("External update certificate scope mismatch");
    }
    sign::PublicKey::from_slice(&crate::decode64(
        claims["public_key"]
            .as_str()
            .ok_or_else(|| anyhow!("Missing certified key"))?,
    )?)
    .ok_or_else(|| anyhow!("Invalid certified key"))
}

pub(super) fn public_address(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(ip) => {
            let b = ip.octets();
            !(b[0] == 0
                || b[0] == 10
                || b[0] == 127
                || b[0] >= 224
                || b[0] == 100 && (64..=127).contains(&b[1])
                || b[0] == 169 && b[1] == 254
                || b[0] == 172 && (16..=31).contains(&b[1])
                || b[0] == 192 && (b[1] == 168 || b[1] == 0 && (b[2] == 0 || b[2] == 2))
                || b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100)
                || b[0] == 203 && b[1] == 0 && b[2] == 113)
        }
        IpAddr::V6(ip) => {
            let b = ip.segments();
            b[0] & 0xe000 == 0x2000
                && b[0] != 0x2002
                && !(b[0] == 0x2001 && (b[1] == 0xdb8 || b[1] <= 0x1ff))
        }
    }
}

pub(super) fn validate_url(value: &str) -> ResultType<reqwest::Url> {
    let url = reqwest::Url::parse(value)?;
    if value.is_empty()
        || value.len() > 4096
        || value.chars().any(|c| c.is_whitespace() || c == '\\')
        || url.scheme() != "https"
        || url.port_or_known_default() != Some(443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        bail!("External download requires a public HTTPS URL");
    }
    let host = url
        .host_str()
        .ok_or_else(|| anyhow!("Missing external host"))?;
    if host.eq_ignore_ascii_case("localhost") || host.ends_with('.') {
        bail!("Invalid external host");
    }
    if let Ok(ip) = host.trim_matches(['[', ']']).parse::<IpAddr>() {
        if !public_address(ip) {
            bail!("External download cannot use a private or reserved address");
        }
    }
    Ok(url)
}

fn open_one(value: &str) -> ResultType<reqwest::blocking::Response> {
    let mut url = validate_url(value)?;
    for hop in 0..=5 {
        validate_url(url.as_str())?;
        let host = url
            .host_str()
            .ok_or_else(|| anyhow!("Missing external host"))?;
        let literal = host.trim_matches(['[', ']']).parse::<IpAddr>().is_ok();
        let addresses: Vec<SocketAddr> = (host.trim_matches(['[', ']']), 443)
            .to_socket_addrs()?
            .filter(|address| {
                // Some local TUN proxies return a DNS-only benchmark address.
                let tunnel = match address.ip() {
                    IpAddr::V4(ip) => {
                        let b = ip.octets();
                        !literal && b[0] == 198 && (b[1] == 18 || b[1] == 19)
                    }
                    _ => false,
                };
                public_address(address.ip()) || tunnel
            })
            .collect();
        if addresses.is_empty() {
            bail!("External download resolved to a private or reserved network");
        }
        let client = reqwest::blocking::Client::builder()
            .https_only(true)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(15))
            .timeout(Duration::from_secs(1800))
            .resolve_to_addrs(host, &addresses)
            .build()?;
        let response = client
            .get(url.clone())
            .header("Accept-Encoding", "identity")
            .send()?;
        if [301, 302, 303, 307, 308].contains(&response.status().as_u16()) {
            if hop == 5 {
                bail!("Too many external download redirects");
            }
            let location = response
                .headers()
                .get(reqwest::header::LOCATION)
                .ok_or_else(|| anyhow!("External redirect has no destination"))?
                .to_str()?;
            url = url.join(location)?;
            continue;
        }
        if response.status() != reqwest::StatusCode::OK {
            bail!("External download returned {}", response.status());
        }
        let mime = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .split(';')
            .next()
            .unwrap_or("")
            .trim();
        let encoding = response
            .headers()
            .get(reqwest::header::CONTENT_ENCODING)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("identity");
        if ["text/html", "application/xhtml+xml", "application/json"].contains(&mime)
            || encoding != "identity"
        {
            bail!("External download returned a webpage or encoded content");
        }
        return Ok(response);
    }
    bail!("External download failed")
}

pub(super) fn open(mirrors: &[String]) -> ResultType<reqwest::blocking::Response> {
    let mut last = anyhow!("Missing external download URL");
    for value in mirrors {
        match open_one(value) {
            Ok(response) => return Ok(response),
            Err(error) => last = error,
        }
    }
    Err(last)
}
