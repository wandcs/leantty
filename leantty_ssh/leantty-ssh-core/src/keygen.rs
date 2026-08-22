use russh::keys::ssh_key::private::PrivateKey;
use std::path::{Path, PathBuf};

const MAX_KEY_COMMENT_BYTES: usize = 1023;

pub fn load_private_key(
    key_path: &str,
    passphrase: &str,
) -> std::result::Result<PrivateKey, String> {
    if passphrase.is_empty() {
        russh::keys::load_secret_key(key_path, None).map_err(|e| format!("Cannot load key: {}", e))
    } else {
        russh::keys::load_secret_key(key_path, Some(passphrase))
            .map_err(|e| format!("Cannot load key: {}", e))
    }
}

pub struct KeyGenResult {
    pub private_path: String,
    pub public_path: String,
    pub fingerprint: String,
}

pub struct KeyInspection {
    pub algorithm: String,
    pub public_key: String,
    pub fingerprint: String,
    pub encrypted: bool,
}

pub fn inspect_private_key(key_path: &str) -> Result<KeyInspection, String> {
    let content =
        std::fs::read_to_string(key_path).map_err(|e| format!("read private key failed: {}", e))?;
    let private_key = PrivateKey::from_openssh(&content)
        .map_err(|e| format!("parse private key failed: {}", e))?;
    let public_key = private_key.public_key();
    let algorithm = public_key.algorithm().as_str().to_string();
    if !matches!(
        algorithm.as_str(),
        "ssh-ed25519"
            | "ssh-rsa"
            | "ecdsa-sha2-nistp256"
            | "ecdsa-sha2-nistp384"
            | "ecdsa-sha2-nistp521"
    ) {
        return Err(format!("unsupported private key type: {}", algorithm));
    }
    Ok(KeyInspection {
        algorithm,
        public_key: public_key.to_string(),
        fingerprint: private_key
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string(),
        encrypted: private_key.is_encrypted(),
    })
}

pub fn read_key_comment(key_path: &str, passphrase: &str) -> Result<String, String> {
    let content = std::fs::read_to_string(key_path)
        .map_err(|error| format!("read private key failed: {}", error))?;
    let parsed = PrivateKey::from_openssh(&content)
        .map_err(|error| format!("parse private key failed: {}", error))?;
    let private_key = if parsed.is_encrypted() {
        parsed
            .decrypt(passphrase)
            .map_err(|_| "passphrase is incorrect".to_string())?
    } else {
        if !passphrase.is_empty() {
            return Err("passphrase is incorrect".to_string());
        }
        parsed
    };
    private_key
        .comment()
        .as_str()
        .map(str::to_owned)
        .map_err(|_| "private key comment is not valid UTF-8".to_string())
}

pub fn protect_private_key(key_path: &str) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(key_path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("chmod private key failed: {}", e))?;
    }
    Ok(())
}

pub fn change_private_key_passphrase(
    key_path: &str,
    old_passphrase: &str,
    new_passphrase: &str,
) -> Result<(), String> {
    change_private_key_passphrase_with_replace(
        key_path,
        old_passphrase,
        new_passphrase,
        |temporary_path, target_path| {
            std::fs::rename(temporary_path, target_path)
                .map_err(|error| format!("replace private key failed: {}", error))
        },
    )
}

fn change_private_key_passphrase_with_replace<F>(
    key_path: &str,
    old_passphrase: &str,
    new_passphrase: &str,
    replace: F,
) -> Result<(), String>
where
    F: FnOnce(&Path, &Path) -> Result<(), String>,
{
    use russh::keys::ssh_key::LineEnding;
    use std::fs::OpenOptions;
    use std::io::Write;

    let target_path = Path::new(key_path);
    let original = std::fs::read_to_string(target_path)
        .map_err(|error| format!("read private key failed: {}", error))?;
    let parsed = PrivateKey::from_openssh(&original)
        .map_err(|error| format!("parse private key failed: {}", error))?;
    let private_key = if parsed.is_encrypted() {
        parsed
            .decrypt(old_passphrase)
            .map_err(|_| "old passphrase is incorrect".to_string())?
    } else {
        if !old_passphrase.is_empty() {
            return Err("old passphrase is incorrect".to_string());
        }
        parsed
    };

    let original_fingerprint = private_key
        .fingerprint(russh::keys::HashAlg::Sha256)
        .to_string();
    let original_public_key = private_key.public_key().to_string();
    let stored_key = if new_passphrase.is_empty() {
        private_key
    } else {
        private_key
            .encrypt(&mut rand::rng(), new_passphrase)
            .map_err(|error| format!("key encryption failed: {}", error))?
    };
    let encoded = stored_key
        .to_openssh(LineEnding::LF)
        .map_err(|error| format!("private key encoding failed: {}", error))?;

    let temporary_path = create_passphrase_temporary_path(target_path)?;
    let write_result = (|| -> Result<(), String> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary_path)
            .map_err(|error| format!("create temporary private key failed: {}", error))?;
        file.write_all(encoded.as_bytes())
            .map_err(|error| format!("write temporary private key failed: {}", error))?;
        file.flush()
            .map_err(|error| format!("flush temporary private key failed: {}", error))?;
        file.sync_all()
            .map_err(|error| format!("sync temporary private key failed: {}", error))?;
        drop(file);

        let written = std::fs::read_to_string(&temporary_path)
            .map_err(|error| format!("verify temporary private key failed: {}", error))?;
        let written_key = PrivateKey::from_openssh(&written)
            .map_err(|error| format!("verify temporary private key failed: {}", error))?;
        let verified_key = if written_key.is_encrypted() {
            written_key
                .decrypt(new_passphrase)
                .map_err(|error| format!("verify temporary private key failed: {}", error))?
        } else {
            written_key
        };
        if verified_key
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string()
            != original_fingerprint
            || verified_key.public_key().to_string() != original_public_key
        {
            return Err("temporary private key changed key identity or comment".to_string());
        }

        replace(&temporary_path, target_path)?;
        let _ = sync_parent_directory(target_path);
        Ok(())
    })();
    if write_result.is_err() {
        let _ = std::fs::remove_file(&temporary_path);
    }
    write_result
}

pub fn change_key_comment(
    key_path: &str,
    passphrase: &str,
    new_comment: &str,
) -> Result<String, String> {
    change_key_comment_with_replace(
        key_path,
        passphrase,
        new_comment,
        |_, temporary_path, target_path| {
            std::fs::rename(temporary_path, target_path)
                .map_err(|error| format!("replace key file failed: {}", error))
        },
    )
}

fn change_key_comment_with_replace<F>(
    key_path: &str,
    passphrase: &str,
    new_comment: &str,
    mut replace: F,
) -> Result<String, String>
where
    F: FnMut(&str, &Path, &Path) -> Result<(), String>,
{
    use russh::keys::ssh_key::{LineEnding, PublicKey};

    validate_key_comment(new_comment)?;

    let private_path = Path::new(key_path);
    let public_path = PathBuf::from(format!("{}.pub", key_path));
    let original_private = std::fs::read(private_path)
        .map_err(|error| format!("read private key failed: {}", error))?;
    let original_public = std::fs::read(&public_path)
        .map_err(|error| format!("read public key failed: {}", error))?;
    let original_private_text = std::str::from_utf8(&original_private)
        .map_err(|error| format!("parse private key failed: {}", error))?;
    let original_public_text = std::str::from_utf8(&original_public)
        .map_err(|error| format!("parse public key failed: {}", error))?;

    let parsed_private = PrivateKey::from_openssh(original_private_text)
        .map_err(|error| format!("parse private key failed: {}", error))?;
    let was_encrypted = parsed_private.is_encrypted();
    let mut private_key = if was_encrypted {
        parsed_private
            .decrypt(passphrase)
            .map_err(|_| "passphrase is incorrect".to_string())?
    } else {
        if !passphrase.is_empty() {
            return Err("passphrase is incorrect".to_string());
        }
        parsed_private
    };
    let parsed_public = PublicKey::from_openssh(original_public_text)
        .map_err(|error| format!("parse public key failed: {}", error))?;
    if parsed_public.key_data() != private_key.public_key().key_data() {
        return Err("private and public key identities do not match".to_string());
    }

    let old_comment = private_key
        .comment()
        .as_str()
        .map_err(|_| "private key comment is not valid UTF-8".to_string())?
        .to_string();
    let old_public_comment = parsed_public
        .comment()
        .as_str()
        .map_err(|_| "public key comment is not valid UTF-8".to_string())?;
    if old_comment == new_comment && old_public_comment == new_comment {
        return Ok(old_comment);
    }
    let original_fingerprint = private_key
        .fingerprint(russh::keys::HashAlg::Sha256)
        .to_string();
    let original_key_data = private_key.public_key().key_data().clone();

    private_key.set_comment(new_comment);
    let updated_public = private_key.public_key().to_string();
    let stored_private = if was_encrypted {
        private_key
            .encrypt(&mut rand::rng(), passphrase)
            .map_err(|error| format!("key encryption failed: {}", error))?
    } else {
        private_key
    };
    let updated_private = stored_private
        .to_openssh(LineEnding::LF)
        .map_err(|error| format!("private key encoding failed: {}", error))?
        .to_string();

    let private_temporary = create_key_comment_aux_path(private_path, "private", "tmp")?;
    let public_temporary = create_key_comment_aux_path(&public_path, "public", "tmp")?;
    let private_backup = create_key_comment_aux_path(private_path, "private", "bak")?;
    let public_backup = create_key_comment_aux_path(&public_path, "public", "bak")?;
    let auxiliary_paths = [
        private_temporary.as_path(),
        public_temporary.as_path(),
        private_backup.as_path(),
        public_backup.as_path(),
    ];

    let result = (|| -> Result<(), String> {
        write_key_comment_file(
            &private_temporary,
            updated_private.as_bytes(),
            0o600,
            "private",
        )?;
        write_key_comment_file(
            &public_temporary,
            updated_public.as_bytes(),
            0o644,
            "public",
        )?;

        let staged_private_text = std::fs::read_to_string(&private_temporary)
            .map_err(|error| format!("verify temporary private key failed: {}", error))?;
        let staged_private = PrivateKey::from_openssh(&staged_private_text)
            .map_err(|error| format!("verify temporary private key failed: {}", error))?;
        if staged_private.is_encrypted() != was_encrypted {
            return Err("temporary private key changed encryption state".to_string());
        }
        let staged_private = if was_encrypted {
            staged_private
                .decrypt(passphrase)
                .map_err(|error| format!("verify temporary private key failed: {}", error))?
        } else {
            staged_private
        };
        let staged_public_text = std::fs::read_to_string(&public_temporary)
            .map_err(|error| format!("verify temporary public key failed: {}", error))?;
        let staged_public = PublicKey::from_openssh(&staged_public_text)
            .map_err(|error| format!("verify temporary public key failed: {}", error))?;
        if staged_private
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string()
            != original_fingerprint
            || staged_private.public_key().key_data() != &original_key_data
            || staged_public.key_data() != &original_key_data
            || staged_private
                .comment()
                .as_str()
                .map_err(|_| "temporary private key comment is not valid UTF-8".to_string())?
                != new_comment
            || staged_public
                .comment()
                .as_str()
                .map_err(|_| "temporary public key comment is not valid UTF-8".to_string())?
                != new_comment
        {
            return Err("temporary key pair failed identity or comment verification".to_string());
        }

        copy_key_comment_backup(private_path, &private_backup, "private")?;
        copy_key_comment_backup(&public_path, &public_backup, "public")?;

        replace("private", &private_temporary, private_path)?;
        if let Err(commit_error) = replace("public", &public_temporary, &public_path) {
            let rollback_result = std::fs::rename(&private_backup, private_path)
                .map_err(|error| format!("restore private key failed: {}", error));
            return match rollback_result {
                Ok(()) => Err(commit_error),
                Err(rollback_error) => Err(format!("{}; {}", commit_error, rollback_error)),
            };
        }

        let _ = std::fs::remove_file(&private_backup);
        let _ = std::fs::remove_file(&public_backup);
        sync_parent_directory(private_path)?;
        Ok(())
    })();

    for path in auxiliary_paths {
        let _ = std::fs::remove_file(path);
    }
    result.map(|_| old_comment)
}

fn validate_key_comment(comment: &str) -> Result<(), String> {
    if comment.len() > MAX_KEY_COMMENT_BYTES {
        return Err(format!(
            "key comment exceeds {} UTF-8 bytes",
            MAX_KEY_COMMENT_BYTES
        ));
    }
    if comment.chars().any(char::is_control) {
        return Err("key comment contains control characters".to_string());
    }
    Ok(())
}

fn create_key_comment_aux_path(
    target_path: &Path,
    role: &str,
    extension: &str,
) -> Result<PathBuf, String> {
    let parent = target_path
        .parent()
        .ok_or_else(|| "key path has no parent directory".to_string())?;
    let file_name = target_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "key path has an invalid file name".to_string())?;
    for attempt in 0..100_u32 {
        let candidate = parent.join(format!(
            ".{}.ltty-comment-{}-{}-{}.{}",
            file_name,
            role,
            std::process::id(),
            attempt,
            extension
        ));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err("cannot allocate key comment transaction path".to_string())
}

fn write_key_comment_file(
    path: &Path,
    contents: &[u8],
    unix_mode: u32,
    role: &str,
) -> Result<(), String> {
    use std::fs::OpenOptions;
    use std::io::Write;

    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(unix_mode);
    }
    #[cfg(not(unix))]
    let _ = unix_mode;
    let mut file = options
        .open(path)
        .map_err(|error| format!("create temporary {} key failed: {}", role, error))?;
    file.write_all(contents)
        .map_err(|error| format!("write temporary {} key failed: {}", role, error))?;
    file.flush()
        .map_err(|error| format!("flush temporary {} key failed: {}", role, error))?;
    file.sync_all()
        .map_err(|error| format!("sync temporary {} key failed: {}", role, error))?;
    Ok(())
}

fn copy_key_comment_backup(source: &Path, backup: &Path, role: &str) -> Result<(), String> {
    std::fs::copy(source, backup)
        .map_err(|error| format!("backup {} key failed: {}", role, error))?;
    std::fs::File::open(backup)
        .and_then(|file| file.sync_all())
        .map_err(|error| format!("sync {} key backup failed: {}", role, error))?;
    Ok(())
}

fn create_passphrase_temporary_path(target_path: &Path) -> Result<PathBuf, String> {
    let parent = target_path
        .parent()
        .ok_or_else(|| "private key path has no parent directory".to_string())?;
    let file_name = target_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| "private key path has an invalid file name".to_string())?;
    for attempt in 0..100_u32 {
        let candidate = parent.join(format!(
            ".{}.ltty-passphrase-{}-{}.tmp",
            file_name,
            std::process::id(),
            attempt
        ));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err("cannot allocate temporary private key path".to_string())
}

fn sync_parent_directory(target_path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        let parent = target_path
            .parent()
            .ok_or_else(|| "private key path has no parent directory".to_string())?;
        std::fs::File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("sync private key directory failed: {}", error))?;
    }
    Ok(())
}

pub fn export_key_pair(
    private_path: &str,
    public_path: &str,
    output_dir: &str,
    file_name: &str,
) -> Result<(), String> {
    use std::fs::{File, OpenOptions};
    use std::io::{self, Write};
    use std::path::Path;

    validate_export_file_name(file_name)?;

    let output_dir_path = Path::new(output_dir);
    if !output_dir_path.is_dir() {
        return Err("Downloads directory is unavailable".to_string());
    }

    let private_destination = output_dir_path.join(file_name);
    let public_destination = output_dir_path.join(format!("{}.pub", file_name));
    if private_destination.exists() || public_destination.exists() {
        return Err(format!("destination already exists: {}", file_name));
    }

    let mut private_source =
        File::open(private_path).map_err(|e| format!("open private key failed: {}", e))?;
    let mut public_source =
        File::open(public_path).map_err(|e| format!("open public key failed: {}", e))?;

    let mut private_options = OpenOptions::new();
    private_options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        private_options.mode(0o600);
    }
    let mut private_destination_file = private_options
        .open(&private_destination)
        .map_err(|e| format!("create export failed: {}", e))?;

    let public_result = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&public_destination);
    let mut public_destination_file = match public_result {
        Ok(file) => file,
        Err(error) => {
            drop(private_destination_file);
            let _ = std::fs::remove_file(&private_destination);
            return Err(format!("create public export failed: {}", error));
        }
    };

    let copy_result = (|| -> io::Result<()> {
        io::copy(&mut private_source, &mut private_destination_file)?;
        private_destination_file.flush()?;
        private_destination_file.sync_all()?;
        io::copy(&mut public_source, &mut public_destination_file)?;
        public_destination_file.flush()?;
        public_destination_file.sync_all()?;
        Ok(())
    })();
    if let Err(error) = copy_result {
        drop(private_destination_file);
        drop(public_destination_file);
        let _ = std::fs::remove_file(&private_destination);
        let _ = std::fs::remove_file(&public_destination);
        return Err(format!("write export failed: {}", error));
    }

    Ok(())
}

pub fn generate_key_pair(
    algorithm: &str,
    output_dir: &str,
    file_name: &str,
    passphrase: &str,
    comment: &str,
) -> Result<KeyGenResult, String> {
    use russh::keys::ssh_key::{private::PrivateKey, Algorithm, LineEnding};

    let algo: Algorithm = if algorithm.to_lowercase().contains("rsa") {
        Algorithm::Rsa { hash: None }
    } else {
        Algorithm::Ed25519
    };
    let algo_name: &str = if algorithm.to_lowercase().contains("rsa") {
        "rsa"
    } else {
        "ed25519"
    };
    let file_name: String = if file_name.is_empty() {
        format!("id_{}", algo_name)
    } else {
        validate_key_name(file_name)?;
        file_name.to_owned()
    };
    let priv_path: String = format!("{}/{}", output_dir, file_name);
    let pub_path: String = format!("{}/{}.pub", output_dir, file_name);

    let mut keypair: PrivateKey =
        PrivateKey::random(&mut rand::rng(), algo).map_err(|e| format!("key gen failed: {}", e))?;
    if !comment.is_empty() {
        keypair.set_comment(comment);
    }
    let stored_key = if passphrase.is_empty() {
        keypair.clone()
    } else {
        keypair
            .encrypt(&mut rand::rng(), passphrase)
            .map_err(|e| format!("key encryption failed: {}", e))?
    };

    let openssh_pem: String = stored_key
        .to_openssh(LineEnding::LF)
        .map_err(|e| format!("pem encode failed: {}", e))?
        .to_string();

    std::fs::create_dir_all(output_dir).map_err(|e| format!("mkdir failed: {}", e))?;

    if std::path::Path::new(&priv_path).exists() || std::path::Path::new(&pub_path).exists() {
        return Err(format!("key already exists: {}", file_name));
    }

    {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&priv_path)
            .map_err(|e| format!("create key failed: {}", e))?;
        f.write_all(openssh_pem.as_bytes())
            .map_err(|e| format!("write key failed: {}", e))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&priv_path, std::fs::Permissions::from_mode(0o600))
                .map_err(|e| format!("chmod key failed: {}", e))?;
        }
    }

    let pub_text: String = keypair.public_key().to_string();
    let public_result = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&pub_path)
        .and_then(|mut file| {
            use std::io::Write;
            file.write_all(pub_text.as_bytes())
        });
    if let Err(error) = public_result {
        let _ = std::fs::remove_file(&priv_path);
        return Err(format!("write pub failed: {}", error));
    }

    let fingerprint: String = keypair
        .fingerprint(russh::keys::HashAlg::Sha256)
        .to_string();

    Ok(KeyGenResult {
        private_path: priv_path,
        public_path: pub_path,
        fingerprint,
    })
}

fn validate_key_name(file_name: &str) -> Result<(), String> {
    if file_name.is_empty() || file_name == "." || file_name == ".." {
        return Err("invalid key name".to_string());
    }
    if file_name.ends_with(".pub")
        || !file_name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
    {
        return Err("invalid key name".to_string());
    }
    let lower = file_name.to_ascii_lowercase();
    for reserved in [
        "config",
        "known_hosts",
        "authorized_keys",
        "rc",
        "environment",
        "moduli",
    ] {
        if lower == reserved || lower.starts_with(&format!("{}.", reserved)) {
            return Err("key name conflicts with SSH control file".to_string());
        }
    }
    Ok(())
}

fn validate_export_file_name(file_name: &str) -> Result<(), String> {
    if file_name.is_empty() || file_name == "." || file_name == ".." {
        return Err("invalid export file name".to_string());
    }
    if file_name.to_ascii_lowercase().ends_with(".pub")
        || !file_name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
    {
        return Err("invalid export file name".to_string());
    }
    Ok(())
}

pub fn read_public_key_fingerprint(key_path: &str) -> Result<String, String> {
    let content: String =
        std::fs::read_to_string(key_path).map_err(|e| format!("read failed: {}", e))?;

    let public_key: russh::keys::ssh_key::PublicKey = content
        .parse()
        .map_err(|e| format!("parse public key failed: {}", e))?;

    let fingerprint: String = public_key
        .fingerprint(russh::keys::HashAlg::Sha256)
        .to_string();
    Ok(fingerprint)
}

#[cfg(test)]
mod tests {
    use super::{
        change_key_comment, change_key_comment_with_replace, change_private_key_passphrase,
        change_private_key_passphrase_with_replace, export_key_pair, generate_key_pair,
        inspect_private_key, load_private_key, read_key_comment,
    };
    use russh::keys::ssh_key::{Algorithm, EcdsaCurve, LineEnding, PrivateKey};
    use std::path::{Path, PathBuf};

    fn write_ecdsa_pair(
        root: &Path,
        name: &str,
        curve: EcdsaCurve,
        passphrase: &str,
        comment: &str,
    ) -> PathBuf {
        std::fs::create_dir_all(root).unwrap();
        let path = root.join(name);
        let mut key = PrivateKey::random(&mut rand::rng(), Algorithm::Ecdsa { curve }).unwrap();
        key.set_comment(comment);
        let public = key.public_key().to_string();
        let stored = if passphrase.is_empty() {
            key
        } else {
            key.encrypt(&mut rand::rng(), passphrase).unwrap()
        };
        std::fs::write(&path, stored.to_openssh(LineEnding::LF).unwrap().as_bytes()).unwrap();
        let public_path = PathBuf::from(format!("{}.pub", path.to_string_lossy()));
        std::fs::write(public_path, public).unwrap();
        path
    }

    #[test]
    fn uses_requested_name_and_refuses_overwrite() {
        let dir = std::env::temp_dir().join(format!("leantty-keygen-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dir_text = dir.to_string_lossy().to_string();

        let generated = generate_key_pair("ed25519", &dir_text, "deploy_key", "", "").unwrap();
        assert!(generated.private_path.ends_with("deploy_key"));
        assert!(generate_key_pair("ed25519", &dir_text, "deploy_key", "", "").is_err());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejects_unsafe_requested_name() {
        let dir = std::env::temp_dir().to_string_lossy().to_string();
        assert!(generate_key_pair("ed25519", &dir, "../escape", "", "").is_err());
    }

    #[test]
    fn rejects_reserved_ssh_file_names() {
        let dir = std::env::temp_dir().to_string_lossy().to_string();
        assert!(generate_key_pair("ed25519", &dir, "config", "", "").is_err());
        assert!(generate_key_pair("ed25519", &dir, "known_hosts.old", "", "").is_err());
    }

    #[test]
    fn inspects_generated_private_key() {
        let dir = std::env::temp_dir().join(format!("leantty-inspect-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dir_text = dir.to_string_lossy().to_string();
        let generated =
            generate_key_pair("ed25519", &dir_text, "inspect_key", "", "test@host").unwrap();
        let inspected = inspect_private_key(&generated.private_path).unwrap();
        assert_eq!(inspected.algorithm, "ssh-ed25519");
        assert_eq!(inspected.fingerprint, generated.fingerprint);
        assert!(!inspected.encrypted);
        assert!(inspected.public_key.ends_with("test@host"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn inspects_all_standard_ecdsa_private_keys() {
        let root =
            std::env::temp_dir().join(format!("leantty-ecdsa-inspect-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let cases = [
            (EcdsaCurve::NistP256, "ecdsa-sha2-nistp256"),
            (EcdsaCurve::NistP384, "ecdsa-sha2-nistp384"),
            (EcdsaCurve::NistP521, "ecdsa-sha2-nistp521"),
        ];

        for (index, (curve, expected)) in cases.into_iter().enumerate() {
            for encrypted in [false, true] {
                let passphrase = if encrypted { "curve-secret" } else { "" };
                let path = write_ecdsa_pair(
                    &root,
                    &format!("curve-{index}-{encrypted}"),
                    curve,
                    passphrase,
                    "existing@openssh",
                );
                let inspected = inspect_private_key(path.to_str().unwrap()).unwrap();
                assert_eq!(inspected.algorithm, expected);
                assert_eq!(inspected.encrypted, encrypted);
                assert!(inspected.public_key.starts_with(expected));
                assert!(load_private_key(path.to_str().unwrap(), passphrase).is_ok());
            }
        }

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn ecdsa_identity_reuses_passphrase_and_comment_transactions() {
        let root =
            std::env::temp_dir().join(format!("leantty-ecdsa-lifecycle-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let path = write_ecdsa_pair(
            &root,
            "existing-ecdsa",
            EcdsaCurve::NistP256,
            "old-secret",
            "old@openssh",
        );
        let path_text = path.to_str().unwrap();
        let fingerprint = inspect_private_key(path_text).unwrap().fingerprint;

        change_private_key_passphrase(path_text, "old-secret", "new-secret").unwrap();
        assert!(load_private_key(path_text, "old-secret").is_err());
        change_key_comment(path_text, "new-secret", "new@leantty").unwrap();

        let inspected = inspect_private_key(path_text).unwrap();
        assert_eq!(inspected.algorithm, "ecdsa-sha2-nistp256");
        assert_eq!(inspected.fingerprint, fingerprint);
        assert!(inspected.encrypted);
        assert_eq!(
            load_private_key(path_text, "new-secret")
                .unwrap()
                .comment()
                .as_str()
                .unwrap(),
            "new@leantty"
        );
        assert!(std::fs::read_to_string(path.with_extension("pub"))
            .unwrap()
            .ends_with("new@leantty"));

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn exports_key_pair_without_overwriting() {
        let root = std::env::temp_dir().join(format!("leantty-export-{}", std::process::id()));
        let source_dir = root.join("source");
        let downloads_dir = root.join("Downloads");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&source_dir).unwrap();
        std::fs::create_dir_all(&downloads_dir).unwrap();

        let source_dir_text = source_dir.to_string_lossy().to_string();
        let downloads_dir_text = downloads_dir.to_string_lossy().to_string();
        let generated =
            generate_key_pair("ed25519", &source_dir_text, "deploy", "", "test@host").unwrap();
        export_key_pair(
            &generated.private_path,
            &generated.public_path,
            &downloads_dir_text,
            "deploy",
        )
        .unwrap();

        assert_eq!(
            std::fs::read(&generated.private_path).unwrap(),
            std::fs::read(downloads_dir.join("deploy")).unwrap()
        );
        assert_eq!(
            std::fs::read(&generated.public_path).unwrap(),
            std::fs::read(downloads_dir.join("deploy.pub")).unwrap()
        );
        assert!(export_key_pair(
            &generated.private_path,
            &generated.public_path,
            &downloads_dir_text,
            "deploy",
        )
        .is_err());
        export_key_pair(
            &generated.private_path,
            &generated.public_path,
            &downloads_dir_text,
            "deploy-backup",
        )
        .unwrap();
        assert_eq!(
            std::fs::read(&generated.private_path).unwrap(),
            std::fs::read(downloads_dir.join("deploy-backup")).unwrap()
        );
        assert_eq!(
            std::fs::read(&generated.public_path).unwrap(),
            std::fs::read(downloads_dir.join("deploy-backup.pub")).unwrap()
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn public_name_conflict_leaves_no_partial_private_export() {
        let root =
            std::env::temp_dir().join(format!("leantty-export-conflict-{}", std::process::id()));
        let source_dir = root.join("source");
        let downloads_dir = root.join("Downloads");
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&source_dir).unwrap();
        std::fs::create_dir_all(&downloads_dir).unwrap();

        let source_dir_text = source_dir.to_string_lossy().to_string();
        let downloads_dir_text = downloads_dir.to_string_lossy().to_string();
        let generated = generate_key_pair("ed25519", &source_dir_text, "work", "", "").unwrap();
        std::fs::write(downloads_dir.join("work.pub"), "existing").unwrap();

        let error = export_key_pair(
            &generated.private_path,
            &generated.public_path,
            &downloads_dir_text,
            "work",
        )
        .unwrap_err();
        assert!(error.contains("destination already exists"));
        assert!(!downloads_dir.join("work").exists());
        assert_eq!(
            std::fs::read_to_string(downloads_dir.join("work.pub")).unwrap(),
            "existing"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn changes_passphrase_without_changing_key_identity_or_comment() {
        let root =
            std::env::temp_dir().join(format!("leantty-change-passphrase-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated =
            generate_key_pair("ed25519", &root_text, "deploy", "old-secret", "test@host").unwrap();
        let before = inspect_private_key(&generated.private_path).unwrap();
        let before_bytes = std::fs::read(&generated.private_path).unwrap();
        let before_public = std::fs::read(&generated.public_path).unwrap();

        change_private_key_passphrase(&generated.private_path, "old-secret", "new-secret").unwrap();

        let after = inspect_private_key(&generated.private_path).unwrap();
        assert_eq!(after.fingerprint, before.fingerprint);
        assert_eq!(after.public_key, before.public_key);
        assert!(after.encrypted);
        assert_ne!(
            std::fs::read(&generated.private_path).unwrap(),
            before_bytes
        );
        assert_eq!(
            std::fs::read(&generated.public_path).unwrap(),
            before_public
        );
        assert!(load_private_key(&generated.private_path, "old-secret").is_err());
        let loaded = load_private_key(&generated.private_path, "new-secret").unwrap();
        assert_eq!(loaded.comment().as_str().unwrap(), "test@host");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn supports_adding_and_removing_a_passphrase() {
        let root = std::env::temp_dir().join(format!(
            "leantty-add-remove-passphrase-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated = generate_key_pair("ed25519", &root_text, "deploy", "", "").unwrap();

        change_private_key_passphrase(&generated.private_path, "", "new-secret").unwrap();
        assert!(
            inspect_private_key(&generated.private_path)
                .unwrap()
                .encrypted
        );
        change_private_key_passphrase(&generated.private_path, "new-secret", "").unwrap();
        assert!(
            !inspect_private_key(&generated.private_path)
                .unwrap()
                .encrypted
        );
        assert!(load_private_key(&generated.private_path, "").is_ok());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn changes_rsa_passphrase_without_changing_the_public_key() {
        let root = std::env::temp_dir().join(format!(
            "leantty-rsa-change-passphrase-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated =
            generate_key_pair("rsa", &root_text, "deploy_rsa", "old-secret", "rsa@host").unwrap();
        let public_before = std::fs::read(&generated.public_path).unwrap();

        change_private_key_passphrase(&generated.private_path, "old-secret", "new-secret").unwrap();

        let loaded = load_private_key(&generated.private_path, "new-secret").unwrap();
        assert_eq!(loaded.comment().as_str().unwrap(), "rsa@host");
        assert_eq!(
            std::fs::read(&generated.public_path).unwrap(),
            public_before
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn wrong_old_passphrase_leaves_private_key_unchanged() {
        let root = std::env::temp_dir().join(format!(
            "leantty-wrong-old-passphrase-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated =
            generate_key_pair("ed25519", &root_text, "deploy", "old-secret", "").unwrap();
        let before = std::fs::read(&generated.private_path).unwrap();

        let error =
            change_private_key_passphrase(&generated.private_path, "wrong-secret", "new-secret")
                .unwrap_err();

        assert!(error.contains("old passphrase is incorrect"));
        assert_eq!(std::fs::read(&generated.private_path).unwrap(), before);
        assert!(load_private_key(&generated.private_path, "old-secret").is_ok());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn replacement_failure_leaves_private_key_unchanged_and_removes_temporary_file() {
        let root = std::env::temp_dir().join(format!(
            "leantty-passphrase-commit-failure-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated = generate_key_pair("ed25519", &root_text, "deploy", "", "").unwrap();
        let before = std::fs::read(&generated.private_path).unwrap();

        let error = change_private_key_passphrase_with_replace(
            &generated.private_path,
            "",
            "new-secret",
            |_, _| Err("forced replacement failure".to_string()),
        )
        .unwrap_err();

        assert!(error.contains("forced replacement failure"));
        assert_eq!(std::fs::read(&generated.private_path).unwrap(), before);
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 2);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn changes_encrypted_key_comment_without_changing_identity_or_passphrase() {
        let root = std::env::temp_dir().join(format!(
            "leantty-change-comment-encrypted-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated =
            generate_key_pair("ed25519", &root_text, "deploy", "key-secret", "old@host").unwrap();
        let fingerprint_before = inspect_private_key(&generated.private_path)
            .unwrap()
            .fingerprint;

        let old_comment =
            change_key_comment(&generated.private_path, "key-secret", "发布 key 2026").unwrap();

        assert_eq!(old_comment, "old@host");
        let inspected = inspect_private_key(&generated.private_path).unwrap();
        assert_eq!(inspected.fingerprint, fingerprint_before);
        assert!(inspected.encrypted);
        assert!(std::fs::read_to_string(&generated.public_path)
            .unwrap()
            .ends_with("发布 key 2026"));
        assert!(load_private_key(&generated.private_path, "wrong-secret").is_err());
        let loaded = load_private_key(&generated.private_path, "key-secret").unwrap();
        assert_eq!(loaded.comment().as_str().unwrap(), "发布 key 2026");
        assert_eq!(
            read_key_comment(&generated.private_path, "key-secret").unwrap(),
            "发布 key 2026"
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&generated.private_path)
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 2);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn removes_plain_key_comment_and_keeps_pair_consistent() {
        let root =
            std::env::temp_dir().join(format!("leantty-remove-comment-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated =
            generate_key_pair("rsa", &root_text, "deploy_rsa", "", "old comment").unwrap();

        assert_eq!(
            change_key_comment(&generated.private_path, "", "").unwrap(),
            "old comment"
        );

        let inspected = inspect_private_key(&generated.private_path).unwrap();
        assert!(!inspected.encrypted);
        assert_eq!(
            std::fs::read_to_string(&generated.public_path).unwrap(),
            inspected.public_key
        );
        assert_eq!(
            load_private_key(&generated.private_path, "")
                .unwrap()
                .comment()
                .as_str()
                .unwrap(),
            ""
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn rejects_wrong_passphrase_and_invalid_comments_without_changing_pair() {
        let root =
            std::env::temp_dir().join(format!("leantty-invalid-comment-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated =
            generate_key_pair("ed25519", &root_text, "deploy", "secret", "old").unwrap();
        let private_before = std::fs::read(&generated.private_path).unwrap();
        let public_before = std::fs::read(&generated.public_path).unwrap();

        assert!(change_key_comment(&generated.private_path, "wrong", "new").is_err());
        assert!(change_key_comment(&generated.private_path, "secret", "line\nbreak").is_err());
        assert!(change_key_comment(&generated.private_path, "secret", &"x".repeat(1024)).is_err());
        assert_eq!(
            std::fs::read(&generated.private_path).unwrap(),
            private_before
        );
        assert_eq!(
            std::fs::read(&generated.public_path).unwrap(),
            public_before
        );
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 2);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn public_replacement_failure_rolls_back_both_key_files() {
        let root = std::env::temp_dir().join(format!(
            "leantty-comment-commit-failure-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated = generate_key_pair("ed25519", &root_text, "deploy", "", "old").unwrap();
        let private_before = std::fs::read(&generated.private_path).unwrap();
        let public_before = std::fs::read(&generated.public_path).unwrap();

        let error = change_key_comment_with_replace(
            &generated.private_path,
            "",
            "new",
            |role, temporary, target| {
                if role == "public" {
                    Err("forced public replacement failure".to_string())
                } else {
                    std::fs::rename(temporary, target)
                        .map_err(|error| format!("replace failed: {}", error))
                }
            },
        )
        .unwrap_err();

        assert!(error.contains("forced public replacement failure"));
        assert_eq!(
            std::fs::read(&generated.private_path).unwrap(),
            private_before
        );
        assert_eq!(
            std::fs::read(&generated.public_path).unwrap(),
            public_before
        );
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 2);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn private_replacement_failure_leaves_both_key_files_unchanged() {
        let root = std::env::temp_dir().join(format!(
            "leantty-comment-private-commit-failure-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated = generate_key_pair("ed25519", &root_text, "deploy", "", "old").unwrap();
        let private_before = std::fs::read(&generated.private_path).unwrap();
        let public_before = std::fs::read(&generated.public_path).unwrap();

        let error =
            change_key_comment_with_replace(&generated.private_path, "", "new", |role, _, _| {
                Err(format!("forced {} replacement failure", role))
            })
            .unwrap_err();

        assert!(error.contains("forced private replacement failure"));
        assert_eq!(
            std::fs::read(&generated.private_path).unwrap(),
            private_before
        );
        assert_eq!(
            std::fs::read(&generated.public_path).unwrap(),
            public_before
        );
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 2);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn mismatched_public_key_is_rejected_without_writing() {
        let root = std::env::temp_dir().join(format!(
            "leantty-comment-mismatched-public-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated = generate_key_pair("ed25519", &root_text, "deploy", "", "old").unwrap();
        let other = generate_key_pair("ed25519", &root_text, "other", "", "other").unwrap();
        std::fs::copy(&other.public_path, &generated.public_path).unwrap();
        let private_before = std::fs::read(&generated.private_path).unwrap();
        let public_before = std::fs::read(&generated.public_path).unwrap();

        let error = change_key_comment(&generated.private_path, "", "new").unwrap_err();

        assert!(error.contains("identities do not match"));
        assert_eq!(
            std::fs::read(&generated.private_path).unwrap(),
            private_before
        );
        assert_eq!(
            std::fs::read(&generated.public_path).unwrap(),
            public_before
        );
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 4);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn unchanged_comment_is_a_byte_identical_no_op() {
        let root =
            std::env::temp_dir().join(format!("leantty-comment-no-op-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let root_text = root.to_string_lossy().to_string();
        let generated =
            generate_key_pair("ed25519", &root_text, "deploy", "secret", "same").unwrap();
        let private_before = std::fs::read(&generated.private_path).unwrap();
        let public_before = std::fs::read(&generated.public_path).unwrap();

        assert_eq!(
            change_key_comment(&generated.private_path, "secret", "same").unwrap(),
            "same"
        );
        assert_eq!(
            std::fs::read(&generated.private_path).unwrap(),
            private_before
        );
        assert_eq!(
            std::fs::read(&generated.public_path).unwrap(),
            public_before
        );
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 2);

        let _ = std::fs::remove_dir_all(&root);
    }
}
