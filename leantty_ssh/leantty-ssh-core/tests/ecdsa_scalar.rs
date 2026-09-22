//! Public test scalars, never credentials. Keep these tests when removing the
//! dependency patch: they exercise the same re-export used by import and auth.
use russh::keys::ssh_key::{encoding::Decode, private::EcdsaPrivateKey};

fn decode<const N: usize>(scalar: &[u8]) -> Result<EcdsaPrivateKey<N>, String> {
    let mut wire = (scalar.len() as u32).to_be_bytes().to_vec();
    wire.extend_from_slice(scalar);
    EcdsaPrivateKey::decode(&mut wire.as_slice()).map_err(|error| error.to_string())
}

fn check_width<const N: usize>() {
    for length in [1, 30, 31, 32, N - 1, N] {
        let mut scalar = vec![0x42; length];
        scalar[0] = 0x40;
        let decoded = decode::<N>(&scalar).unwrap();
        assert_eq!(&decoded.as_slice()[..N - length], vec![0; N - length]);
        assert_eq!(&decoded.as_slice()[N - length..], scalar);
    }
    // A positive integer with its high bit set needs a sign byte.
    for length in [30, 31, N] {
        let mut scalar = vec![0x80; length + 1];
        scalar[0] = 0;
        let decoded = decode::<N>(&scalar).unwrap();
        assert_eq!(&decoded.as_slice()[N - length..], vec![0x80; length]);
    }
    assert!(decode::<N>(&[]).is_err());
    assert!(decode::<N>(&[0]).is_err());
    assert!(decode::<N>(&vec![0; N]).is_err());
    assert!(decode::<N>(&[0x80]).is_err());
    assert!(decode::<N>(&vec![0x80; N]).is_err());
    assert!(decode::<N>(&vec![1; N + 1]).is_err());
    assert!(decode::<N>(&vec![0; N + 2]).is_err());
    let truncated = [0, 0, 0, 31, 0x40];
    assert!(EcdsaPrivateKey::<N>::decode(&mut truncated.as_slice()).is_err());
}

#[test]
fn positive_scalar_encoding_boundaries() {
    check_width::<32>();
    check_width::<48>();
    check_width::<66>();
}

// An independently derived P-256 point for the public test scalar 2^246.
// Build the OpenSSH framing ourselves so ssh-key's fixed-width encoder cannot
// accidentally turn the regression input back into a 32-byte scalar.
fn short_openssh_key() -> String {
    fn string(out: &mut Vec<u8>, value: &[u8]) {
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value);
    }
    let point_hex = "04040bf36bdea2de0a4542cb5c539a534c68723275964aa5eb9c1a74b282375988e8b5b2b681dad75337d16867767ee3c5977abe33ae04f7f080d2a3d4793301cb";
    let point: Vec<u8> = (0..point_hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&point_hex[i..i + 2], 16).unwrap())
        .collect();
    let mut public = Vec::new();
    for field in [b"ecdsa-sha2-nistp256".as_slice(), b"nistp256", &point] {
        string(&mut public, field);
    }
    let mut private = vec![0, 0, 0, 42, 0, 0, 0, 42];
    private.extend_from_slice(&public);
    let mut scalar = [0u8; 31];
    scalar[0] = 0x40;
    string(&mut private, &scalar);
    string(&mut private, b"public-test-vector");
    for pad in 1..=8 - private.len() % 8 {
        private.push(pad as u8);
    }
    let mut wire = b"openssh-key-v1\0".to_vec();
    for field in [b"none".as_slice(), b"none", b""] {
        string(&mut wire, field);
    }
    wire.extend_from_slice(&1u32.to_be_bytes());
    string(&mut wire, &public);
    string(&mut wire, &private);
    let label = "OPENSSH PRIVATE KEY";
    let payload = data_encoding::BASE64.encode(&wire);
    format!("-----BEGIN {label}-----\n{payload}\n-----END {label}-----\n")
}

#[test]
fn short_scalar_import_signing_and_passphrase_lifecycle() {
    use leantty_ssh_core::keygen::{
        change_key_comment, change_private_key_passphrase, inspect_private_key, load_private_key,
    };
    use russh::keys::ssh_key::HashAlg;
    let root = std::env::temp_dir().join(format!("leantty-short-scalar-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("public-test-vector");
    let path_text = path.to_str().unwrap();
    std::fs::write(&path, short_openssh_key()).unwrap();
    let inspection = inspect_private_key(path_text).unwrap();
    std::fs::write(path.with_extension("pub"), &inspection.public_key).unwrap();
    assert_eq!(inspection.algorithm, "ecdsa-sha2-nistp256");
    let key = load_private_key(path_text, "").unwrap();
    let signature = key
        .sign("leantty-test", HashAlg::Sha256, b"auth challenge")
        .unwrap();
    key.public_key()
        .verify("leantty-test", b"auth challenge", &signature)
        .unwrap();
    change_private_key_passphrase(path_text, "", "test-only-passphrase").unwrap();
    assert!(load_private_key(path_text, "wrong").is_err());
    change_key_comment(path_text, "test-only-passphrase", "changed-test-comment").unwrap();
    let encrypted = inspect_private_key(path_text).unwrap();
    assert!(encrypted.encrypted);
    assert_eq!(encrypted.fingerprint, inspection.fingerprint);
    let reopened = load_private_key(path_text, "test-only-passphrase").unwrap();
    assert_eq!(
        reopened.public_key().key_data(),
        key.public_key().key_data()
    );
    change_private_key_passphrase(path_text, "test-only-passphrase", "").unwrap();
    assert_eq!(
        inspect_private_key(path_text).unwrap().fingerprint,
        inspection.fingerprint
    );
    std::fs::remove_dir_all(root).unwrap();
}
