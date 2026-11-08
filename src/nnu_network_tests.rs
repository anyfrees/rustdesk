use super::*;
use hbb_common::{bytes::Bytes, rendezvous_proto::{rendezvous_message::Union, *}, webrtc::WebRTCStream};

fn isolated_config() {
    static INIT: std::sync::Once = std::sync::Once::new();
    INIT.call_once(|| {
        let name = format!("NNU-ICE-Tests-{}", std::process::id());
        *hbb_common::config::APP_NAME.write().unwrap() = name.clone();
        let path = Config::path("");
        assert!(path.components().any(|part| part.as_os_str().to_string_lossy() == name));
        println!("Isolated native configuration: {}", path.display());
    });
}

#[test]
fn fallback_is_limited_to_known_service_ports_and_hosts() {
    assert_eq!(fallback_url("rd.nnu.cn:21116").as_deref(), Some("wss://rd.nnu.cn/ws/id"));
    assert_eq!(fallback_url("rd.0vk.com:22222").as_deref(), Some("wss://rd.0vk.com/ws/relay"));
    for server in ["rd.nnu.cn.evil:21116", "192.168.1.1:21116", "rd.nnu.cn:3389"] {
        assert!(fallback_url(server).is_none());
    }
}

#[test]
fn automatic_punching_respects_explicit_preferences_and_other_servers() {
    for option in ["enable-udp-punch", "enable-ipv6-punch", "enable-webrtc"] {
        assert_eq!(punch_default("rd.nnu.cn:21116", option, ""), Some("Y"));
        assert_eq!(punch_default("rd.nnu.cn:21116", option, "N"), None);
        assert_eq!(punch_default("rd.nnu.cn:21116", option, "Y"), None);
        assert_eq!(punch_default("private.example:21116", option, ""), None);
    }
}

async fn message(socket: &mut Stream) -> RendezvousMessage {
    RendezvousMessage::parse_from_bytes(&socket.next_timeout(10000).await.unwrap().unwrap()).unwrap()
}

async fn fixture_socket() -> Stream {
    let address = std::env::var("NNU_ICE_TEST_SERVER").unwrap();
    assert_eq!(address, "127.0.0.1:32176", "Never create fixture devices on production");
    let mut socket = hbb_common::socket_client::connect_tcp(address.as_str(), 5000).await.unwrap();
    crate::secure_tcp_required(&mut socket, &std::env::var("NNU_ICE_TEST_PUBLIC_KEY").unwrap()).await.unwrap();
    socket
}

#[tokio::test]
#[ignore = "Run only in the isolated network fixture with a temporary APPDATA"]
async fn native_ice_pair_uses_signed_server_signalling_and_transfers_data() {
    isolated_config();
    assert!(std::env::var("APPDATA").unwrap().contains("nnu-ice-tests"));
    Config::set_option("custom-rendezvous-server".into(), "rd.nnu.cn:21116".into());
    Config::set_option("ice-servers".into(), "stun:127.0.0.1:9".into());
    Config::set_socks(None);
    let id = format!("icetest{}", hbb_common::uuid::Uuid::new_v4().simple());
    Config::set_id(&id);
    let mut target = fixture_socket().await;
    let mut registration = RendezvousMessage::new();
    registration.set_register_pk(RegisterPk { id: id.clone(), uuid: vec![7;16].into(), pk: Config::get_key_pair().1.into(), ..Default::default() });
    prepare_registration(&mut registration, &[]).unwrap();
    target.send(&registration).await.unwrap();
    let challenge = message(&mut target).await.signal_challenge().nonce.clone();
    assert_eq!(challenge.len(), 32);
    let mut registration = RendezvousMessage::new();
    registration.set_register_pk(RegisterPk { id: id.clone(), uuid: vec![7;16].into(), pk: Config::get_key_pair().1.into(), ..Default::default() });
    prepare_registration(&mut registration, &challenge).unwrap();
    target.send(&registration).await.unwrap();
    assert_eq!(message(&mut target).await.register_pk_response().result.enum_value().unwrap(), register_pk_response::Result::OK);
    let mut caller = fixture_socket().await;
    let mut offerer = WebRTCStream::new("", false, 10000).await.unwrap();
    let session = offerer.session_key().to_owned();
    let mut request = RendezvousMessage::new();
    request.set_punch_hole_request(PunchHoleRequest { id: id.clone(), licence_key: "nnu-native-ice-fixture".into(), webrtc_sdp_offer: offerer.local_endpoint().into(), ..Default::default() });
    caller.send(&request).await.unwrap();
    let offer = message(&mut target).await.punch_hole().clone();
    let mut answerer = WebRTCStream::new(&offer.webrtc_sdp_offer, false, 10000).await.unwrap();
    let mut answer_socket = fixture_socket().await;
    let mut answer = RendezvousMessage::new();
    answer.set_punch_hole_sent(PunchHoleSent { socket_addr: offer.socket_addr.clone(), id: id.clone(), version: "1.5.0".into(), webrtc_sdp_answer: answerer.local_endpoint().into(), ..Default::default() });
    sign_signal(&mut answer, &[]).unwrap();
    answer_socket.send(&answer).await.unwrap();
    let mut outgoing = offerer.take_local_ice_rx().unwrap();
    let mut returning = answerer.take_local_ice_rx().unwrap();
    let (mut offer_wait, mut answer_wait) = (offerer.clone(), answerer.clone());
    let connected = async move {
        offer_wait.wait_connected(10000).await.unwrap();
        answer_wait.wait_connected(10000).await.unwrap();
    };
    tokio::pin!(connected);
    let mut identity_verified = false;
    loop {
        tokio::select! {
            _ = &mut connected => break,
            Some(candidate) = outgoing.recv() => {
                let mut msg = RendezvousMessage::new();
                msg.set_ice_candidate(IceCandidate { id: id.clone(), session_key: session.clone(), candidate, ..Default::default() });
                caller.send(&msg).await.unwrap();
            }
            Some(candidate) = returning.recv() => {
                let mut msg = RendezvousMessage::new();
                msg.set_ice_candidate(IceCandidate { socket_addr: offer.socket_addr.clone(), session_key: session.clone(), candidate, ..Default::default() });
                sign_signal(&mut msg, &[]).unwrap();
                answer_socket.send(&msg).await.unwrap();
            }
            Some(Ok(bytes)) = target.next() => {
                let msg = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
                answerer.add_remote_ice_candidate(&msg.ice_candidate().candidate).await.unwrap();
            }
            Some(Ok(bytes)) = caller.next() => {
                let msg = RendezvousMessage::parse_from_bytes(&bytes).unwrap();
                match msg.union.unwrap() {
                    Union::PunchHoleResponse(response) => {
                        use hbb_common::base64::{Engine, engine::general_purpose::STANDARD};
                        let public = STANDARD.decode(std::env::var("NNU_ICE_TEST_PUBLIC_KEY").unwrap()).unwrap();
                        let public = sign::PublicKey::from_slice(&public).unwrap();
                        assert_eq!(crate::decode_id_pk(&response.pk, &public).unwrap().0, id);
                        identity_verified = true;
                        offerer.set_remote_endpoint(&response.webrtc_sdp_answer).await.unwrap();
                    }
                    Union::IceCandidate(candidate) => { offerer.add_remote_ice_candidate(&candidate.candidate).await.unwrap(); }
                    _ => panic!("Unexpected fixture response"),
                }
            }
        }
    }
    assert!(identity_verified);
    offerer.send_bytes(Bytes::from_static(b"native-ice-forward")).await.unwrap();
    assert_eq!(&answerer.next_timeout(3000).await.unwrap().unwrap()[..], b"native-ice-forward");
    answerer.send_bytes(Bytes::from_static(b"native-ice-backward")).await.unwrap();
    assert_eq!(&offerer.next_timeout(3000).await.unwrap().unwrap()[..], b"native-ice-backward");
    assert_eq!(offerer.is_relayed().await, Some(false));
    offerer.close().await;
    answerer.close().await;
}

#[tokio::test]
#[ignore = "Read-only public TLS probe through a temporary restricted local proxy"]
async fn native_restricted_http_and_socks_proxies_fall_back_to_verified_wss() {
    isolated_config();
    use hbb_common::tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::{TcpListener, TcpStream}};
    assert!(std::env::var("APPDATA").unwrap().contains("nnu-ice-tests"));
    for http in [true, false] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let proxy_address = listener.local_addr().unwrap();
        let proxy = tokio::spawn(async move {
            for attempt in 0..2 {
                let (mut socket, _) = listener.accept().await.unwrap();
                let port = if http {
                    let mut headers = Vec::new();
                    while !headers.ends_with(b"\r\n\r\n") {
                        headers.push(socket.read_u8().await.unwrap());
                        assert!(headers.len() < 4096);
                    }
                    let headers = String::from_utf8(headers).unwrap();
                    if headers.starts_with("CONNECT rd.nnu.cn:443 ") { 443 } else { 21116 }
                } else {
                    assert_eq!(socket.read_u8().await.unwrap(), 5);
                    let count = socket.read_u8().await.unwrap();
                    let mut methods = vec![0; count as usize];socket.read_exact(&mut methods).await.unwrap();
                    socket.write_all(&[5,0]).await.unwrap();
                    let mut request = [0;4];socket.read_exact(&mut request).await.unwrap();
                    let length = match request[3] { 1 => 4, 4 => 16, 3 => socket.read_u8().await.unwrap() as usize, _ => panic!("SOCKS address type") };
                    let mut address = vec![0;length];socket.read_exact(&mut address).await.unwrap();
                    socket.read_u16().await.unwrap()
                };
                assert_eq!(port == 443, attempt == 1);
                if port != 443 {
                    socket.write_all(if http { b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n" } else { &[5,2,0,1,0,0,0,0,0,0] }).await.unwrap();
                    continue;
                }
                let mut remote = TcpStream::connect(("rd.nnu.cn",443)).await.unwrap();
                socket.write_all(if http { b"HTTP/1.1 200 Connection established\r\n\r\n" } else { &[5,0,0,1,127,0,0,1,0,0] }).await.unwrap();
                let _ = hbb_common::tokio::io::copy_bidirectional(&mut socket, &mut remote).await;
            }
        });
        Config::set_socks(Some(hbb_common::config::Socks5Server { proxy: if http { format!("http://{proxy_address}") } else { proxy_address.to_string() }, ..Default::default() }));
        let mut socket = connect("rd.nnu.cn:21116", 5000).await.unwrap();
        assert!(tls_fallback(&socket));
        let mut probe = RendezvousMessage::new();probe.set_test_nat_request(TestNatRequest::new());
        socket.send(&probe).await.unwrap();
        assert!(matches!(message(&mut socket).await.union, Some(Union::TestNatResponse(_))));
        drop(socket);
        proxy.await.unwrap();
        Config::set_socks(None);
    }
    assert!(hbb_common::websocket::WsFramedStream::new_strict("ws://127.0.0.1",100).await.is_err());
}
