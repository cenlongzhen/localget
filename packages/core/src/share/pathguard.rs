//! Path-resolution guard used by every shared-directory request handler.
//!
//! Remote callers supply **relative** paths (e.g. `sub=2024/dune.mkv`) that
//! must resolve to filesystem locations guaranteed to lie under the
//! [`super::SharedDirectory::root`] they were authorized for. This module
//! centralizes the checks so mistakes at one call site can't leak elsewhere:
//!
//! 1. Reject the input outright when it contains NUL, absolute prefixes
//!    (`/…`, `\…`, `C:\…`, `\\server\…`), or any `..` component.
//! 2. Assemble the remaining segments with the target platform's separator
//!    and join under the root.
//! 3. Canonicalize both sides so a symlink cannot hop out of the tree, and
//!    assert the canonicalized target starts with the canonicalized root.
//!
//! Any failure returns [`PathGuardError::Escape`] or
//! [`PathGuardError::Malformed`]; the HTTP layer maps either to `400`/`403`.

use std::io;
use std::path::{Component, Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum PathGuardError {
    /// The path attempted to leave the shared root (`..`, symlink escape, …).
    #[error("requested path escapes the shared directory")]
    Escape,
    /// The path was syntactically invalid (absolute, NUL, malformed segment).
    #[error("requested path is malformed")]
    Malformed,
    /// The shared root itself could not be canonicalized (probably missing).
    #[error("shared directory root could not be canonicalized")]
    RootUnavailable(#[from] io::Error),
    /// The requested target does not exist under the root.
    #[error("requested path not found under the shared directory")]
    NotFound,
}

pub struct PathGuard;

impl PathGuard {
    /// Interpret the client-supplied relative path against `root` and, on
    /// success, return `(canonical_root, canonical_target)`.
    ///
    /// The relative path may be empty (`""`) to mean "the root itself".
    pub fn resolve(root: &Path, client_path: &str) -> Result<(PathBuf, PathBuf), PathGuardError> {
        // 1. Reject obviously bad shapes *before* touching the FS.
        if client_path.contains('\0') {
            return Err(PathGuardError::Malformed);
        }
        let trimmed = client_path.trim();
        if Self::looks_absolute(trimmed) {
            return Err(PathGuardError::Malformed);
        }

        // 2. Split on both separators, refuse `..` outright, ignore `.`/empty.
        let mut sanitized = String::new();
        for component in client_path.split(['/', '\\']) {
            match component {
                "" | "." => continue,
                ".." => return Err(PathGuardError::Escape),
                other => {
                    if !sanitized.is_empty() {
                        sanitized.push(std::path::MAIN_SEPARATOR);
                    }
                    sanitized.push_str(other);
                }
            }
        }

        // 3. Join under root.
        let joined = if sanitized.is_empty() {
            root.to_path_buf()
        } else {
            root.join(sanitized)
        };

        // 4. Canonicalize both sides and re-check.
        let canonical_root = root.canonicalize()?;
        let canonical_target = match joined.canonicalize() {
            Ok(p) => p,
            Err(err) if err.kind() == io::ErrorKind::NotFound => {
                return Err(PathGuardError::NotFound)
            }
            Err(_) => return Err(PathGuardError::Escape),
        };
        if !canonical_target.starts_with(&canonical_root) {
            return Err(PathGuardError::Escape);
        }
        Ok((canonical_root, canonical_target))
    }

    /// Encode a canonical target back into the client-side relative form
    /// (forward-slash separated for cross-platform determinism). Returns
    /// `None` when the target is not under the root — treat that as a caller
    /// bug or an escape attempt.
    pub fn relative_to_root(canonical_root: &Path, canonical_target: &Path) -> Option<String> {
        let rel = canonical_target.strip_prefix(canonical_root).ok()?;
        let mut buf = String::new();
        for (i, component) in rel.components().enumerate() {
            match component {
                Component::Normal(s) => {
                    if i > 0 {
                        buf.push('/');
                    }
                    buf.push_str(&s.to_string_lossy());
                }
                _ => return None,
            }
        }
        Some(buf)
    }

    fn looks_absolute(path: &str) -> bool {
        if path.is_empty() {
            return false;
        }
        let bytes = path.as_bytes();
        if bytes[0] == b'/' || bytes[0] == b'\\' {
            return true;
        }
        // Windows drive letters (`C:\…`, `c:/…`) and UNC (`\\server\share`).
        #[cfg(windows)]
        {
            if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
                return true;
            }
        }
        // Even on non-Windows we treat the shape as suspicious: the caller
        // almost certainly meant their own filesystem namespace.
        if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
            return true;
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_absolute_posix_paths() {
        let err = PathGuard::resolve(Path::new("/tmp/shared"), "/etc/passwd").unwrap_err();
        assert!(matches!(err, PathGuardError::Malformed));
    }

    #[test]
    fn rejects_absolute_windows_drive() {
        let err = PathGuard::resolve(Path::new("C:\\shared"), r"C:\Windows\win.ini").unwrap_err();
        assert!(matches!(err, PathGuardError::Malformed));
    }

    #[test]
    fn rejects_uplevel_references() {
        let err = PathGuard::resolve(Path::new("/tmp/shared"), "../etc/passwd").unwrap_err();
        assert!(matches!(err, PathGuardError::Escape));
    }

    #[test]
    fn rejects_nul_byte() {
        let err = PathGuard::resolve(Path::new("/tmp/shared"), "hello\0world").unwrap_err();
        assert!(matches!(err, PathGuardError::Malformed));
    }

    #[test]
    fn relative_to_root_round_trips_forward_slashes() {
        let root = Path::new("/srv/media");
        let target = Path::new("/srv/media/2024/dune.mkv");
        let rel = PathGuard::relative_to_root(root, target).unwrap();
        assert_eq!(rel, "2024/dune.mkv");
    }

    #[test]
    fn relative_to_root_returns_none_when_outside() {
        assert!(PathGuard::relative_to_root(
            Path::new("/srv/media"),
            Path::new("/etc/passwd")
        )
        .is_none());
    }

    #[test]
    fn relative_to_root_handles_root_itself() {
        let root = Path::new("/srv/media");
        let rel = PathGuard::relative_to_root(root, root).unwrap();
        assert_eq!(rel, "");
    }
}
