# Rust Dependency License Inventory

Generated and reviewed on 2026-08-30 from `leantty_ssh/Cargo.lock` in a WSL
shell opened at the mounted checkout:

```bash
cargo metadata --locked --offline \
  --filter-platform aarch64-unknown-linux-ohos \
  --format-version 1
```

The target-filtered graph contains 181 registry packages and one external Git
package, `mosh-client 0.0.0`. Every package reports a license expression or
license file. Package build dependencies are included conservatively even when
they are not linked into the final shared library.

## Apache-2.0

`russh 0.62.5`, `russh-cryptovec 0.62.0`, `russh-sftp 2.4.0`,
`russh-util 0.52.0`, `prost 0.14.4`, `prost-derive 0.14.4`

## MIT

`bytes 1.12.1`, `cfg_aliases 0.2.1`, `convert_case 0.11.0`,
`dashmap 6.2.1`,
`data-encoding 2.11.0`, `generic-array 0.14.9`, `generic-array 1.4.4`,
`mio 1.2.2`, `napi-build-ohos 1.2.0`,
`napi-derive-backend-ohos 1.2.0`, `napi-derive-ohos 1.2.0`,
`napi-ohos 1.2.0`, `napi-sys-ohos 1.2.0`, `nix 0.31.3`,
`slab 0.4.12`, `tokio 1.53.1`, `tokio-macros 2.7.0`,
`tokio-util 0.7.19`, `vt100 0.16.2`

## MIT OR Apache-2.0

`aead 0.6.1`, `aes 0.9.1`, `aes-gcm 0.11.0`, `anyhow 1.0.104`,
`argon2 0.6.0-rc.8`, `arrayvec 0.7.8`,
`autocfg 1.5.1`, `base16ct 1.0.0`, `base64ct 1.8.3`,
`base64 0.23.1`,
`bcrypt-pbkdf 0.11.0`, `bitflags 2.13.1`, `blake2 0.11.0-rc.6`,
`block-buffer 0.12.1`, `block-padding 0.4.2`, `blowfish 0.10.0`,
`cbc 0.2.1`, `cc 1.2.67`, `cfg-if 1.0.4`, `chacha20 0.10.1`,
`chrono 0.4.45`, `cipher 0.5.2`, `cmov 0.5.4`, `const-oid 0.10.2`,
`cpubits 0.1.1`,
`cpufeatures 0.3.0`, `crypto-bigint 0.7.5`, `crypto-common 0.2.2`,
`crypto-primes 0.7.2`,
`crossbeam-utils 0.8.22`, `ctor 1.0.8`, `ctr 0.10.1`, `ctutils 0.4.2`,
`dbl 0.5.0`, `delegate 0.13.5`,
`der 0.8.1`, `des 0.9.0`, `digest 0.11.3`, `ecdsa 0.17.0`,
`ed25519 3.0.0`, `either 1.18.0`, `elliptic-curve 0.14.1`, `enum_dispatch 0.3.13`,
`errno 0.3.14`,
`ff 0.14.0`, `find-msvc-tools 0.1.9`, `futures 0.3.32`,
`futures-channel 0.3.32`, `futures-core 0.3.32`,
`futures-executor 0.3.32`, `futures-io 0.3.32`,
`futures-macro 0.3.32`, `futures-sink 0.3.32`,
`futures-task 0.3.32`, `futures-util 0.3.32`, `getrandom 0.2.17`,
`getrandom 0.4.3`, `ghash 0.6.0`, `group 0.14.0`, `hex 0.4.3`,
`hex-literal 1.1.0`, `hkdf 0.13.0`, `hmac 0.13.0`,
`hashbrown 0.14.5`, `hybrid-array 0.4.13`, `iana-time-zone 0.1.65`,
`inout 0.2.2`, `itertools 0.14.0`, `itoa 1.0.18`,
`internal-russh-num-bigint 0.5.0`, `keccak 0.2.0`, `kem 0.3.0`,
`libc 0.2.186`, `lock_api 0.4.14`, `log 0.4.33`, `md5 0.8.1`,
`ml-kem 0.3.2`,
`module-lattice 0.2.3`, `mosh-client 0.0.0`, `nohash-hasher 0.2.0`, `num-bigint 0.4.8`,
`num-integer 0.1.46`, `num-traits 0.2.19`, `once_cell 1.21.4`,
`parking_lot_core 0.9.12`,
`p256 0.14.0`, `p384 0.14.0`, `p521 0.14.0`,
`password-hash 0.6.1`, `pbkdf2 0.13.0`, `pem-rfc7468 1.0.0`,
`ocb3 0.2.0`, `phc 0.6.1`, `pin-project-lite 0.2.17`, `pkcs1 0.8.0-rc.4`, `pkcs5 0.8.1`,
`pkcs8 0.11.0`, `poly1305 0.9.1`, `polyval 0.7.2`,
`primefield 0.14.0`, `primeorder 0.14.0`, `proc-macro2 1.0.106`,
`quote 1.0.46`, `rand 0.10.2`, `rand_core 0.10.1`, `rsa 0.10.0-rc.18`,
`rfc6979 0.6.0`, `rustc_version 0.4.1`, `rustc-hash 2.1.3`,
`rustversion 1.0.23`, `salsa20 0.11.0`, `scrypt 0.12.0`,
`scopeguard 1.2.0`, `sec1 0.8.1`, `semver 1.0.28`, `serde 1.0.229`,
`serde_bytes 0.11.19`, `serde_core 1.0.229`, `serde_derive 1.0.229`,
`serdect 0.4.3`, `sha1 0.11.0`,
`sha2 0.11.0`, `sha3 0.11.0`, `sha3 0.12.0`, `shlex 2.0.1`,
`signal-hook-registry 1.4.8`, `signature 3.0.0`, `smallvec 1.15.2`,
`sponge-cursor 0.1.0`,
`socket2 0.6.4`, `spki 0.8.0`, `ssh-cipher 0.3.0`,
`ssh-encoding 0.3.0`, `ssh-key 0.7.0-rc.11`, `syn 2.0.118`,
`syn 3.0.3`, `thiserror 2.0.20`, `thiserror-impl 2.0.20`, `typenum 1.20.1`,
`unicode-segmentation 1.13.3`, `unicode-width 0.2.2`, `universal-hash 0.6.1`,
`version_check 0.9.5`, `vte 0.15.0`, `wnaf 0.14.0`, `zeroize 1.9.0`

The inventory normalizes the equivalent expressions `Apache-2.0 OR MIT` and
`MIT/Apache-2.0` into this group.

## 0BSD OR MIT OR Apache-2.0

`adler2 2.0.1`

## MIT OR Zlib OR Apache-2.0

`miniz_oxide 0.9.1`

## BSD-3-Clause

`curve25519-dalek 5.0.0`, `ed25519-dalek 3.0.0`,
`subtle 2.6.1`

## ISC

`libloading 0.9.0`, `untrusted 0.9.0`

## Apache-2.0 AND ISC

`ring 0.17.14`

## Unlicense OR MIT

`byteorder 1.5.0`, `memchr 2.8.3`

## (MIT OR Apache-2.0) AND Unicode-3.0

`unicode-ident 1.0.24`

`mosh-client` is resolved from `https://github.com/wandcs/mosh-client-rs.git` at
commit `94f13225aba535c6645a9179e0ce9f00b156629e`. Cargo uses the complete `rev`
instead of a movable branch; see
[`mosh-client-rs` integration issues](design/mosh-client-rs-integration-issues.md).

The release build copies the applicable license and notice files from the
locked crate source archives into package-specific directories and generates
`licenses/rust/packages.json` as the package-to-file index. It also includes
LeanTTY's Apache-2.0 text and the consolidated third-party notice.
