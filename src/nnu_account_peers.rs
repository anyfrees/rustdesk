use hbb_common::{
    config::{LocalConfig, PeerConfig},
    log,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    io::Read,
    sync::{Mutex, OnceLock},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
struct Peer {
    id: String,
    alias: String,
    note: String,
    hostname: String,
    username: String,
    platform: String,
    favorite: bool,
    recent: bool,
    last_visit: i64,
    revision: u64,
    redirect: String,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
struct Operation {
    seq: u64,
    id: String,
    kind: String,
    text: String,
    enabled: bool,
    recent: bool,
    favorite: bool,
    alias: String,
    note: String,
    last_visit: i64,
    hostname: String,
    username: String,
    platform: String,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(default)]
struct Cache {
    replica: String,
    sequence: u64,
    cursor: u64,
    imported: bool,
    operations: Vec<Operation>,
    peers: HashMap<String, Peer>,
}

#[derive(Default)]
struct State {
    scope: String,
    cache: Cache,
    disabled: bool,
    last: Option<Instant>,
    running: bool,
}

struct Context {
    scope: String,
    origin: String,
    account_id: u64,
    token: String,
}
#[derive(Deserialize)]
struct Reply {
    schema: u8,
    account_id: u64,
    replica: String,
    ack: u64,
    cursor: u64,
    more: bool,
    peers: Vec<Peer>,
}

fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(State::default()))
}

fn fingerprint(text: &str) -> String {
    hbb_common::sodiumoxide::crypto::hash::sha256::hash(text.as_bytes())
        .as_ref()
        .iter()
        .map(|v| format!("{v:02x}"))
        .collect()
}

fn context() -> Option<Context> {
    if !crate::flutter::get_global_event_channels()
        .iter()
        .any(|v| v == crate::flutter::APP_TYPE_MAIN)
    {
        return None;
    }
    let origin = crate::nnu_official_support::origin()?;
    let token = LocalConfig::get_option("access_token");
    if token.is_empty() {
        return None;
    }
    let info: serde_json::Value =
        serde_json::from_str(&LocalConfig::get_option("user_info")).ok()?;
    let id = info.get("id")?;
    let account_id = id.as_u64().or_else(|| id.as_str()?.parse().ok())?;
    if account_id == 0 {
        return None;
    }
    Some(Context {
        scope: format!(
            "nnu-account-peers-{}",
            fingerprint(&format!("{origin}\0{account_id}"))
        ),
        origin,
        account_id,
        token,
    })
}

fn load(state: &mut State, ctx: &Context) -> bool {
    if state.scope == ctx.scope {
        return false;
    }
    state.scope = ctx.scope.clone();
    state.cache = serde_json::from_str(&LocalConfig::get_option(&ctx.scope)).unwrap_or_default();
    if state.cache.replica.is_empty() {
        state.cache.replica = uuid::Uuid::new_v4().to_string();
    }
    state.disabled = false;
    state.last = None;
    true
}

fn persist(state: &State) {
    match serde_json::to_string(&state.cache) {
        Ok(value) => LocalConfig::set_option(state.scope.clone(), value),
        Err(error) => log::trace!("Account peer cache deferred: {error}"),
    }
}

fn refresh_views() {
    crate::flutter_ffi::main_load_recent_peers();
    crate::flutter_ffi::main_load_fav_peers();
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 256
        && id
            .bytes()
            .all(|v| v.is_ascii_alphanumeric() || b"_.:@[]-".contains(&v))
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|v| v.as_millis() as i64)
        .unwrap_or(0)
}

fn optimistic(cache: &mut Cache, op: &Operation) {
    if op.kind == "seed" {
        return;
    }
    let peer = cache.peers.entry(op.id.clone()).or_insert_with(|| Peer {
        id: op.id.clone(),
        ..Default::default()
    });
    match op.kind.as_str() {
        "alias" => peer.alias = op.text.clone(),
        "note" => peer.note = op.text.clone(),
        "favorite" => peer.favorite = op.enabled,
        "remove_history" => peer.recent = false,
        "visit" => {
            peer.recent = true;
            peer.last_visit = peer.last_visit.max(op.last_visit);
        }
        _ => {}
    }
    if !op.hostname.is_empty() {
        peer.hostname = op.hostname.clone();
    }
    if !op.username.is_empty() {
        peer.username = op.username.clone();
    }
    if !op.platform.is_empty() {
        peer.platform = op.platform.clone();
    }
}

fn enqueue(cache: &mut Cache, mut op: Operation) {
    cache.sequence += 1;
    op.seq = cache.sequence;
    optimistic(cache, &op);
    cache.operations.push(op);
}

fn queue(op: Operation) -> bool {
    if !valid_id(&op.id) {
        return false;
    }
    let Some(ctx) = context() else {
        return false;
    };
    let mut guard = state().lock().unwrap();
    load(&mut guard, &ctx);
    if guard.disabled {
        return false;
    }
    enqueue(&mut guard.cache, op);
    guard.last = None;
    persist(&guard);
    drop(guard);
    refresh_views();
    true
}

pub(crate) fn alias(id: &str) -> Option<String> {
    let ctx = context()?;
    let mut guard = state().lock().unwrap();
    load(&mut guard, &ctx);
    if guard.disabled {
        return None;
    }
    Some(
        guard
            .cache
            .peers
            .get(id)
            .map(|v| v.alias.clone())
            .unwrap_or_default(),
    )
}

pub(crate) fn rename(id: &str, alias: &str) -> bool {
    if alias.len() > 512 {
        return false;
    }
    queue(Operation {
        id: id.into(),
        kind: "alias".into(),
        text: alias.into(),
        ..Default::default()
    })
}

pub(crate) fn remove_history(id: &str) {
    queue(Operation {
        id: id.into(),
        kind: "remove_history".into(),
        ..Default::default()
    });
}

fn metadata(id: &str, kind: &str, config: &PeerConfig) -> Operation {
    Operation {
        id: id.into(),
        kind: kind.into(),
        hostname: clipped(&config.info.hostname, 512),
        username: clipped(&config.info.username, 512),
        platform: clipped(&config.info.platform, 64),
        ..Default::default()
    }
}

fn clipped(text: &str, limit: usize) -> String {
    let mut end = text.len().min(limit);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}

pub(crate) fn visit(id: &str, config: &PeerConfig) {
    if config.options.contains_key("other-server-key") {
        return;
    }
    let mut op = metadata(id, "visit", config);
    op.last_visit = now();
    queue(op);
}

pub(crate) fn favorites() -> Option<Vec<String>> {
    let ctx = context()?;
    let mut guard = state().lock().unwrap();
    load(&mut guard, &ctx);
    if guard.disabled {
        return None;
    }
    let mut ids: Vec<_> = guard
        .cache
        .peers
        .values()
        .filter(|v| v.favorite)
        .map(|v| v.id.clone())
        .collect();
    ids.sort();
    Some(ids)
}

pub(crate) fn set_favorites(ids: &[String]) -> bool {
    let Some(ctx) = context() else {
        return false;
    };
    let mut guard = state().lock().unwrap();
    load(&mut guard, &ctx);
    if guard.disabled {
        return false;
    }
    let desired: HashSet<_> = ids.iter().filter(|id| valid_id(id)).cloned().collect();
    let existing: HashSet<_> = guard
        .cache
        .peers
        .values()
        .filter(|v| v.favorite)
        .map(|v| v.id.clone())
        .collect();
    for id in existing.symmetric_difference(&desired) {
        let mut op = metadata(id, "favorite", &PeerConfig::load(id));
        op.enabled = desired.contains(id);
        enqueue(&mut guard.cache, op);
    }
    guard.last = None;
    persist(&guard);
    drop(guard);
    refresh_views();
    true
}

pub(crate) fn ui_peers(favorites: bool) -> Option<Vec<HashMap<&'static str, String>>> {
    let ctx = context()?;
    let mut guard = state().lock().unwrap();
    load(&mut guard, &ctx);
    if guard.disabled {
        return None;
    }
    let mut peers: Vec<_> = guard
        .cache
        .peers
        .values()
        .filter(|v| if favorites { v.favorite } else { v.recent })
        .cloned()
        .collect();
    drop(guard);
    peers.sort_by(|a, b| {
        b.last_visit
            .cmp(&a.last_visit)
            .then_with(|| a.id.cmp(&b.id))
    });
    Some(
        peers
            .into_iter()
            .map(|peer| {
                let mut config = PeerConfig::load(&peer.id);
                config.info.hostname = peer.hostname;
                config.info.username = peer.username;
                config.info.platform = peer.platform;
                config.options.insert("alias".into(), peer.alias);
                let mut row = crate::ui_interface::peer_to_map(peer.id, config);
                row.insert("note", peer.note);
                row
            })
            .collect(),
    )
}

pub(crate) fn account_changed() {
    state().lock().unwrap().last = None;
    tick();
    refresh_views();
}

pub(crate) fn tick() {
    let Some(ctx) = context() else {
        let mut guard = state().lock().unwrap();
        let changed = !guard.scope.is_empty();
        guard.scope.clear();
        guard.cache = Cache::default();
        drop(guard);
        if changed {
            refresh_views();
        }
        return;
    };
    let mut guard = state().lock().unwrap();
    let changed = load(&mut guard, &ctx);
    let due = !guard.running
        && guard
            .last
            .map(|v| v.elapsed() >= Duration::from_secs(10))
            .unwrap_or(true);
    if due {
        guard.running = true;
        guard.last = Some(Instant::now());
    }
    drop(guard);
    if changed {
        refresh_views();
    }
    if !due {
        return;
    }
    std::thread::spawn(move || {
        if let Err(error) = synchronize(&ctx) {
            log::trace!("Account peer sync deferred: {error}");
        }
        state().lock().unwrap().running = false;
    });
}

fn import_local(guard: &mut State, ctx: &Context) {
    let key = format!(
        "nnu-account-peers-import-owner-{}",
        fingerprint(&ctx.origin)
    );
    let owner = LocalConfig::get_option(&key);
    if owner.is_empty() || owner == ctx.scope {
        let favorites: HashSet<_> = LocalConfig::get_fav().into_iter().collect();
        let mut seen = HashSet::new();
        for (id, modified, _) in PeerConfig::get_vec_id_modified_time_path(&None) {
            if !valid_id(&id) {
                continue;
            }
            let config = PeerConfig::load(&id);
            if config.options.contains_key("other-server-key") {
                continue;
            }
            let mut op = metadata(&id, "seed", &config);
            op.recent = true;
            op.favorite = favorites.contains(&id);
            op.last_visit = modified
                .duration_since(UNIX_EPOCH)
                .map(|v| v.as_millis() as i64)
                .unwrap_or(0);
            op.alias = clipped(
                config
                    .options
                    .get("alias")
                    .map(String::as_str)
                    .unwrap_or_default(),
                512,
            );
            op.note = clipped(
                config
                    .options
                    .get("note")
                    .map(String::as_str)
                    .unwrap_or_default(),
                2048,
            );
            seen.insert(id);
            enqueue(&mut guard.cache, op);
        }
        for id in favorites.difference(&seen) {
            if valid_id(id) {
                let mut op = metadata(id, "seed", &PeerConfig::load(id));
                op.favorite = true;
                enqueue(&mut guard.cache, op);
            }
        }
        LocalConfig::set_option(key, ctx.scope.clone());
    }
    guard.cache.imported = true;
    guard.last = None;
}

fn merge(cache: &mut Cache, reply: Reply) -> hbb_common::ResultType<bool> {
    let acknowledged = cache
        .operations
        .first()
        .map(|v| v.seq.saturating_sub(1))
        .unwrap_or(cache.sequence);
    if reply.ack > cache.sequence
        || reply.ack < acknowledged
        || reply.cursor < cache.cursor
        || reply.peers.iter().any(|p| {
            !valid_id(&p.id)
                || (!p.redirect.is_empty() && !valid_id(&p.redirect))
                || p.revision > reply.cursor
        })
    {
        hbb_common::bail!("Invalid account peer acknowledgment");
    }
    for peer in reply.peers {
        if peer.redirect.is_empty() {
            cache.peers.insert(peer.id.clone(), peer);
        } else {
            cache.peers.remove(&peer.id);
        }
    }
    cache.operations.retain(|op| op.seq > reply.ack);
    cache.cursor = reply.cursor;
    let pending = cache.operations.clone();
    for op in pending {
        optimistic(cache, &op);
    }
    Ok(reply.more)
}

fn synchronize(ctx: &Context) -> hbb_common::ResultType<()> {
    let (replica, cursor, operations) = {
        let guard = state().lock().unwrap();
        if guard.scope != ctx.scope {
            return Ok(());
        }
        (
            guard.cache.replica.clone(),
            guard.cache.cursor,
            guard
                .cache
                .operations
                .iter()
                .take(100)
                .cloned()
                .collect::<Vec<_>>(),
        )
    };
    let builder = reqwest::blocking::Client::builder()
        .https_only(true)
        .timeout(Duration::from_secs(6))
        .redirect(reqwest::redirect::Policy::none());
    #[cfg(target_os = "android")]
    let builder = builder.use_preconfigured_tls(hbb_common::verifier::client_config(false)?);
    let response = builder
        .build()?
        .post(format!("{}/api/nnu/account-peers/sync", ctx.origin))
        .bearer_auth(&ctx.token)
        .json(&serde_json::json!({"replica":replica,"cursor":cursor,"operations":operations}))
        .send()?;
    let unsupported = response.status() == reqwest::StatusCode::NOT_FOUND;
    let reply = if unsupported {
        None
    } else {
        let mut bytes = Vec::new();
        response
            .error_for_status()?
            .take(4 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 4 * 1024 * 1024 {
            hbb_common::bail!("Account peer response too large");
        }
        let reply: Reply = serde_json::from_slice(&bytes)?;
        if reply.schema != 1
            || reply.account_id != ctx.account_id
            || reply.replica != replica
            || reply.peers.len() > 500
        {
            hbb_common::bail!("Account peer response identity mismatch");
        }
        Some(reply)
    };
    let Some(current) = context() else {
        return Ok(());
    };
    if current.scope != ctx.scope || current.token != ctx.token {
        return Ok(());
    }
    let mut guard = state().lock().unwrap();
    if guard.scope != ctx.scope {
        return Ok(());
    }
    guard.disabled = unsupported;
    if let Some(reply) = reply {
        let more = merge(&mut guard.cache, reply)?;
        if !guard.cache.imported {
            import_local(&mut guard, ctx);
        }
        if more || !guard.cache.operations.is_empty() {
            guard.last = None;
        }
        persist(&guard);
    }
    drop(guard);
    refresh_views();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn offline_changes_survive_restart_without_uploading_credentials() {
        let mut native = PeerConfig::default();
        native.info.hostname = "办公电脑".into();
        native.password = b"private-password".to_vec();
        native
            .options
            .insert("os-password".into(), "private-os-password".into());
        let mut cache = Cache::default();
        let mut visit = metadata("610000001", "visit", &native);
        visit.last_visit = 100;
        enqueue(&mut cache, visit);
        enqueue(
            &mut cache,
            Operation {
                id: "610000001".into(),
                kind: "alias".into(),
                text: "教室电脑".into(),
                ..Default::default()
            },
        );
        let encoded = serde_json::to_string(&cache).unwrap();
        assert!(
            !encoded.contains("password")
                && !encoded.contains("token")
                && !encoded.contains("\"hash\"")
        );
        let restored: Cache = serde_json::from_str(&encoded).unwrap();
        assert_eq!(restored.operations.len(), 2);
        assert_eq!(restored.sequence, 2);
        assert_eq!(restored.peers["610000001"].alias, "教室电脑");
        assert!(restored.peers["610000001"].recent);
        assert_eq!(native.password, b"private-password");
        assert_ne!(
            fingerprint("https://rd.nnu.cn\u{0}7"),
            fingerprint("https://rd.nnu.cn\u{0}8")
        );
    }
    #[test]
    fn remote_refresh_keeps_unsent_changes_and_applies_confirmed_removals() {
        let mut cache = Cache::default();
        enqueue(
            &mut cache,
            Operation {
                id: "610000001".into(),
                kind: "favorite".into(),
                enabled: true,
                ..Default::default()
            },
        );
        enqueue(
            &mut cache,
            Operation {
                id: "610000001".into(),
                kind: "alias".into(),
                text: "本机新备注".into(),
                ..Default::default()
            },
        );
        let reply = |ack, cursor, peer| Reply {
            schema: 1,
            account_id: 7,
            replica: "device-fixture".into(),
            ack,
            cursor,
            more: false,
            peers: vec![peer],
        };
        merge(
            &mut cache,
            reply(
                1,
                1,
                Peer {
                    id: "610000001".into(),
                    alias: "旧备注".into(),
                    favorite: true,
                    revision: 1,
                    ..Default::default()
                },
            ),
        )
        .unwrap();
        assert_eq!(cache.operations.len(), 1);
        assert_eq!(cache.peers["610000001"].alias, "本机新备注");
        merge(
            &mut cache,
            reply(
                2,
                3,
                Peer {
                    id: "610000001".into(),
                    alias: "本机新备注".into(),
                    revision: 3,
                    ..Default::default()
                },
            ),
        )
        .unwrap();
        assert!(cache.operations.is_empty());
        assert!(!cache.peers["610000001"].favorite && !cache.peers["610000001"].recent);
    }
}
