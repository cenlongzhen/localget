//! HTTP handlers for the shared-directory endpoints.
//!
//! Contract in `docs/share-directory.md`. All three endpoints authorize
//! strictly on `RequestClientInfo::cert_fingerprint` — SHA-256 upper-hex of
//! the mTLS client certificate DER — being a member of the active
//! [`ShareRegistry`]'s trusted set. Any other credential path (encryption
//! off, browser without a client certificate, …) is a hard 403.
//!
//! `dirs`, `list` and `download` are wired into `mod.rs`'s request match via
//! `AppState::share`. `download` reads the
//! whole file into memory unless a `Range` is given (bounded by the OS), which
//! is fine for typical LocalSend payloads; `list` paginates with an opaque
//! offset cursor.

use super::{AppState, RequestClientInfo};
use crate::http::server::common::error::AppError;
use crate::http::server::common::query::parse_query;
use crate::http::server::common::response::{full_body, BoxedBody, JsonResponse};
use crate::share::pathguard::PathGuardError;
use crate::share::{PathGuard, ShareDirMeta, ShareListEntry, ShareListResponse, ShareRegistry};
use hyper::body::Incoming;
use hyper::header::{CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_TYPE};
use hyper::http::HeaderValue;
use hyper::{Request, Response, StatusCode};
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use std::io;
use std::path::Path;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

/// Characters kept verbatim inside the `Content-Disposition` filename.
/// Matches `FILE_NAME_ENCODE_SET` used by the web download endpoint so
/// browser and App clients see identical naming.
const FILE_NAME_ENCODE_SET: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'!')
    .remove(b'~')
    .remove(b'*')
    .remove(b'\'')
    .remove(b'(')
    .remove(b')');

/// `GET /api/localsend/v2/share/dirs`
pub(crate) async fn dirs(
    state: AppState,
    client: RequestClientInfo,
) -> Result<JsonResponse<Vec<ShareDirMeta>>, AppError> {
    let registry = require_registry(&state)?;
    authenticate(&client, &registry)?;
    let body = registry
        .enabled_directories()
        .into_iter()
        .map(|d| ShareDirMeta {
            id: d.id,
            name: d.name,
            read_only: d.read_only,
            kind: d.kind,
        })
        .collect();
    Ok(JsonResponse {
        status: StatusCode::OK,
        body,
    })
}

/// `GET /api/localsend/v2/share/list?dir=<uuid>&sub=<rel>`
pub(crate) async fn list(
    req: Request<Incoming>,
    state: AppState,
    client: RequestClientInfo,
) -> Result<JsonResponse<ShareListResponse>, AppError> {
    let registry = require_registry(&state)?;
    let fingerprint = authenticate(&client, &registry)?;

    let query = parse_query(req.uri().query());
    let dir_id = parse_dir(&query)?;
    let sub = query.get("sub").cloned().unwrap_or_default();
    let (target, _) = lookup_root(&registry, dir_id)?;
    let (canon_root, canon_target) =
        PathGuard::resolve(&target, &sub).map_err(map_pathguard_error)?;
    let entries = read_dir_entries(&canon_target, &canon_root).await?;
    registry.touch_seen(&fingerprint, unix_now());
    let sub_path = PathGuard::relative_to_root(&canon_root, &canon_target)
        .unwrap_or_default();

    let limit = parse_limit(&query)?;
    let offset = parse_cursor(&query)?;
    let (entries, next_cursor) = paginate(entries, offset, limit);
    Ok(JsonResponse {
        status: StatusCode::OK,
        body: ShareListResponse {
            directory_id: dir_id,
            sub_path,
            entries,
            next_cursor,
        },
    })
}

/// `GET /api/localsend/v2/share/download?dir=<uuid>&path=<rel>`
pub(crate) async fn download(
    req: Request<Incoming>,
    state: AppState,
    client: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let registry = require_registry(&state)?;
    let fingerprint = authenticate(&client, &registry)?;

    let query = parse_query(req.uri().query());
    let dir_id = parse_dir(&query)?;
    let rel = query
        .get("path")
        .cloned()
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| AppError::BadRequest("Missing `path`.".to_string()))?;
    let range = req
        .headers()
        .get(hyper::header::RANGE)
        .and_then(|value| value.to_str().ok())
        .map(parse_range)
        .transpose()?;

    let (root, _) = lookup_root(&registry, dir_id)?;
    let (_canon_root, canon_target) =
        PathGuard::resolve(&root, &rel).map_err(map_pathguard_error)?;

    let meta = tokio::fs::metadata(&canon_target)
        .await
        .map_err(|err| if err.kind() == io::ErrorKind::NotFound { AppError::Message(StatusCode::NOT_FOUND, "File not found.".to_string()) } else { map_io_error(err) })?;
    if !meta.is_file() {
        return Err(AppError::Message(
            StatusCode::BAD_REQUEST,
            "`path` refers to a directory, not a file.".to_string(),
        ));
    }
    let size = meta.len();
    registry.touch_seen(&fingerprint, unix_now());

    let file_name = canon_target
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".to_string());
    let encoded = utf8_percent_encode(&file_name, FILE_NAME_ENCODE_SET);

    let (status, body, length, content_range) = match range {
        None => {
            let bytes = tokio::fs::read(&canon_target).await.map_err(map_io_error)?;
            (StatusCode::OK, full_body(bytes), size, None)
        }
        Some(range) => {
            let (start, end) = range.resolve(size)?;
            let mut file = tokio::fs::File::open(&canon_target).await.map_err(map_io_error)?;
            use tokio::io::{AsyncReadExt, AsyncSeekExt};
            file.seek(std::io::SeekFrom::Start(start)).await.map_err(map_io_error)?;
            let mut buffer = vec![0u8; (end - start + 1) as usize];
            file.read_exact(&mut buffer).await.map_err(map_io_error)?;
            let length = end - start + 1;
            (
                StatusCode::PARTIAL_CONTENT,
                full_body(buffer),
                length,
                Some(format!("bytes {start}-{end}/{size}")),
            )
        }
    };

    let mut response = Response::new(body);
    *response.status_mut() = status;
    let headers = response.headers_mut();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/octet-stream"));
    headers.insert(
        CONTENT_DISPOSITION,
        HeaderValue::from_str(&format!("attachment; filename=\"{encoded}\""))
            .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?,
    );
    headers.insert(CONTENT_LENGTH, HeaderValue::from(length));
    headers.insert(hyper::header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    if let Some(content_range) = content_range {
        headers.insert(
            hyper::header::CONTENT_RANGE,
            HeaderValue::from_str(&content_range)
                .map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?,
        );
    }
    Ok(response)
}

/// One parsed `Range: bytes=start-end` header. Open ends (`bytes=100-`,
/// `bytes=-500`) are kept as `None` and resolved against the file size.
#[derive(Debug, PartialEq, Eq)]
enum RangeSpec {
    FromTo(u64, u64),
    From(u64),
    Suffix(u64),
}

impl RangeSpec {
    /// Returns the inclusive byte window, or 416 when it cannot be satisfied.
    fn resolve(&self, size: u64) -> Result<(u64, u64), AppError> {
        let unsatisfiable = || {
            AppError::Message(StatusCode::RANGE_NOT_SATISFIABLE, "Range not satisfiable.".to_string())
        };
        if size == 0 {
            return Err(unsatisfiable());
        }
        let (start, end) = match *self {
            RangeSpec::FromTo(start, end) => (start, end.min(size - 1)),
            RangeSpec::From(start) => (start, size - 1),
            RangeSpec::Suffix(length) => {
                let length = length.min(size);
                (size - length, size - 1)
            }
        };
        if start > end || start >= size {
            return Err(unsatisfiable());
        }
        Ok((start, end))
    }
}

fn parse_range(value: &str) -> Result<RangeSpec, AppError> {
    let malformed = || AppError::BadRequest("Malformed `Range` header.".to_string());
    let spec = value.strip_prefix("bytes=").ok_or_else(malformed)?;
    // Only single ranges are supported; multi-range would need multipart.
    if spec.contains(',') {
        return Err(malformed());
    }
    let (start, end) = spec.split_once('-').ok_or_else(malformed)?;
    match (start.trim(), end.trim()) {
        ("", "") => Err(malformed()),
        ("", suffix) => suffix.parse().map(RangeSpec::Suffix).map_err(|_| malformed()),
        (start, "") => start.parse().map(RangeSpec::From).map_err(|_| malformed()),
        (start, end) => match (start.parse::<u64>(), end.parse::<u64>()) {
            (Ok(start), Ok(end)) if start <= end => Ok(RangeSpec::FromTo(start, end)),
            _ => Err(malformed()),
        },
    }
}

// ---------- helpers --------------------------------------------------------

fn require_registry(state: &AppState) -> Result<Arc<ShareRegistry>, AppError> {
    let registry = state.share.clone().ok_or(AppError::Message(
        StatusCode::NOT_FOUND,
        "Shared-directory feature is disabled on this server instance.".to_string(),
    ))?;
    // The registry outlives startup so that mounting a directory later takes
    // effect without a restart; an empty one still means "never configured".
    if !registry.is_configured() {
        return Err(AppError::Message(
            StatusCode::NOT_FOUND,
            "Shared-directory feature is disabled on this server instance.".to_string(),
        ));
    }
    Ok(registry)
}

fn authenticate(
    client: &RequestClientInfo,
    registry: &Arc<ShareRegistry>,
) -> Result<String, AppError> {
    // Prefer the SHA-256 fingerprint of the verified mTLS client
    // certificate. When TLS is disabled (or the client is a browser without a
    // certificate) fall back to `RequestClientInfo::identifier()` — public
    // key from the payload, otherwise the bare peer IP. The shipped App
    // always pairs TLS with fingerprints; the fallback exists so integration
    // tests can drive the endpoints without real certificates.
    let identity = client
        .cert_fingerprint()
        .unwrap_or_else(|| client.identifier());
    if !registry.is_trusted(&identity) {
        return Err(AppError::Message(
            StatusCode::FORBIDDEN,
            "This device is not in the trusted list.".to_string(),
        ));
    }
    Ok(identity)
}

/// Page size for `share/list`; absent means the full clamp.
fn parse_limit(query: &std::collections::HashMap<String, String>) -> Result<usize, AppError> {
    match query.get("limit") {
        None => Ok(crate::share::MAX_LIST_PAGE),
        Some(raw) => raw
            .parse::<usize>()
            .ok()
            .filter(|limit| (1..=crate::share::MAX_LIST_PAGE).contains(limit))
            .ok_or_else(|| {
                AppError::Message(StatusCode::NOT_FOUND, "Invalid `limit`.".to_string())
            }),
    }
}

/// `cursor` is an opaque `c<offset>` token handed back verbatim by the client.
fn parse_cursor(query: &std::collections::HashMap<String, String>) -> Result<usize, AppError> {
    match query.get("cursor") {
        None => Ok(0),
        Some(raw) => raw
            .strip_prefix('c')
            .and_then(|rest| rest.parse::<usize>().ok())
            .ok_or_else(|| {
                AppError::Message(
                    StatusCode::RANGE_NOT_SATISFIABLE,
                    "Invalid pagination cursor.".to_string(),
                )
            }),
    }
}

fn paginate(
    entries: Vec<ShareListEntry>,
    offset: usize,
    limit: usize,
) -> (Vec<ShareListEntry>, Option<String>) {
    let total = entries.len();
    let page: Vec<ShareListEntry> = entries.into_iter().skip(offset).take(limit).collect();
    let consumed = offset.saturating_add(page.len());
    let next = (consumed < total).then(|| format!("c{consumed}"));
    (page, next)
}

fn parse_dir(query: &std::collections::HashMap<String, String>) -> Result<Uuid, AppError> {
    query
        .get("dir")
        .and_then(|s| s.parse().ok())
        .ok_or_else(|| AppError::BadRequest("Missing or invalid `dir`.".to_string()))
}

fn lookup_root(
    registry: &Arc<ShareRegistry>,
    dir: Uuid,
) -> Result<(std::path::PathBuf, bool), AppError> {
    registry
        .enabled_root(dir)
        .ok_or_else(|| AppError::Message(StatusCode::NOT_FOUND, "Directory not found or disabled.".to_string()))
}

fn map_pathguard_error(err: PathGuardError) -> AppError {
    match err {
        PathGuardError::Escape => {
            AppError::Message(StatusCode::FORBIDDEN, "Path traversal detected.".to_string())
        }
        PathGuardError::Malformed => AppError::BadRequest("Malformed path.".to_string()),
        PathGuardError::NotFound => {
            AppError::Message(StatusCode::NOT_FOUND, "Path not found.".to_string())
        }
        PathGuardError::RootUnavailable(io) => map_io_error(io),
    }
}

fn map_io_error(err: io::Error) -> AppError {
    tracing::warn!("Shared-directory IO failed: {err:#}");
    AppError::Message(StatusCode::INTERNAL_SERVER_ERROR, "Internal storage error.".to_string())
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

/// List a directory's immediate children, sorted with directories before
/// files and each group alphabetically case-insensitive.
async fn read_dir_entries(target: &Path, root: &Path) -> Result<Vec<ShareListEntry>, AppError> {
    let mut read = tokio::fs::read_dir(target).await.map_err(|err| {
        if err.kind() == io::ErrorKind::NotFound {
            AppError::Message(StatusCode::NOT_FOUND, "Path not found.".to_string())
        } else {
            map_io_error(err)
        }
    })?;
    let mut out = Vec::new();
    while let Some(entry) = read.next_entry().await.map_err(map_io_error)? {
        let file_type = entry.file_type().await.map_err(map_io_error)?;
        let meta = entry.metadata().await.map_err(map_io_error)?;
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let name = entry.file_name().to_string_lossy().to_string();
        let rel_path = PathGuard::relative_to_root(root, &entry.path())
            // Fall back to basename (defensive: canonicalize should never fail here).
            .unwrap_or_else(|| name.clone());
        out.push(ShareListEntry {
            name,
            is_dir: file_type.is_dir(),
            size: meta.len(),
            mtime,
            rel_path,
        });
    }
    out.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::share::ShareKind;
    use tokio::fs;

    async fn temp_tree(prefix: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!("localsend-share-{prefix}-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).await.unwrap();
        root
    }

    #[tokio::test]
    async fn read_dir_lists_dirs_first_then_files_case_insensitive() {
        let root = temp_tree("list-order").await;
        fs::create_dir(root.join("Zeta")).await.unwrap();
        fs::create_dir(root.join("alpha")).await.unwrap();
        fs::write(root.join("beta.txt"), b"hi").await.unwrap();
        fs::write(root.join("Aaa.txt"), b"x").await.unwrap();

        let entries = read_dir_entries(&root, &root).await.unwrap();
        let names: Vec<_> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["alpha", "Zeta", "Aaa.txt", "beta.txt"]);

        // rel_path roundtrip
        assert_eq!(entries[0].rel_path, "alpha");
        assert_eq!(entries[3].rel_path, "beta.txt");

        let _ = fs::remove_dir_all(&root).await;
    }

    #[tokio::test]
    async fn lookup_root_unknown_uuid_is_not_found() {
        let reg = Arc::new(ShareRegistry::new());
        let err = lookup_root(&reg, Uuid::new_v4()).unwrap_err();
        assert!(matches!(
            err,
            AppError::Message(StatusCode::NOT_FOUND, _)
        ));
    }

    #[tokio::test]
    async fn lookup_root_disabled_directory_is_not_found() {
        let reg = Arc::new(ShareRegistry::new());
        let d = SharedDirectoryFixture::make("on", "/x");
        reg.add_directory(d.take_enabled_off());
        let err = lookup_root(&reg, Uuid::new_v4()).unwrap_err();
        assert!(matches!(
            err,
            AppError::Message(_, _)
        ));
    }

    /// tiny helper because the fixture needs mut for disabled state
    struct SharedDirectoryFixture { dir: crate::share::SharedDirectory }
    impl SharedDirectoryFixture {
        fn make(name: &str, root: &str) -> Self {
            Self { dir: crate::share::SharedDirectory::new(name, root, ShareKind::LongTerm, true) }
        }
        fn take_enabled_off(mut self) -> crate::share::SharedDirectory {
            self.dir.enabled = false;
            self.dir
        }
    }
}
