use std::{fs, path::Path};

use lb_core::mantle::ops::channel::ChannelId;
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

/// Save checkpoint together with the channel ID it belongs to.
/// The channel ID is written to a sidecar file (<checkpoint>.channel).
pub fn save_checkpoint(path: &Path, checkpoint: &SequencerCheckpoint, channel_id: ChannelId) {
    let data = serde_json::to_vec(checkpoint).expect("failed to serialize checkpoint");
    fs::write(path, &data).expect("failed to write checkpoint");
    fs::write(sidecar_path(path), channel_id.as_ref())
        .expect("failed to write checkpoint channel sidecar");
}

/// Load a checkpoint only if it was saved for `channel_id`.
/// Automatically removes stale files if the channel has changed.
pub fn load_checkpoint(path: &Path, channel_id: ChannelId) -> Option<SequencerCheckpoint> {
    if !path.exists() {
        return None;
    }
    let sidecar = sidecar_path(path);
    if sidecar.exists() {
        let saved = fs::read(&sidecar).unwrap_or_default();
        if saved.as_slice() != channel_id.as_ref() {
            eprintln!("channel ID changed -- discarding stale sequencer checkpoint");
            let _ = fs::remove_file(path);
            let _ = fs::remove_file(&sidecar);
            return None;
        }
    } else {
        // No sidecar: checkpoint predates channel decoupling -- discard it
        eprintln!("checkpoint has no channel sidecar -- discarding stale checkpoint");
        let _ = fs::remove_file(path);
        return None;
    }
    let data = fs::read(path).expect("failed to read checkpoint");
    Some(serde_json::from_slice(&data).expect("failed to deserialize checkpoint"))
}

fn sidecar_path(checkpoint_path: &Path) -> std::path::PathBuf {
    let mut p = checkpoint_path.to_path_buf();
    let name = p
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    p.set_file_name(format!("{name}.channel"));
    p
}

/// Load an existing channel ID from `path`, or generate and save a fresh random one.
pub fn load_or_create_channel_id(path: &Path) -> ChannelId {
    if path.exists() {
        let bytes = fs::read(path).expect("failed to read channel ID file");
        assert_eq!(bytes.len(), 32, "channel ID file must be exactly 32 bytes");
        let arr: [u8; 32] = bytes.try_into().expect("length checked above");
        ChannelId::from(arr)
    } else {
        let mut bytes = [0u8; 32];
        rand::RngCore::fill_bytes(&mut rand::thread_rng(), &mut bytes);
        fs::write(path, bytes).expect("failed to write channel ID file");
        ChannelId::from(bytes)
    }
}

pub fn save_channel_id(path: &Path, channel_id: ChannelId) {
    fs::write(path, channel_id.as_ref()).expect("failed to write channel ID file");
}

pub const CHANNEL_PREFIX: &str = "logos:yolo:";

/// Derive a human-readable label from a channel ID:
/// - "logos:yolo:<name>"  ->  "<name>"
/// - other valid UTF-8 (no NUL padding)  ->  the string as-is
/// - anything else  ->  first 12 hex chars + "..."
pub fn channel_id_label(channel_id: ChannelId) -> String {
    let bytes = channel_id.as_ref();
    // Strip trailing NUL padding
    let end = bytes
        .iter()
        .rposition(|&b| b != 0)
        .map(|i| i + 1)
        .unwrap_or(0);
    let trimmed = &bytes[..end];
    if let Ok(s) = std::str::from_utf8(trimmed) {
        if s.chars().all(|c| !c.is_control()) {
            return s.strip_prefix(CHANNEL_PREFIX).unwrap_or(s).to_string();
        }
    }
    format!("{}...", &hex::encode(bytes)[..12])
}

/// Per-channel indexer progress: highest slot successfully scanned.
pub fn save_index_slot(data_dir: &Path, channel_id: ChannelId, slot: u64) {
    let path = index_slot_path(data_dir, channel_id);
    let _ = fs::write(path, slot.to_string());
}

pub fn load_index_slot(data_dir: &Path, channel_id: ChannelId) -> u64 {
    let path = index_slot_path(data_dir, channel_id);
    fs::read_to_string(path)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0)
}

pub fn clear_index_slot(data_dir: &Path, channel_id: ChannelId) {
    let _ = fs::remove_file(index_slot_path(data_dir, channel_id));
}

fn index_slot_path(data_dir: &Path, channel_id: ChannelId) -> std::path::PathBuf {
    data_dir.join(format!("index_{}.slot", hex::encode(channel_id.as_ref())))
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
