use crate::api::cancel::RsCancellationToken;
use crate::api::stream;
use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
pub use localsend::http::client::{ClientError, LsHttpClientVersion};
pub use localsend::http::dto::{
    PrepareUploadRequestDto, PrepareUploadResponseDto, PrepareUploadResult,
    RegisterDto, RegisterResponseDto,
};
use localsend::model::discovery::ProtocolType;
use localsend::util::error::ErrorChain;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

pub struct RsHttpClient {
    inner: localsend::http::client::LsHttpClient,
}

/// Creates an HTTP client.
///
/// `expected_fingerprint` pins the peer to the certificate with that SHA-256
/// fingerprint (uppercase hex). It is enforced during the TLS handshake, so a
/// peer that does not present the expected certificate never receives the
/// request. Pass `None` only for discovery, where the peer is not known yet.
#[frb(sync)]
pub fn create_client(
    private_key: String,
    cert: String,
    version: LsHttpClientVersion,
    expected_fingerprint: Option<String>,
    timeout_ms: Option<u32>,
) -> Result<RsHttpClient, RsHttpClientError> {
    let inner = localsend::http::client::LsHttpClient::new(
        &private_key,
        &cert,
        version,
        expected_fingerprint,
        timeout_ms.map(|ms| std::time::Duration::from_millis(ms as u64)),
    )
    .map_err(RsHttpClientError::from)?;

    Ok(RsHttpClient { inner })
}

impl RsHttpClient {
    pub async fn register(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        payload: RegisterDto,
    ) -> Result<ResultWithPublicKeyRegisterResponseDto, RsHttpClientError> {
        let response = self
            .inner
            .register(protocol, ip, port, payload)
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(ResultWithPublicKeyRegisterResponseDto {
            public_key: response.public_key,
            body: response.body,
        })
    }

    pub async fn prepare_upload(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        payload: PrepareUploadRequestDto,
        public_key: Option<String>,
        pin: Option<String>,
        cancel_token: &RsCancellationToken,
    ) -> Result<PrepareUploadResult, RsHttpClientError> {
        let response = self
            .inner
            .prepare_upload(
                protocol,
                ip,
                port,
                public_key,
                payload,
                pin.as_deref(),
                cancel_token.inner.clone(),
            )
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(response)
    }

    /// Uploads a single file, emitting [RsUploadEvent]s on [sink].
    ///
    /// Failures are emitted as [RsUploadEvent::Failed] instead of being
    /// returned: flutter_rust_bridge discards the returned `Result` of
    /// functions taking a [StreamSink], so a returned error would become an
    /// uncaught async error killing the calling isolate.
    pub async fn upload(
        &self,
        sink: StreamSink<RsUploadEvent>,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        public_key: Option<String>,
        session_id: &str,
        file_id: &str,
        token: &str,
        binary: Option<stream::Dart2RustStreamReceiver>,
        path: Option<String>,
        file_descriptor: Option<i32>,
        content_length: u64,
        cancel_token: &RsCancellationToken,
    ) {
        let result = async {
            let content = resolve_file_content(binary, path, file_descriptor)?;
            let last_emit = std::cell::Cell::new(None::<std::time::Instant>);
            let progress_sink = sink.clone();
            let progress = move |sent| {
                let now = std::time::Instant::now();
                let is_final = sent >= content_length;
                if !is_final {
                    if let Some(last) = last_emit.get() {
                        if now.duration_since(last) < std::time::Duration::from_millis(20) {
                            return;
                        }
                    }
                }
                last_emit.set(Some(now));
                let progress = if content_length == 0 {
                    1.0
                } else {
                    (sent as f64 / content_length as f64).min(1.0)
                };
                let _ = progress_sink.add(RsUploadEvent::Progress { progress });
            };

            self.inner
                .upload(
                    protocol,
                    ip,
                    port,
                    public_key,
                    session_id,
                    file_id,
                    token,
                    content,
                    progress,
                    cancel_token.inner.clone(),
                )
                .await
                .map_err(RsHttpClientError::from)?;

            Ok(())
        }
        .await;

        if let Err(error) = result {
            let _ = sink.add(RsUploadEvent::Failed { error });
        }
    }

    pub async fn cancel(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        session_id: &str,
    ) -> Result<(), RsHttpClientError> {
        self.inner
            .cancel(protocol, ip, port, session_id)
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(())
    }

    /// Lists the shared directories the peer publishes.
    pub async fn share_dirs(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
    ) -> Result<Vec<RsShareDir>, RsHttpClientError> {
        let dirs = self
            .inner
            .share_dirs(protocol, ip, port)
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(dirs.into_iter().map(RsShareDir::from).collect())
    }

    /// Lists one page of a directory of the peer's share.
    pub async fn share_list(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        dir: String,
        sub: String,
        cursor: Option<String>,
        limit: u16,
    ) -> Result<RsShareListPage, RsHttpClientError> {
        let dir = Uuid::parse_str(&dir)
            .map_err(|e| RsHttpClientError::Other(ErrorChain(&e).to_string()))?;

        let page = self
            .inner
            .share_list(protocol, ip, port, &dir, &sub, cursor.as_deref(), limit.max(1))
            .await
            .map_err(RsHttpClientError::from)?;

        Ok(RsShareListPage::from(page))
    }

    /// Downloads one shared file into the given target, emitting
    /// [RsShareDownloadEvent]s on [sink].
    ///
    /// Failures are emitted as [RsShareDownloadEvent::Failed] instead of being
    /// returned: flutter_rust_bridge discards the returned `Result` of
    /// functions taking a [StreamSink], so a returned error would become an
    /// uncaught async error killing the calling isolate.
    pub async fn share_download(
        &self,
        sink: StreamSink<RsShareDownloadEvent>,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        dir: String,
        path: String,
        total_size: u64,
        target_path: Option<String>,
        target_file_descriptor: Option<i32>,
        cancel_token: &RsCancellationToken,
    ) {
        let result = async {
            let dir = Uuid::parse_str(&dir).map_err(|e| RsHttpClientError::Other(ErrorChain(&e).to_string()))?;
            let mut writer = resolve_save_sink(target_path, target_file_descriptor).await?;

            let last_emit = std::cell::Cell::new(None::<std::time::Instant>);
            let progress_sink = sink.clone();
            let progress = move |received| {
                let now = std::time::Instant::now();
                let is_final = total_size == 0 || received >= total_size;
                if !is_final {
                    if let Some(last) = last_emit.get() {
                        if now.duration_since(last) < std::time::Duration::from_millis(20) {
                            return;
                        }
                    }
                }
                last_emit.set(Some(now));
                let fraction = if total_size == 0 {
                    1.0
                } else {
                    (received as f64 / total_size as f64).min(1.0)
                };
                let _ = progress_sink.add(RsShareDownloadEvent::Progress {
                    received,
                    progress: fraction,
                });
            };

            self
                .inner
                .share_download_to_writer(
                    protocol,
                    ip,
                    port,
                    &dir,
                    &path,
                    None,
                    &mut writer,
                    progress,
                    cancel_token.inner.clone(),
                )
                .await
                .map_err(RsHttpClientError::from)?;

            writer.shutdown().await.map_err(|e| RsHttpClientError::Io(e.to_string()))?;

            Ok::<(), RsHttpClientError>(())
        }
        .await;

        match result {
            Ok(()) => {
                let _ = sink.add(RsShareDownloadEvent::Finished);
            }
            Err(error) => {
                let _ = sink.add(RsShareDownloadEvent::Failed { error });
            }
        }
    }
}

fn resolve_file_content(
    binary: Option<stream::Dart2RustStreamReceiver>,
    path: Option<String>,
    file_descriptor: Option<i32>,
) -> Result<localsend::model::transfer::FileContent, RsHttpClientError> {
    match (binary, path, file_descriptor) {
        (Some(binary), None, None) => Ok(localsend::model::transfer::FileContent::Stream(
            binary.receiver,
        )),
        (None, Some(path), None) => Ok(localsend::model::transfer::FileContent::Path(path.into())),
        (None, None, Some(file_descriptor)) => {
            #[cfg(target_os = "android")]
            {
                Ok(localsend::model::transfer::FileContent::Fd(file_descriptor))
            }
            #[cfg(not(target_os = "android"))]
            {
                let _ = file_descriptor;
                Err(RsHttpClientError::Other(
                    "File descriptors are only supported on Android".into(),
                ))
            }
        }
        _ => Err(RsHttpClientError::Other(
            "Exactly one upload content source must be provided".into(),
        )),
    }
}

/// An event emitted while a file is being uploaded by [RsHttpClient::upload].
#[derive(Clone)]
pub enum RsUploadEvent {
    /// The upload progress as a fraction (0.0 to 1.0). Throttled.
    Progress { progress: f64 },

    /// The upload failed. Always the last event of the stream.
    Failed { error: RsHttpClientError },
}

#[derive(Clone)]
pub enum RsHttpClientError {
    StatusCode {
        status: u16,
        message: Option<String>,
    },
    Reqwest(String),
    Json(String),
    Io(String),
    Other(String),
}

impl From<ClientError> for RsHttpClientError {
    fn from(e: ClientError) -> Self {
        match e {
            ClientError::StatusCode(e) => RsHttpClientError::StatusCode {
                status: e.status,
                message: e.message,
            },
            ClientError::Reqwest(e) => RsHttpClientError::Reqwest(ErrorChain(&e).to_string()),
            ClientError::Json(e) => RsHttpClientError::Json(e.to_string()),
            ClientError::Io(e) => RsHttpClientError::Io(e.to_string()),
            ClientError::Other(e) => RsHttpClientError::Other(e.to_string()),
            ClientError::Cancelled => RsHttpClientError::Other("Cancelled".to_string()),
        }
    }
}

#[frb(mirror(LsHttpClientVersion))]
pub enum _LsHttpClientVersion {
    V2,
    V3,
}

#[frb(mirror(PrepareUploadResult))]
pub struct _PrepareUploadResult {
    pub status_code: u16,
    pub response: Option<PrepareUploadResponseDto>,
}

pub struct ResultWithPublicKeyRegisterResponseDto {
    pub public_key: Option<String>,
    pub body: RegisterResponseDto,
}

// -----------------------------------------------------------------------------
// Shared-directory client types.
//
// They mirror `localsend::share::*` using only primitives, the same way the
// server-side `RsShareSnapshot` does, so Dart receives plain classes instead of
// serde/UUID/PathBuf types crossing the boundary.
// -----------------------------------------------------------------------------

/// One directory a remote peer publishes.
pub struct RsShareDir {
    pub id: String,
    pub name: String,
    pub read_only: bool,
    /// `"longTerm"` or `"sessionOnly"`.
    pub kind: String,
}

impl From<localsend::share::ShareDirMeta> for RsShareDir {
    fn from(d: localsend::share::ShareDirMeta) -> Self {
        Self {
            id: d.id.to_string(),
            name: d.name,
            read_only: d.read_only,
            kind: match d.kind {
                localsend::share::ShareKind::SessionOnly => "sessionOnly".to_string(),
                _ => "longTerm".to_string(),
            },
        }
    }
}

/// One row of a remote directory listing.
pub struct RsShareEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// Unix seconds; `0` when the peer's filesystem does not report one.
    pub mtime: i64,
    pub rel_path: String,
}

impl From<localsend::share::ShareListEntry> for RsShareEntry {
    fn from(e: localsend::share::ShareListEntry) -> Self {
        Self {
            name: e.name,
            is_dir: e.is_dir,
            size: e.size,
            mtime: e.mtime,
            rel_path: e.rel_path,
        }
    }
}

/// Body of one remote directory listing.
pub struct RsShareListPage {
    pub directory_id: String,
    pub sub_path: String,
    pub entries: Vec<RsShareEntry>,
    pub next_cursor: Option<String>,
}

impl From<localsend::share::ShareListResponse> for RsShareListPage {
    fn from(p: localsend::share::ShareListResponse) -> Self {
        Self {
            directory_id: p.directory_id.to_string(),
            sub_path: p.sub_path,
            entries: p.entries.into_iter().map(RsShareEntry::from).collect(),
            next_cursor: p.next_cursor,
        }
    }
}

/// An event emitted while a shared file is being downloaded.
#[derive(Clone)]
pub enum RsShareDownloadEvent {
    /// Bytes received so far plus the fraction of `total_size` (0.0 to 1.0).
    /// Throttled.
    Progress { received: u64, progress: f64 },

    /// The file is complete and written to the target.
    Finished,

    /// The download failed. Always the last event of the stream.
    Failed { error: RsHttpClientError },
}

async fn resolve_save_sink(
    target_path: Option<String>,
    target_file_descriptor: Option<i32>,
) -> Result<tokio::fs::File, RsHttpClientError> {
    match (target_path, target_file_descriptor) {
        (Some(path), None) => tokio::fs::File::create(&path).await.map_err(|e| {
            RsHttpClientError::Io(format!("Failed to create {}: {e}", path))
        }),
        (None, Some(_fd)) => {
            #[cfg(target_os = "android")]
            {
                use std::os::fd::FromRawFd;

                // SAFETY: the descriptor is owned by this download; wrapping it in
                // a File transfers that ownership so it is closed once writing ends.
                let std_file = unsafe { std::fs::File::from_raw_fd(_fd) };
                Ok(tokio::fs::File::from_std(std_file))
            }
            #[cfg(not(target_os = "android"))]
            {
                Err(RsHttpClientError::Other(
                    "File descriptors are only supported on Android".into(),
                ))
            }
        }
        _ => Err(RsHttpClientError::Other(
            "Exactly one download target must be provided".into(),
        )),
    }
}
