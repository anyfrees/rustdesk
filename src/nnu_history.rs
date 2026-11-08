use hbb_common::{config::{Config,LocalConfig,PeerConfig},log,ResultType};
use serde::Deserialize;
use std::{collections::{HashMap,HashSet},io::Read,sync::{Mutex,OnceLock},time::{Duration,Instant}};

pub fn tick() {
    if !crate::nnu::is_nnu_server() {return}
    static LAST:OnceLock<Mutex<Option<Instant>>>=OnceLock::new();
    let mut last=LAST.get_or_init(||Mutex::new(None)).lock().unwrap();
    if last.map(|at|at.elapsed()<Duration::from_secs(30)).unwrap_or(false) {return}
    *last=Some(Instant::now());drop(last);
    std::thread::spawn(|| {
        if let Err(error)=refresh() {log::debug!("NNU history refresh deferred: {}",error);}
    });
}

fn refresh()->ResultType<()> {
    #[derive(Deserialize)] struct Mapping {old_id:String,id:String}
    #[derive(Deserialize)] struct Reply {schema:u32,mappings:Vec<Mapping>}
    let directory=Config::path("peers");
    let ids:Vec<_>=PeerConfig::get_vec_id_modified_time_path(&None).into_iter().map(|(id,_,_)|id)
        .filter(|id|crate::nnu_history_files::plain_id(id)).collect();
    if ids.is_empty() {return Ok(())}
    let builder=reqwest::blocking::Client::builder().https_only(true).timeout(Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::none());
    #[cfg(target_os="android")]
    let builder=builder.use_preconfigured_tls(hbb_common::verifier::client_config(false)?);
    let client=builder.build()?;
    let mut changed=HashMap::new();
    for batch in ids.chunks(100) {
        let response=client.post("https://rd.nnu.cn/api/nnu/id-resolve").json(&serde_json::json!({"ids":batch})).send()?.error_for_status()?;
        let mut data=Vec::new();response.take(131073).read_to_end(&mut data)?;
        if data.len()>131072 {hbb_common::bail!("ID response too large")}
        let reply:Reply=serde_json::from_slice(&data)?;
        if reply.schema!=1 || reply.mappings.len()>batch.len() {hbb_common::bail!("Invalid ID mapping response")}
        for mapping in reply.mappings {
            if !batch.contains(&mapping.old_id) || !crate::nnu_history_files::plain_id(&mapping.id) {continue}
            let config=PeerConfig::load(&mapping.old_id);
            if config.options.contains_key("other-server-key") {continue}
            if crate::nnu_history_files::migrate(&directory,&mapping.old_id,&mapping.id)? {changed.insert(mapping.old_id,mapping.id);}
        }
    }
    if changed.is_empty() {return Ok(())}
    let mut seen=HashSet::new();
    let favorites=LocalConfig::get_fav().into_iter().map(|id|changed.get(&id).cloned().unwrap_or(id)).filter(|id|seen.insert(id.clone())).collect();
    LocalConfig::set_fav(favorites);
    let remote=LocalConfig::get_remote_id();if let Some(id)=changed.get(&remote) {LocalConfig::set_remote_id(id);}
    crate::flutter_ffi::main_load_recent_peers();
    crate::flutter_ffi::main_load_fav_peers();
    Ok(())
}
