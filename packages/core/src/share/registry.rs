//! In-memory registry of shared directories and trusted peers.
//!
//! [`ShareRegistry`] is cheap to clone into the HTTP server via
//! `Arc<ShareRegistry>`. Mutations take a write lock for the shortest time
//! possible; queries take read locks. All methods are safe to call from
//! concurrent tokio tasks because the lock critical sections never span
//! awaits.

use super::{ShareKind, SharedDirectory, TrustedDevice};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::RwLock;
use thiserror::Error;
use uuid::Uuid;

/// Errors raised by mutating operations on [`ShareRegistry`].
#[derive(Debug, Error)]
pub enum ShareRegistryError {
    #[error("shared directory not found: {0}")]
    DirectoryNotFound(Uuid),

    #[error("trusted device not found: {0}")]
    DeviceNotFound(String),
}

/// Runtime configuration for the shared-directory endpoints. Cloneable via
/// `Arc<ShareRegistry>`; the interior locks serialize mutations so callers do
/// not need to hold an outer lock.
#[derive(Debug, Default)]
pub struct ShareRegistry {
    directories: RwLock<HashMap<Uuid, SharedDirectory>>,
    trusted: RwLock<HashMap<String, TrustedDevice>>,
}

impl ShareRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Populate a fresh registry from a persisted / synced view.
    pub fn load(dirs: Vec<SharedDirectory>, trusted: Vec<TrustedDevice>) -> Self {
        let r = Self::default();
        for d in dirs {
            r.add_directory(d);
        }
        for t in trusted {
            r.trust_device(t);
        }
        r
    }

    /// Snapshot for FRB / persistence; ordered by `added_at_unix_secs` for a
    /// stable UI view.
    pub fn snapshot(&self) -> super::ShareSnapshot {
        let mut dirs = self.all_directories();
        dirs.sort_by_key(|d| d.added_at_unix_secs);
        let mut trusted = self.all_trusted();
        trusted.sort_by_key(|t| t.added_at_unix_secs);
        super::ShareSnapshot {
            directories: dirs,
            trusted_devices: trusted,
        }
    }

    // ---- Directories ------------------------------------------------------

    /// Inserts (or replaces by id) and returns the id.
    pub fn add_directory(&self, dir: SharedDirectory) -> Uuid {
        let id = dir.id;
        self.directories.write().unwrap().insert(id, dir);
        id
    }

    /// Removes the directory; returns [`ShareRegistryError::DirectoryNotFound`]
    /// if the id was unknown.
    pub fn remove_directory(&self, id: Uuid) -> Result<SharedDirectory, ShareRegistryError> {
        self.directories
            .write()
            .unwrap()
            .remove(&id)
            .ok_or(ShareRegistryError::DirectoryNotFound(id))
    }

    /// Toggle the enabled bit of a directory.
    pub fn set_directory_enabled(&self, id: Uuid, enabled: bool) -> Result<(), ShareRegistryError> {
        let mut dirs = self.directories.write().unwrap();
        let entry = dirs
            .get_mut(&id)
            .ok_or(ShareRegistryError::DirectoryNotFound(id))?;
        entry.enabled = enabled;
        Ok(())
    }

    /// Enabled directories, sorted by insertion time.
    pub fn enabled_directories(&self) -> Vec<SharedDirectory> {
        self.directories
            .read()
            .unwrap()
            .values()
            .filter(|d| d.enabled)
            .cloned()
            .collect()
    }

    pub fn all_directories(&self) -> Vec<SharedDirectory> {
        self.directories.read().unwrap().values().cloned().collect()
    }

    /// Convenience lookup used by every HTTP handler: fetch a directory's
    /// on-disk root and read-only flag **if it exists and is enabled**.
    pub fn enabled_root(&self, id: Uuid) -> Option<(PathBuf, bool)> {
        let dirs = self.directories.read().unwrap();
        dirs.get(&id)
            .filter(|d| d.enabled)
            .map(|d| (d.root.clone(), d.read_only))
    }

    /// Ids of directories marked [`ShareKind::SessionOnly`].
    pub fn session_only_ids(&self) -> Vec<Uuid> {
        self.directories
            .read()
            .unwrap()
            .iter()
            .filter(|(_, d)| matches!(d.kind, ShareKind::SessionOnly))
            .map(|(id, _)| *id)
            .collect()
    }

    /// Purge every [`ShareKind::SessionOnly`] directory. Called from the server
    /// shutdown path so a re-launch starts with a clean list.
    pub fn drop_session_only(&self) {
        let doomed = self.session_only_ids();
        let mut dirs = self.directories.write().unwrap();
        for id in doomed {
            dirs.remove(&id);
        }
    }

    /// Atomically replace the whole contents with `dirs` and `trusted`.
    ///
    /// Used by the FRB bridge, where the Flutter app pushes a fresh
    /// snapshot whenever the local view mutates while preserving the same
    /// `Arc<ShareRegistry>` handle the HTTP server already holds — avoiding
    /// any server restart.
    pub fn replace_all(&self, dirs: Vec<SharedDirectory>, trusted: Vec<TrustedDevice>) {
        let mut dir_sl = self.directories.write().unwrap();
        dir_sl.clear();
        for d in dirs {
            dir_sl.insert(d.id, d);
        }
        drop(dir_sl);

        let mut trusted_sl = self.trusted.write().unwrap();
        trusted_sl.clear();
        for t in trusted {
            trusted_sl.insert(t.fingerprint.clone(), t);
        }
    }

    // ---- Trust ------------------------------------------------------------

    /// Insert or replace by fingerprint.
    pub fn trust_device(&self, device: TrustedDevice) {
        self.trusted
            .write()
            .unwrap()
            .insert(device.fingerprint.clone(), device);
    }

    pub fn revoke_device(&self, fingerprint: &str) -> Result<TrustedDevice, ShareRegistryError> {
        self.trusted
            .write()
            .unwrap()
            .remove(fingerprint)
            .ok_or_else(|| ShareRegistryError::DeviceNotFound(fingerprint.to_string()))
    }

    #[inline]
    pub fn is_trusted(&self, fingerprint: &str) -> bool {
        self.trusted.read().unwrap().contains_key(fingerprint)
    }

    /// Whether the user configured anything at all. An empty registry means the
    /// feature was never used, so `/share/*` answers `404` and peers do not
    /// advertise this device.
    pub fn is_configured(&self) -> bool {
        !self.directories.read().unwrap().is_empty()
            || !self.trusted.read().unwrap().is_empty()
    }

    pub fn all_trusted(&self) -> Vec<TrustedDevice> {
        self.trusted.read().unwrap().values().cloned().collect()
    }

    /// Update `last_seen_at_unix_secs` on a trusted device when the fingerprint
    /// makes a successful list/download call. Returns `true` when the timestamp
    /// actually moved (callers can coalesce writes at [`super::LAST_SEEN_COALESCE`]
    /// granularity to reduce lock churn).
    pub fn touch_seen(&self, fingerprint: &str, now_unix_secs: u64) -> bool {
        let mut trusted = self.trusted.write().unwrap();
        match trusted.get_mut(fingerprint) {
            Some(dev) => {
                let needs_update = match dev.last_seen_at_unix_secs {
                    None => true,
                    Some(prev) => now_unix_secs.saturating_sub(prev)
                        >= super::LAST_SEEN_COALESCE.as_secs(),
                };
                if needs_update {
                    dev.last_seen_at_unix_secs = Some(now_unix_secs);
                }
                needs_update
            }
            None => false,
        }
    }

    // ---- Aggregate view helpers for HTTP handlers -------------------------

    pub fn dir_ids_visible_to(&self, fingerprint: &str) -> Vec<Uuid> {
        if !self.is_trusted(fingerprint) {
            return Vec::new();
        }
        self.enabled_directories().into_iter().map(|d| d.id).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_then_remove_roundtrip() {
        let reg = ShareRegistry::new();
        let dir = SharedDirectory::new("Movies", "/mnt/movies", ShareKind::LongTerm, true);
        let id = dir.id;
        reg.add_directory(dir);
        assert_eq!(reg.all_directories().len(), 1);

        let removed = reg.remove_directory(id).unwrap();
        assert_eq!(removed.name, "Movies");
        assert!(reg.all_directories().is_empty());
        assert!(matches!(
            reg.remove_directory(id),
            Err(ShareRegistryError::DirectoryNotFound(_))
        ));
    }

    #[test]
    fn trust_and_revoke() {
        let reg = ShareRegistry::new();
        reg.trust_device(TrustedDevice::new("AAAA", "Alias"));
        assert!(reg.is_trusted("AAAA"));
        let revoked = reg.revoke_device("AAAA").unwrap();
        assert_eq!(revoked.alias, "Alias");
        assert!(!reg.is_trusted("AAAA"));
        assert!(matches!(
            reg.revoke_device("AAAA"),
            Err(ShareRegistryError::DeviceNotFound(_))
        ));
    }

    #[test]
    fn session_only_purged() {
        let reg = ShareRegistry::new();
        reg.add_directory(SharedDirectory::new(
            "long",
            "/x",
            ShareKind::LongTerm,
            false,
        ));
        reg.add_directory(SharedDirectory::new(
            "short",
            "/y",
            ShareKind::SessionOnly,
            false,
        ));
        reg.drop_session_only();
        let remaining = reg.all_directories();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].name, "long");
    }

    #[test]
    fn enabled_filter_hides_disabled() {
        let reg = ShareRegistry::new();
        let long = SharedDirectory::new("on", "/on", ShareKind::LongTerm, false);
        let off = SharedDirectory::new("off", "/off", ShareKind::LongTerm, false);
        let off_id = off.id;
        reg.add_directory(long);
        reg.add_directory(off);
        reg.set_directory_enabled(off_id, false).unwrap();

        let visible = reg.enabled_directories();
        assert_eq!(visible.len(), 1);
        assert_eq!(visible[0].name, "on");
        assert!(reg.enabled_root(off_id).is_none());
    }

    #[test]
    fn touch_seen_respects_coalesce() {
        let reg = ShareRegistry::new();
        reg.trust_device(TrustedDevice::new("AAAA", "Alias"));
        let t0 = super::super::unix_now();
        assert!(reg.touch_seen("AAAA", t0), "first touch must persist");
        // Within the same seconds window -> no-op.
        assert!(!reg.touch_seen("AAAA", t0), "same-window touch coalesces");
        // Outside LAST_SEEN_COALESCE window -> move.
        assert!(reg.touch_seen("AAAA", t0 + 60), "past window persists");
    }

    #[test]
    fn snapshot_is_sorted_by_added_at() {
        let reg = ShareRegistry::new();
        let mut a = SharedDirectory::new("a", "/a", ShareKind::LongTerm, false);
        a.added_at_unix_secs = 100;
        let mut b = SharedDirectory::new("b", "/b", ShareKind::LongTerm, false);
        b.added_at_unix_secs = 50;
        reg.add_directory(a);
        reg.add_directory(b);
        let snap = reg.snapshot();
        assert_eq!(snap.directories[0].name, "b");
        assert_eq!(snap.directories[1].name, "a");
    }

    #[test]
    fn load_rebuilds_state() {
        let mut d = SharedDirectory::new("x", "/x", ShareKind::SessionOnly, false);
        d.enabled = false;
        let reg = ShareRegistry::load(
            vec![d.clone()],
            vec![TrustedDevice::new("F", "friend")],
        );
        assert_eq!(reg.all_directories().len(), 1);
        assert_eq!(reg.enabled_directories().len(), 0);
        assert!(reg.is_trusted("F"));
    }

    #[test]
    fn replace_all_swaps_both_maps() {
        let reg = ShareRegistry::new();
        reg.add_directory(SharedDirectory::new("old", "/old", ShareKind::LongTerm, false));
        reg.trust_device(TrustedDevice::new("OLD", "Old peer"));

        reg.replace_all(
            vec![SharedDirectory::new("new", "/new", ShareKind::SessionOnly, false)],
            vec![TrustedDevice::new("NEW", "New peer")],
        );

        assert!(!reg.is_trusted("OLD"));
        assert!(reg.is_trusted("NEW"));
        let dirs = reg.all_directories();
        assert_eq!(dirs.len(), 1);
        assert_eq!(dirs[0].name, "new");
    }

    #[test]
    fn replace_all_clears_both_when_empty() {
        let reg = ShareRegistry::new();
        reg.add_directory(SharedDirectory::new("a", "/a", ShareKind::LongTerm, false));
        reg.trust_device(TrustedDevice::new("AA", "aa"));
        reg.replace_all(vec![], vec![]);
        assert!(reg.all_directories().is_empty());
        assert!(reg.all_trusted().is_empty());
    }
}
