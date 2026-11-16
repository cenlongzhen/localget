//! Fingerprint validation and helpers.
//!
//! The wire format of a device fingerprint matches
//! `crate::crypto::cert::fingerprint_from_cert_der` — 64 uppercase hex
//! characters (32 raw bytes, SHA-256). [`TrustedDevices::parse_fingerprint`]
//! is the shared entry point used both when importing a peer from the
//! discovery list and when reading persisted state.

use super::TrustedDevice;
use thiserror::Error;

/// Errors returned by [`TrustedDevices::parse_fingerprint`].
#[derive(Debug, Error)]
pub enum TrustedDevicesError {
    #[error("fingerprint must be 64 hex characters (32 bytes), got {0}")]
    BadSize(usize),
    #[error("fingerprint contains non-hex characters")]
    NotHex,
    #[error("fingerprint alias must not be empty")]
    EmptyAlias,
}

/// Stateless namespace grouping fingerprint utilities.
pub struct TrustedDevices;

impl TrustedDevices {
    /// Validate and normalize a hex-string fingerprint into the canonical
    /// uppercase form used both on the wire and inside the registry.
    pub fn parse_fingerprint(raw: &str) -> Result<String, TrustedDevicesError> {
        let trimmed = raw.trim();
        if trimmed.len() != 64 {
            return Err(TrustedDevicesError::BadSize(trimmed.len()));
        }
        if !trimmed.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(TrustedDevicesError::NotHex);
        }
        Ok(trimmed.to_ascii_uppercase())
    }

    /// Build a [`TrustedDevice`] after validating the fingerprint and rejecting
    /// an empty alias.
    pub fn build(
        alias: impl Into<String>,
        raw_fingerprint: &str,
    ) -> Result<TrustedDevice, TrustedDevicesError> {
        let alias = alias.into();
        if alias.trim().is_empty() {
            return Err(TrustedDevicesError::EmptyAlias);
        }
        Ok(TrustedDevice::new(
            Self::parse_fingerprint(raw_fingerprint)?,
            alias,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uppercases_and_trims() {
        let raw = format!("  {}  ", "ab".repeat(32));
        let normalized = TrustedDevices::parse_fingerprint(&raw).unwrap();
        assert_eq!(normalized, "AB".repeat(32));
    }

    #[test]
    fn rejects_short_fingerprints() {
        assert!(matches!(
            TrustedDevices::parse_fingerprint("abc"),
            Err(TrustedDevicesError::BadSize(3))
        ));
    }

    #[test]
    fn rejects_non_hex() {
        let bad = "z".repeat(64);
        assert!(matches!(
            TrustedDevices::parse_fingerprint(&bad),
            Err(TrustedDevicesError::NotHex)
        ));
    }

    #[test]
    fn build_rejects_empty_alias() {
        let fp = "a".repeat(64);
        assert!(matches!(
            TrustedDevices::build("   ", &fp),
            Err(TrustedDevicesError::EmptyAlias)
        ));
    }

    #[test]
    fn build_accepts_valid_input() {
        let fp = "aa".repeat(32);
        let dev = TrustedDevices::build("Mom's laptop", &fp).unwrap();
        assert_eq!(dev.alias, "Mom's laptop");
        assert_eq!(dev.fingerprint, "AA".repeat(32));
    }
}
