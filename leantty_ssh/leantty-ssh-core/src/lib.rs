pub mod authentication;
pub mod keygen;
pub mod known_hosts;

pub enum AuthMethod {
    Password(String),
    PrivateKeyPassphrase(String),
    KeyboardInteractiveResponses {
        round_id: u32,
        responses: Vec<String>,
    },
}

impl Drop for AuthMethod {
    fn drop(&mut self) {
        use zeroize::Zeroize;

        match self {
            Self::Password(password) | Self::PrivateKeyPassphrase(password) => password.zeroize(),
            Self::KeyboardInteractiveResponses { responses, .. } => {
                responses.iter_mut().for_each(Zeroize::zeroize);
                responses.clear();
            }
        }
    }
}
