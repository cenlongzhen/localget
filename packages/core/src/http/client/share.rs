use super::{ClientError, ResponseExt};
use crate::http::client::url::{ApiVersion, TargetUrl};
use crate::http::client::v2::LsHttpClientV2;
use crate::model::discovery::ProtocolType;
use crate::share::{ShareDirMeta, ShareListResponse};
use futures_util::StreamExt;
use reqwest::{Response, StatusCode};
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

/// Byte range of a resumable `share/download` request, inclusive on both ends.
pub type ByteRange = (u64, u64);

impl LsHttpClientV2 {
    /// Lists the shared directories the peer exposes.
    ///
    /// GET /api/localsend/v2/share/dirs
    pub async fn share_dirs(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
    ) -> Result<Vec<ShareDirMeta>, ClientError> {
        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/share/dirs",
            params: &[],
        }
        .to_string();

        let res = self.client.get(&url).send().await?;

        if res.status() != StatusCode::OK {
            return res.into_error().await;
        }

        Ok(res.json::<Vec<ShareDirMeta>>().await?)
    }

    /// Lists one page of entries of a shared directory.
    ///
    /// GET /api/localsend/v2/share/list?dir=...&sub=...&cursor=...&limit=...
    pub async fn share_list(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        dir: &Uuid,
        sub: &str,
        cursor: Option<&str>,
        limit: u16,
    ) -> Result<ShareListResponse, ClientError> {
        let dir = dir.to_string();
        let limit = limit.to_string();
        let mut params: Vec<(&'static str, &str)> =
            vec![("dir", dir.as_str()), ("limit", limit.as_str())];
        if !sub.is_empty() {
            params.push(("sub", sub));
        }
        if let Some(cursor) = cursor {
            params.push(("cursor", cursor));
        }

        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/share/list",
            params: &params,
        }
        .to_string();

        let res = self.client.get(&url).send().await?;

        if res.status() != StatusCode::OK {
            return res.into_error().await;
        }

        Ok(res.json::<ShareListResponse>().await?)
    }

    /// Downloads one file from a shared directory.
    ///
    /// GET /api/localsend/v2/share/download?dir=...&path=...
    ///
    /// A `range` is sent as a `Range` header; peers that honor it answer with
    /// 206 and the requested slice, older ones answer with the whole file.
    pub async fn share_download(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        dir: &Uuid,
        path: &str,
        range: Option<ByteRange>,
    ) -> Result<Response, ClientError> {
        let dir = dir.to_string();
        let url = TargetUrl {
            version: ApiVersion::V2,
            protocol: protocol.as_str(),
            host: ip.to_string(),
            port,
            path: "/share/download",
            params: &[("dir", dir.as_str()), ("path", path)],
        }
        .to_string();

        let mut request = self.client.get(&url);
        if let Some((start, end)) = range {
            request = request.header("Range", format!("bytes={start}-{end}"));
        }

        let res = request.send().await?;

        if res.status() != StatusCode::OK && res.status() != StatusCode::PARTIAL_CONTENT {
            return res.into_error().await;
        }

        Ok(res)
    }

    /// Downloads a shared file into `writer`, reporting the cumulative byte
    /// count through `progress`. Returns the number of bytes written.
    ///
    /// Cancelling `cancel` aborts the transfer with [`ClientError::Cancelled`];
    /// whatever was written so far stays in `writer`.
    pub async fn share_download_to_writer<W: tokio::io::AsyncWrite + Unpin>(
        &self,
        protocol: ProtocolType,
        ip: &str,
        port: u16,
        dir: &Uuid,
        path: &str,
        range: Option<ByteRange>,
        writer: &mut W,
        progress: impl FnMut(u64) + Send,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<u64, ClientError> {
        let response = self
            .share_download(protocol, ip, port, dir, path, range)
            .await?;

        let mut stream = response.bytes_stream();
        let mut total_bytes = 0u64;
        let mut progress = progress;

        loop {
            let chunk = tokio::select! {
                chunk = stream.next() => chunk,
                _ = cancel.cancelled() => return Err(ClientError::Cancelled),
            };
            let Some(chunk) = chunk else { break };
            let chunk = chunk?;
            writer.write_all(&chunk).await?;
            total_bytes += chunk.len() as u64;
            progress(total_bytes);
        }

        writer.flush().await?;

        Ok(total_bytes)
    }
}
