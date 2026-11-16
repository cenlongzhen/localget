//! Shared-directory protocol module — data model, registry, and helpers.
//!
//! The protocol exposes three read-only HTTP endpoints under
//! `/api/localsend/v2/share/*` letting **trusted peers** browse and download
//! files that the local user explicitly published. Trust is decided by the
//! device fingerprint (`SHA-256` of the mTLS client certificate DER,
//! uppercase hex — same encoding as
//! [`crate::http::server::RequestClientInfo::cert_fingerprint`] returns).
//!
//! This module owns the data types and mutation surface; the HTTP handlers
//! live in `packages/core/src/http/server/share.rs`.
//!
//! Notable invariants:
//! - [`ShareKind::SessionOnly`] directories are dropped when the server stops;
//!   only [`ShareKind::LongTerm`] gets persisted by the app side.
//! - Trusted access implies *all* enabled directories. Per-directory whitelists
//!   are intentionally out of scope for v0.2.
//! - Every remote-supplied relative path must be resolved through
//!   [`PathGuard::resolve`] before touching the filesystem.

pub mod pathguard;
pub mod registry;
pub mod trusted;

pub use pathguard::PathGuard;
pub use registry::{ShareRegistry, ShareRegistryError};
pub use trusted::{TrustedDevices, TrustedDevicesError};

use serde::{Deserialize, Serialize};
use std::time::Duration;
use uuid::Uuid;

/// How many entries one `share/list` call may return at most (server clamp).
pub const MAX_LIST_PAGE: usize = 1000;

/// Interval coalescing `TrustedDevice::last_seen_at` refreshes; a peer that
/// browses repeatedly only triggers one write per window.
pub const LAST_SEEN_COALESCE: Duration = Duration::from_secs(15);

/// Lifecycle of a shared directory as chosen by the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ShareKind {
    /// Persisted across server restarts until the user explicitly removes it.
    #[default]
    LongTerm,
    /// Valid only while the current server instance is running; purged on
    /// shutdown via [`ShareRegistry::drop_session_only`].
    SessionOnly,
}

/// A directory the user has published for trusted peers to browse.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SharedDirectory {
    pub id: Uuid,
    pub name: String,
    /// Root as authored by the user; [`PathGuard`] canonicalizes it at
    /// request handling time.
    pub root: std::path::PathBuf,
    pub kind: ShareKind,
    pub read_only: bool,
    pub enabled: bool,
    pub added_at_unix_secs: u64,
}

impl SharedDirectory {
    pub fn new(
        name: impl Into<String>,
        root: impl Into<std::path::PathBuf>,
        kind: ShareKind,
        read_only: bool,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            root: root.into(),
            kind,
            read_only,
            enabled: true,
            added_at_unix_secs: unix_now(),
        }
    }
}

/// A peer that has been granted browse/download access to all *enabled*
/// directories of this device.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedDevice {
    /// Uppercase 64-char hex string. See [`TrustedDevices::parse_fingerprint`].
    pub fingerprint: String,
    pub alias: String,
    pub added_at_unix_secs: u64,
    pub last_seen_at_unix_secs: Option<u64>,
}

impl TrustedDevice {
    pub fn new(fingerprint: impl Into<String>, alias: impl Into<String>) -> Self {
        Self {
            fingerprint: fingerprint.into(),
            alias: alias.into(),
            added_at_unix_secs: unix_now(),
            last_seen_at_unix_secs: None,
        }
    }
}

/// One row in a `share/list` response.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareListEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// Unix seconds; `0` when the filesystem does not report one.
    pub mtime: i64,
    /// POSIX-style relative path from the shared directory root; verbatim
    /// input for a subsequent `share/download`.
    pub rel_path: String,
}

/// Body of the `share/list` endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareListResponse {
    pub directory_id: Uuid,
    pub sub_path: String,
    pub entries: Vec<ShareListEntry>,
    /// `Some` when more items may exist; the caller passes it back verbatim.
    pub next_cursor: Option<String>,
}

/// Item of the `share/dirs` endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareDirMeta {
    pub id: Uuid,
    pub name: String,
    pub read_only: bool,
    pub kind: ShareKind,
}

/// Snapshot handed across FRB / persisted by the Flutter app. Ordered by
/// insertion (`Vec`, not `HashMap`) so the UI keeps a stable view.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ShareSnapshot {
    pub directories: Vec<SharedDirectory>,
    pub trusted_devices: Vec<TrustedDevice>,
}

impl ShareSnapshot {
    pub fn load(registry: &ShareRegistry) -> Self {
        Self {
            directories: registry.all_directories(),
            trusted_devices: registry.all_trusted(),
        }
    }
}

/// Unix seconds now; used both as `added_at` seed and as argument to
/// [`ShareRegistry::touch_seen`].
pub fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_directory_new_assigns_unique_id_and_default_enabled() {
        let a = SharedDirectory::new("Movies", "/srv/movies", ShareKind::LongTerm, true);
        let b = SharedDirectory::new("Photos", "/srv/photos", ShareKind::SessionOnly, false);
        assert_ne!(a.id, b.id);
        assert!(a.enabled, "new directories start enabled");
        assert!(a.added_at_unix_secs > 0);
        assert_eq!(a.kind, ShareKind::LongTerm);
        assert_eq!(b.kind, ShareKind::SessionOnly);
    }

    #[test]
    fn trusted_device_new_leaves_last_seen_empty() {
        let dev = TrustedDevice::new("ABC123", "alias");
        assert_eq!(dev.last_seen_at_unix_secs, None);
        assert!(dev.added_at_unix_secs > 0);
    }

    #[test]
    fn share_kind_round_trips_camel_case() {
        let dir = SharedDirectory::new("x", "/tmp/x", ShareKind::SessionOnly, false);
        let json = serde_json::to_string(&dir).unwrap();
        assert!(json.contains("\"sessionOnly\""), "expected camelCase: {json}");
        let back: SharedDirectory = serde_json::from_str(&json).unwrap();
        assert_eq!(back.kind, ShareKind::SessionOnly);
    }

    #[test]
    fn unix_now_is_monotonic_positive() {
        let a = unix_now();
        std::thread::sleep(std::time::Duration::from_millis(1100));
        let b = unix_now();
        // coarse clock may tick the same second within 1.1s, so allow equality.
        assert!(a <= b + 1);
    }
}
