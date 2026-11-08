use std::{fs, io, path::Path, time::{SystemTime,UNIX_EPOCH}};

pub fn plain_id(id: &str) -> bool {
    !id.is_empty() && id.len()<=100 && id.bytes().all(|c|c.is_ascii_alphanumeric() || c==b'_' || c==b'-')
}

pub fn migrate(directory: &Path, old: &str, new: &str) -> io::Result<bool> {
    if !plain_id(old) || !plain_id(new) || old==new {return Ok(false)}
    let source=directory.join(format!("{old}.toml"));let target=directory.join(format!("{new}.toml"));
    match fs::symlink_metadata(&source) {
        Ok(metadata) if metadata.file_type().is_file()=>{},
        Ok(_)=>return Ok(false),
        Err(error) if error.kind()==io::ErrorKind::NotFound=>return Ok(false),
        Err(error)=>return Err(error),
    }
    if target.try_exists()? {
        // Keep the newer target's settings and archive the old credentials;
        // an existing history entry must never be overwritten during refresh.
        let backup=directory.join("nnu-id-history-backups");fs::create_dir_all(&backup)?;
        let stamp=SystemTime::now().duration_since(UNIX_EPOCH).map_err(io::Error::other)?.as_nanos();
        fs::rename(&source,backup.join(format!("{old}-{new}-{stamp}.toml")))?;
    } else {
        // create-only preserves the original bytes and modification time.
        fs::hard_link(&source,&target)?;
        fs::remove_file(&source)?;
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
 use super::*;
 fn directory()->std::path::PathBuf {let p=std::env::temp_dir().join(format!("nnu-history-{}-{}",std::process::id(),SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));fs::create_dir(&p).unwrap();p}
 #[test] fn renamed_history_preserves_saved_credentials_and_timestamp() {
  let root=directory();let old=root.join("1662224467.toml");fs::write(&old,b"encrypted-password-and-user-settings").unwrap();let modified=fs::metadata(&old).unwrap().modified().unwrap();
  assert!(migrate(&root,"1662224467","homepc").unwrap());assert_eq!(fs::read(root.join("homepc.toml")).unwrap(),b"encrypted-password-and-user-settings");assert_eq!(fs::metadata(root.join("homepc.toml")).unwrap().modified().unwrap(),modified);assert!(!old.exists());fs::remove_dir_all(root).unwrap();
 }
 #[test] fn existing_target_survives_and_old_credentials_are_archived() {
  let root=directory();fs::write(root.join("oldpc1.toml"),b"old").unwrap();fs::write(root.join("homepc.toml"),b"new").unwrap();assert!(migrate(&root,"oldpc1","homepc").unwrap());assert_eq!(fs::read(root.join("homepc.toml")).unwrap(),b"new");let archived=fs::read_dir(root.join("nnu-id-history-backups")).unwrap().next().unwrap().unwrap().path();assert_eq!(fs::read(archived).unwrap(),b"old");assert!(!migrate(&root,"../private","homepc").unwrap());assert!(!migrate(&root,"homepc@other","homepc").unwrap());fs::remove_dir_all(root).unwrap();
 }
}
