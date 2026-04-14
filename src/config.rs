use std::{fs, path::Path};

use lb_key_management_system_keys::keys::{ED25519_SECRET_KEY_SIZE, Ed25519Key};
use lb_zone_sdk::sequencer::SequencerCheckpoint;

pub fn load_or_create_key(path: &Path) -> Ed25519Key {
    if path.exists() {
        let bytes = fs::read(path).expect("failed to read key file");
        assert_eq!(
            bytes.len(),
            ED25519_SECRET_KEY_SIZE,
            "key file has wrong length"
        );
        let arr: [u8; ED25519_SECRET_KEY_SIZE] = bytes.try_into().expect("length checked above");
        Ed25519Key::from_bytes(&arr)
    } else {
        let mut bytes = [0u8; ED25519_SECRET_KEY_SIZE];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut bytes);
        fs::write(path, bytes).expect("failed to write key file");
        Ed25519Key::from_bytes(&bytes)
    }
}

pub fn save_checkpoint(path: &Path, checkpoint: &SequencerCheckpoint) {
    let data = serde_json::to_vec(checkpoint).expect("failed to serialize checkpoint");
    fs::write(path, data).expect("failed to write checkpoint");
}

pub fn load_checkpoint(path: &Path) -> Option<SequencerCheckpoint> {
    if !path.exists() {
        return None;
    }
    let data = fs::read(path).expect("failed to read checkpoint");
    Some(serde_json::from_slice(&data).expect("failed to deserialize checkpoint"))
}

/// Save subscribed channel IDs as a JSON list of hex strings.
pub fn save_subscriptions(path: &Path, channel_ids: &[String]) {
    let data = serde_json::to_vec(channel_ids).expect("failed to serialize subscriptions");
    fs::write(path, data).expect("failed to write subscriptions");
}

/// Load subscribed channel IDs as hex strings.
pub fn load_subscriptions(path: &Path) -> Vec<String> {
    if !path.exists() {
        return Vec::new();
    }
    let data = fs::read(path).expect("failed to read subscriptions");
    serde_json::from_slice(&data).unwrap_or_default()
}
