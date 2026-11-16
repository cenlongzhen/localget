#![cfg(feature = "http")]
//! Integration tests for the shared-directory endpoints.
//!
//! The server runs **without TLS**, so `RequestClientInfo::cert_fingerprint()`
//! always returns `None`. `share::authenticate` then falls back to
//! `RequestClientInfo::identifier()`, which resolves to the peer IP (`"127.0.0.1"`)
//! for loopback connections — letting tests populate the trusted set with the
//! same string without needing real client certificates.
//!
//! See `docs/share-directory.md` §2 and §7.

use bytes::Bytes;
use http_body_util::{BodyExt, Empty};
use hyper::Method;
use hyper_util::rt::TokioIo;
use hyper::Request;
use localsend::http::server::v2::ServerEventV2;
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port_sharing, ServerConfigV2};
use localsend::http::state::ClientInfo;
use localsend::share::{
    ShareDirMeta, ShareKind, ShareListResponse, ShareRegistry, SharedDirectory, TrustedDevice,
};
use serde::de::DeserializeOwned;
use std::io::Write;
use std::net::{IpAddr, Ipv4Addr};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot};
use uuid::Uuid;

const LOOPBACK: &str = "127.0.0.1";

/// Fire a `GET` request against the test server and return `(status, body)`.
async fn get(port: u16, url_path: &str) -> (u16, Bytes) {
    let stream = TcpStream::connect((IpAddr::V4(Ipv4Addr::LOCALHOST), port))
        .await
        .unwrap();
    let io = TokioIo::new(stream);
    let (mut sender, conn) = hyper::client::conn::http1::handshake(io).await.unwrap();
    tokio::spawn(async move {
        let _ = conn.await;
    });
    let req = Request::builder()
        .method(Method::GET)
        .uri(url_path)
        .header("host", format!("127.0.0.1:{port}"))
        .body(Empty::<Bytes>::new())
        .unwrap();
    let resp = sender.send_request(req).await.unwrap();
    let status = resp.status().as_u16();
    let bytes = resp
        .into_body()
        .collect()
        .await
        .expect("collect body")
        .to_bytes();
    (status, bytes)
}

/// Start a plain-HTTP server with an optional shared-directory registry;
/// returns `(port, stop_tx, registry)`. Keeping the registry handle lets tests
/// assert `last_seen_at` refreshes and mutate state after boot.
async fn start_shared(
    dirs: Vec<SharedDirectory>,
    trusted: Vec<String>,
) -> (u16, oneshot::Sender<()>, Arc<ShareRegistry>) {
    let registry = Arc::new(ShareRegistry::load(dirs, vec![]));
    for id in trusted {
        registry.trust_device(TrustedDevice::new(id.clone(), "test peer"));
    }

    let (event_tx, mut event_rx) = mpsc::channel::<ServerEventV2>(16);
    tokio::spawn(async move {
        while event_rx.recv().await.is_some() {}
    });

    let (stop_tx, stop_rx) = oneshot::channel();
    let handle = start_with_port_sharing(
        0,
        None,
        ClientInfo {
            alias: "share-test".to_string(),
            version: "test".to_string(),
            device_model: None,
            device_type: None,
            token: "test-token".to_string(),
        },
        None,
        Some(ServerConfigV2 {
            pin: None,
            verify_checksums: false,
            event_tx,
        }),
        WebConfig::default(),
        Some(registry.clone()),
        stop_rx,
    )
    .await
    .expect("server start");
    (handle.port(), stop_tx, registry)
}

/// Build a temp root with:
///   ├── hello.txt         (9 bytes)
///   ├── sub/
///   │   └── inner.txt
///   └── secret/ (a sibling root we should NOT be able to reach)
///       └── forbidden.txt
fn make_tree() -> PathBuf {
    let base = std::env::temp_dir().join(format!("localsend-share-{}", Uuid::new_v4()));
    let _ = std::fs::create_dir_all(base.join("sub"));
    let _ = std::fs::create_dir_all(base.parent().unwrap().join(format!(
        "localsend-share-sibling-{}",
        Uuid::new_v4()
    )));
    let mut f = std::fs::File::create(&base.join("hello.txt")).unwrap();
    f.write_all(b"hi there!").unwrap();
    let mut g = std::fs::File::create(base.join("sub").join("inner.txt")).unwrap();
    g.write_all(b"inner").unwrap();
    base
}

fn json<T: DeserializeOwned>(bytes: &Bytes) -> T {
    serde_json::from_slice(bytes).expect("valid json")
}

fn dir(path: PathBuf) -> SharedDirectory {
    SharedDirectory::new("Root", path, ShareKind::LongTerm, true)
}

#[tokio::test]
async fn untrusted_peer_gets_403() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![]).await;
    let (status, _) = get(port, "/api/localsend/v2/share/dirs").await;
    assert_eq!(status, 403, "expected refusal without trust");
    let _ = std::fs::remove_dir_all(&root);
}

/// An untouched registry stays invisible (404) so peers do not advertise a
/// feature the user never configured.
#[tokio::test]
async fn empty_registry_answers_404() {
    let (port, _stop, _reg) = start_shared(vec![], vec![]).await;
    let (status, _) = get(port, "/api/localsend/v2/share/dirs").await;
    assert_eq!(status, 404, "an unconfigured registry must look disabled");
}

/// Mounting a directory after the server started must take effect immediately:
/// the registry outlives startup and is hot-swapped, not recreated.
#[tokio::test]
async fn registry_configured_after_start_is_visible() {
    let root = make_tree();
    let (port, _stop, reg) = start_shared(vec![], vec![]).await;
    let (status, _) = get(port, "/api/localsend/v2/share/dirs").await;
    assert_eq!(status, 404);

    reg.add_directory(dir(root.clone()));
    reg.trust_device(TrustedDevice::new(LOOPBACK.to_string(), "test peer"));

    let (status, body) = get(port, "/api/localsend/v2/share/dirs").await;
    assert_eq!(status, 200, "trusting a peer after start must open the endpoint");
    let dirs: Vec<ShareDirMeta> = json(&body);
    assert_eq!(dirs.len(), 1);
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn trusted_peer_sees_enabled_directories() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let (status, body) = get(port, "/api/localsend/v2/share/dirs").await;
    assert_eq!(status, 200);
    let dirs: Vec<ShareDirMeta> = json(&body);
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].name, "Root");
    assert!(dirs[0].read_only);
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn list_orders_directories_before_files_case_insensitive() {
    let root = make_tree();
    std::fs::create_dir_all(root.join("Zeta")).unwrap();
    std::fs::create_dir_all(root.join("alpha")).unwrap();
    std::fs::File::create(root.join("Bravo.txt")).unwrap();

    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let (_, body) = get(port, "/api/localsend/v2/share/dirs").await;
    let dirs: Vec<ShareDirMeta> = json(&body);
    let dir_id = dirs[0].id.to_string();

    let (status, body) = get(
        port,
        &format!("/api/localsend/v2/share/list?dir={dir_id}&sub="),
    )
    .await;
    assert_eq!(status, 200, "list failed: {body:?}");
    let resp: ShareListResponse = json(&body);

    // Directories first, each group case-insensitive alphabetically.
    let names: Vec<&str> = resp.entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, vec!["alpha", "sub", "Zeta", "Bravo.txt", "hello.txt"]);
    for entry in &resp.entries {
        // Every rel_path must be inside the shared root; assert shape only.
        assert!(entry.rel_path == entry.name || entry.rel_path.starts_with(&entry.name));
    }
    assert!(resp.next_cursor.is_none(), "single page fits the default limit");
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn list_paginates_with_opaque_cursor() {
    let root = make_tree();
    for name in ["a.txt", "b.txt", "c.txt"] {
        std::fs::write(root.join(name), b"x").unwrap();
    }
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let (_, body) = get(port, "/api/localsend/v2/share/dirs").await;
    let dirs: Vec<ShareDirMeta> = json(&body);
    let dir_id = dirs[0].id.to_string();

    let (status, body) = get(
        port,
        &format!("/api/localsend/v2/share/list?dir={dir_id}&limit=2"),
    )
    .await;
    assert_eq!(status, 200);
    let page1: ShareListResponse = json(&body);
    let names1: Vec<&str> = page1.entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names1, vec!["sub", "a.txt"]);
    let cursor = page1.next_cursor.clone().expect("more pages");

    let (status, body) = get(
        port,
        &format!("/api/localsend/v2/share/list?dir={dir_id}&limit=2&cursor={cursor}"),
    )
    .await;
    assert_eq!(status, 200);
    let page2: ShareListResponse = json(&body);
    let names2: Vec<&str> = page2.entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names2, vec!["b.txt", "c.txt"]);
    assert_eq!(page2.next_cursor.as_deref(), Some("c4"));

    let (status, body) = get(
        port,
        &format!("/api/localsend/v2/share/list?dir={dir_id}&limit=2&cursor=c4"),
    )
    .await;
    assert_eq!(status, 200);
    let page3: ShareListResponse = json(&body);
    assert_eq!(page3.entries.len(), 1);
    assert_eq!(page3.entries[0].name, "hello.txt");
    assert!(page3.next_cursor.is_none(), "last page");

    // A garbage cursor is refused rather than silently restarting at 0.
    let (status, _) = get(
        port,
        &format!("/api/localsend/v2/share/list?dir={dir_id}&cursor=nope"),
    )
    .await;
    assert_eq!(status, 416);

    // `limit=0` is out of range.
    let (status, _) = get(
        port,
        &format!("/api/localsend/v2/share/list?dir={dir_id}&limit=0"),
    )
    .await;
    assert_eq!(status, 404);

    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn list_rejects_traversal_paths_with_403() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let (_, body) = get(port, "/api/localsend/v2/share/dirs").await;
    let dirs: Vec<ShareDirMeta> = json(&body);
    let dir_id = dirs[0].id.to_string();

    let (status, _) = get(
        port,
        &format!("/api/localsend/v2/share/list?dir={dir_id}&sub=../"),
    )
    .await;
    assert_eq!(status, 403, "`..` must be refused as traversal");

    let (status, _) = get(
        port,
        &format!("/api/localsend/v2/share/list?dir={dir_id}&sub=%2Fetc%2Fpasswd"),
    )
    .await;
    assert_eq!(status, 400, "absolute `sub` must be refused as malformed");
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn download_returns_file_bytes_and_touches_seen() {
    let root = make_tree();
    let (port, _stop, reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;

    let (_, body) = get(port, "/api/localsend/v2/share/dirs").await;
    let dirs: Vec<ShareDirMeta> = json(&body);
    let dir_id = dirs[0].id.to_string();

    let (status, bytes) = get(
        port,
        &format!("/api/localsend/v2/share/download?dir={dir_id}&path=hello.txt"),
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(&bytes[..], b"hi there!");

    // Nested path also works.
    let (status, bytes) = get(
        port,
        &format!("/api/localsend/v2/share/download?dir={dir_id}&path=sub/inner.txt"),
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(&bytes[..], b"inner");

    // `last_seen_at_unix_secs` must have moved for the loopback identity.
    let seen = reg
        .all_trusted()
        .into_iter()
        .find(|t| t.fingerprint == LOOPBACK)
        .expect("loopback trusted");
    assert!(
        seen.last_seen_at_unix_secs.is_some(),
        "download must update last_seen_at"
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn download_of_missing_path_is_404() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let (_, body) = get(port, "/api/localsend/v2/share/dirs").await;
    let dirs: Vec<ShareDirMeta> = json(&body);
    let dir_id = dirs[0].id.to_string();

    let (status, _) = get(
        port,
        &format!("/api/localsend/v2/share/download?dir={dir_id}&path=nope.txt"),
    )
    .await;
    assert_eq!(status, 404);
    let _ = std::fs::remove_dir_all(&root);
}

/// Fire a `GET` with a `Range` header; returns `(status, headers, body)`.
async fn get_range(port: u16, url_path: &str, range: &str) -> (u16, hyper::HeaderMap, Bytes) {
    let stream = TcpStream::connect((IpAddr::V4(Ipv4Addr::LOCALHOST), port)).await.unwrap();
    let io = TokioIo::new(stream);
    let (mut sender, conn) = hyper::client::conn::http1::handshake(io).await.unwrap();
    tokio::spawn(async move {
        let _ = conn.await;
    });
    let req = Request::builder()
        .method(Method::GET)
        .uri(url_path)
        .header("host", format!("127.0.0.1:{port}"))
        .header("range", range)
        .body(Empty::<Bytes>::new())
        .unwrap();
    let resp = sender.send_request(req).await.unwrap();
    let status = resp.status().as_u16();
    let headers = resp.headers().clone();
    let bytes = resp.into_body().collect().await.expect("collect body").to_bytes();
    (status, headers, bytes)
}

#[tokio::test]
async fn download_honors_range_requests() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let (_, body) = get(port, "/api/localsend/v2/share/dirs").await;
    let dirs: Vec<ShareDirMeta> = json(&body);
    let dir_id = dirs[0].id.to_string();
    let url = format!("/api/localsend/v2/share/download?dir={dir_id}&path=hello.txt");

    // "hi there!" — bytes 3..=7 => "there"
    let (status, headers, bytes) = get_range(port, &url, "bytes=3-7").await;
    assert_eq!(status, 206);
    assert_eq!(&bytes[..], b"there");
    assert_eq!(headers.get("accept-ranges").unwrap(), "bytes");
    assert_eq!(headers.get("content-range").unwrap(), "bytes 3-7/9");
    assert_eq!(headers.get("content-length").unwrap(), "5");

    // Open-ended: bytes 6- => "re!"
    let (status, _, bytes) = get_range(port, &url, "bytes=6-").await;
    assert_eq!(status, 206);
    assert_eq!(&bytes[..], b"re!");

    // Suffix: last 2 bytes of "hi there!" => "e!"
    let (status, _, bytes) = get_range(port, &url, "bytes=-2").await;
    assert_eq!(status, 206);
    assert_eq!(&bytes[..], b"e!");

    // Past the end is unsatisfiable.
    let (status, _, _) = get_range(port, &url, "bytes=99-").await;
    assert_eq!(status, 416);

    // Multi-range needs multipart and is refused as malformed.
    let (status, _, _) = get_range(port, &url, "bytes=0-1,3-4").await;
    assert_eq!(status, 400);

    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn download_refuses_directory_paths_with_400() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let (_, body) = get(port, "/api/localsend/v2/share/dirs").await;
    let dirs: Vec<ShareDirMeta> = json(&body);
    let dir_id = dirs[0].id.to_string();

    let (status, _) = get(
        port,
        &format!("/api/localsend/v2/share/download?dir={dir_id}&path=sub"),
    )
    .await;
    assert_eq!(status, 400, "directory download is malformed");
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn download_disappears_when_directory_disabled() {
    let root = make_tree();
    let mut d = dir(root.clone());
    d.enabled = false;
    let (port, _stop, reg) =
        start_shared(vec![d.clone()], vec![LOOPBACK.into()]).await;
    // no dir listed
    let (_, body) = get(port, "/api/localsend/v2/share/dirs").await;
    let dirs: Vec<ShareDirMeta> = json(&body);
    assert!(dirs.is_empty());

    // download of the disabled dir returns 404
    let dir_id = d.id.to_string();
    let (status, _) = get(
        port,
        &format!("/api/localsend/v2/share/download?dir={dir_id}&path=hello.txt"),
    )
    .await;
    assert_eq!(status, 404);
    let _ = std::fs::remove_dir_all(&root);
    // Touch the reg so the compiler keeps it alive across awaits.
    let _ = reg.all_directories();
}

/// Explicitly verify the ShareListEntry is deserialized with the field names
/// documented in the contract, i.e. camelCase via serde on the wire.
#[tokio::test]
async fn list_entries_use_camel_case_keys_on_the_wire() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let (_, body) = get(port, "/api/localsend/v2/share/dirs").await;
    let dirs: Vec<ShareDirMeta> = json(&body);
    let dir_id = dirs[0].id.to_string();
    let (_, raw) = get(
        port,
        &format!("/api/localsend/v2/share/list?dir={dir_id}"),
    )
    .await;
    let text = String::from_utf8(raw.to_vec()).unwrap();
    assert!(text.contains("\"isDir\":"), "{text}");
    assert!(text.contains("\"relPath\":"));
    assert!(text.contains("\"directoryId\":"));
    assert!(text.contains("\"subPath\":"));
    let _ = std::fs::remove_dir_all(&root);
}

// ---------- App-side client (LsHttpClientV2 share calls) -------------------

use localsend::http::client::v2::LsHttpClientV2;
use localsend::http::StatusCodeError;
use localsend::model::discovery::ProtocolType;

/// The client used by the App to talk to a peer. Without a client certificate
/// the server cannot read a fingerprint, so it falls back to the peer IP — the
/// same identity the tests trust.
fn share_client() -> LsHttpClientV2 {
    LsHttpClientV2::try_new_without_cert().expect("client build")
}

async fn dirs_of(client: &LsHttpClientV2, port: u16) -> Vec<ShareDirMeta> {
    client
        .share_dirs(ProtocolType::Http, LOOPBACK, port)
        .await
        .expect("share_dirs")
}

#[tokio::test]
async fn client_lists_directories_and_entries() {
    let root = make_tree();
    std::fs::create_dir_all(root.join("alpha")).unwrap();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let client = share_client();

    let dirs = dirs_of(&client, port).await;
    assert_eq!(dirs.len(), 1);
    assert_eq!(dirs[0].name, "Root");
    assert!(dirs[0].read_only);
    assert_eq!(dirs[0].kind, ShareKind::LongTerm);

    let list = client
        .share_list(ProtocolType::Http, LOOPBACK, port, &dirs[0].id, "", None, 1000)
        .await
        .expect("share_list");
    assert_eq!(list.directory_id, dirs[0].id);
    assert_eq!(list.sub_path, "");
    let names: Vec<&str> = list.entries.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, vec!["alpha", "sub", "hello.txt"]);

    let inner = client
        .share_list(
            ProtocolType::Http,
            LOOPBACK,
            port,
            &dirs[0].id,
            "sub",
            None,
            1000,
        )
        .await
        .expect("nested share_list");
    assert_eq!(inner.sub_path, "sub");
    assert_eq!(inner.entries.len(), 1);
    assert_eq!(inner.entries[0].rel_path, "sub/inner.txt");

    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn client_reports_untrusted_peer_as_403() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![]).await;
    let client = share_client();

    let err = client
        .share_dirs(ProtocolType::Http, LOOPBACK, port)
        .await
        .expect_err("untrusted peer must refuse");
    let StatusCodeError { status, .. } = match err {
        localsend::http::client::ClientError::StatusCode(status) => status,
        other => panic!("expected a status error, got {other:?}"),
    };
    assert_eq!(status, 403);

    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn client_download_streams_bytes_to_writer_with_progress() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let client = share_client();
    let dirs = dirs_of(&client, port).await;

    let mut written = Vec::new();
    let mut reported = Vec::new();
    let total = client
        .share_download_to_writer(
            ProtocolType::Http,
            LOOPBACK,
            port,
            &dirs[0].id,
            "hello.txt",
            None,
            &mut written,
            |bytes| reported.push(bytes),
            tokio_util::sync::CancellationToken::new(),
        )
        .await
        .expect("download");

    assert_eq!(&written[..], b"hi there!");
    assert_eq!(total, written.len() as u64);
    assert_eq!(reported.last().copied(), Some(total), "progress ends at total");

    let nested = client
        .share_download_to_writer(
            ProtocolType::Http,
            LOOPBACK,
            port,
            &dirs[0].id,
            "sub/inner.txt",
            None,
            &mut Vec::new(),
            |_| {},
            tokio_util::sync::CancellationToken::new(),
        )
        .await
        .expect("nested download");
    assert_eq!(nested, 5);

    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn client_download_of_missing_path_is_404() {
    let root = make_tree();
    let (port, _stop, _reg) = start_shared(vec![dir(root.clone())], vec![LOOPBACK.into()]).await;
    let client = share_client();
    let dirs = dirs_of(&client, port).await;

    let err = client
        .share_download(
            ProtocolType::Http,
            LOOPBACK,
            port,
            &dirs[0].id,
            "nope.txt",
            None,
        )
        .await
        .expect_err("missing file must fail");
    match err {
        localsend::http::client::ClientError::StatusCode(StatusCodeError { status, .. }) => {
            assert_eq!(status, 404)
        }
        other => panic!("expected a status error, got {other:?}"),
    };

    let _ = std::fs::remove_dir_all(&root);
}
