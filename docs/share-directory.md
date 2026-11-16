# LocalSend · 共享目录协议 v2.3 设计契约

> Status: **M6 完成** · 修订：2026-11-15  
> 作者：loomy · 决策依据：`LocalSend共享目录UI原型/index.html` v0.2  
> 影响 crate：`localsend` (`packages/core`)、`rust_lib_localsend_app` (`packages/localsend_isolates/rust`)、`localsend_isolates` (Dart)、`localsend_app` (Flutter)

## 0. 摘要

用户可在本机声明一个**或多个共享目录**；这些目录**只对已信任的设备**通过新增的 HTTP endpoint 暴露：列出目录 → 列文件 → 直接下载文件。鉴权锚点仍走 LocalSend 现有的 **mTLS 客户端证书指纹**，没有引入口令/密码。原型的"临时共享"（服务器停止即卸载）与"长期挂载"（跨重启保留）在 kind 字段上区分。UI 上共享页拆为「浏览共享 / 本机共享 / 信任设备」三 Tab，接收端"浏览对端共享"直接读取远端 fingerprint 白名单。

**v0.1 计划中的 ShareGrant / 明文密码 / 反向请求信任 已在 v0.2 决策中整体废弃**。

## 1. 设计原则

1. **信任 = fingerprint ∈ HashSet**：发送端维护一份 `TrustedDevice` 白名单；接收端只要出示匹配的 mTLS 客户端证书，即获授权，不再需要口令。
2. **只读**：v0.2 只承诺 list + download，不上传/不删除。以后如需上传走 v3 提案。
3. **无二次确认**：一次 `list` / `download` 请求即完成，服务器不打 App、也不发 `ServerEventV2::PrepareDownload`-型决策事件（信任已经建立）。
4. **会话级临时目录**：`ShareKind::SessionOnly`。服务器 stop 时从 registry 自动 purge；写入内存，不落磁盘；不参与持久化迁移。
5. **运行期热挂载**：`ShareRegistry` 通过 `Arc<RwLock<…>>` 传入，`start_with_port` 不重启即可增删目录/信任设备。区别于 pin/web_send，那两个是 handshake 常量。
6. **路径防穿越**：所有 client 传入的相对路径先 reject 绝对前缀、`..`、NUL，join 后再 `canonicalize` + `starts_with(root)` 二次校验（`dunce::canonicalize` 处理 Windows 长路径）。

## 2. HTTP 端点

Base host 为 LocalSend 的既有 server（默认 53 317，IPv4+IPv6 通听）。所有 endpoint 挂载在既有 URL 前缀 **`/api/localsend/v2/share/…`** 之下，避免与现有 `/v2/prepare-upload`/`/v2/upload`/`/v2/download` 冲突；v2 URL 前缀不代表协议版本 —— 只是路径命名空间稳定。

| 方法 | 路径 | Query / Body | 200 响应 | 常见错误 |
|---|---|---|---|---|
| GET | `/api/localsend/v2/share/dirs` | — | `[{ id, name, readOnly }]` | 403 未信任 · 503 registry 关闭 |
| GET | `/api/localsend/v2/share/list` | `dir: <uuid>` · `sub: <rel>?` · `cursor: <op>?` · `limit: 1..=1000` | `{ directoryId, subPath, entries: [ShareEntry], nextCursor? }` | 403 · 404 dir 不存在或禁用 · 416 分页 cursor 无效 |
| GET | `/api/localsend/v2/share/download` | `dir: <uuid>` · `path: <rel>` · `Range?` | file stream + length · `Accept-Ranges: bytes` · `Last-Modified` · `Content-Range` 可选 | 403 · 404 · 416 · 400 Malformed |

**鉴权**：与现有 v2 push endpoints 相同 —— TLS 客户端证书 SHA-256 大写十六进制 = `DeviceFingerprint`，命中 `registry.trusted` 即通；否则 403。**不引入任何新 header**。

### 2.1 响应 schema

`ShareDirMeta` (`/dirs` item)：

```json
{ "id": "uuid-v4", "name": "影视收藏", "readOnly": true, "kind": "longTerm|sessionOnly" }
```

`ShareListEntry` (`/list` items)：

```json
{
  "name": "Dune - Part Two.mkv",
  "isDir": false,
  "size": 9354158899,
  "mtime": 1730793600,
  "relPath": "2024/Dune - Part Two.mkv"
}
```

- `mtime`：Unix seconds，缺失时 0
- `relPath`：以 `/` 分隔的 POSIX-style 相对路径（Windows 也统一 `/`），可直接回填 `download?path=`

### 2.2 错误码约定

- `400 Bad Request`：Malformed（绝对路径 / NUL / 空 dir）
- `403 Forbidden`：fingerprint 不在 trusted 集合中，或请求指向 disabled directory（后者返回空数组而非 403 也可以，选择保守：403）
- `404 Not Found`：dir/path/limit 不存在
- `416 Range Not Satisfiable`：Range 超文件长度
- `429 Too Many Requests`：预留，v0.2 未启用

## 3. Rust 数据模型

**位于**：`packages/core/src/share/`

```rust
pub enum ShareKind       { LongTerm, SessionOnly }

pub struct SharedDirectory {
    id: Uuid, name: String, root: PathBuf,
    kind: ShareKind,
    read_only: bool,
    enabled: bool,
    added_at_unix_secs: u64,
}

pub struct TrustedDevice {
    fingerprint: String,  // 64 hex, uppercase
    alias: String,
    added_at_unix_secs: u64,
    last_seen_at_unix_secs: Option<u64>,
}

pub struct ShareListEntry { name, is_dir, size, mtime, rel_path }
pub struct ShareListResponse { directory_id, sub_path, entries, next_cursor }
pub struct ShareDirMeta    { id, name, read_only, kind }

pub const MAX_LIST_PAGE: usize = 1000;
pub const LAST_SEEN_COALESCE: Duration = Duration::from_secs(15);
```

**Registry**：`ShareRegistry { RwLock<HashMap<Uuid,SharedDirectory>>, RwLock<HashMap<String,TrustedDevice>> }`。所有 mutate / query 走 read/write lock。核心 API 见 `registry.rs`。

**Server 接入**：registry 不挂在 `ServerConfigV2` 上，而是 `start_with_port_sharing(...)` 的独立参数 `share: Option<Arc<ShareRegistry>>`；`start_with_port` 只是传 `None` 的薄包装，因此现有调用方无需改动。`AppState.share` 内嵌同一份 `Arc`，handler 里通过 `state.share(...)` 访问。

注册表在 FRB 层**始终创建**（`start_server` 的空快照退化为空 registry），否则启动后再添加信任设备时 `update_share` 会静默失效、对端永远拿不到目录。是否对外可见由 `ShareRegistry::is_configured()` 决定：目录与信任列表都为空时 `/share/*` 仍返回 404，用户从未使用过该功能时对端不会看到假象。

## 4. Dart 数据模型

**位于**：`packages/localsend_isolates/lib/model/share.dart`

```dart
enum ShareKind { longTerm, sessionOnly }

class SharedDirectory { id, name, root, kind, readOnly, enabled, addedAt }
class TrustedDevice   { fingerprint, alias, addedAt, lastSeenAt }
class ShareListEntry  { name, isDir, size, mtimeUnix, relPath }
class ShareDirMeta    { id, name, readOnly }
```

模型本身是纯 Dart（无 `@MappableClass`）；落盘时由 `PersistenceService` 手写 `toJson`/`fromJson`。

## 5. App 侧 Provider 与 UI

**位于**：`app/lib/provider/share/share_provider.dart`

```dart
final shareProvider = NotifierProvider<ShareNotifier, ShareSnapshot>(...);

// ShareNotifier 的变更方法
addDirectory(...) / updateDirectory(...) / removeDirectory(...)
setDirectoryEnabled(...) / trustDevice(...) / revokeDevice(...) / touchSeen(...)
```

每次变更都走 `_persistAndPush()`：longTerm 目录与信任设备写 `shared_preferences`，随后经 `IsolateHttpServerUpdateShareAction` 推入运行中的 Rust registry（无需重启服务器）。服务器尚未启动时静默跳过，由 `ServerService._currentShareSnapshot()` 在启动时带上初始快照。

**UI 位于 `app/lib/pages/share/`**：

| 文件 | 用途 | 原型对应 |
|---|---|---|
| `share_tabs_page.dart` | 顶层 Scaffold + TabBar（浏览共享 · 本机共享 · 信任设备），FAB 依 tab 索引弹不同 sheet | 屏 1 / 屏 2 |
| `directories_tab.dart` | 目录列表 + 开关 + 删除 | 屏 1 |
| `trusted_devices_tab.dart` | 信任设备列表 + "移除信任" | 屏 2 |
| `add_directory_sheet.dart` | 目录名 + 路径 + 只读 switch + kind segmented + Save | 屏 3 |
| `add_trusted_device_sheet.dart` | 从发现列表多选 + Save | 屏 4 |

入口就是底部第 3 个 Tab「共享」本身，不再挂 Settings。浏览对端共享、管理本机目录、维护信任设备都在这一页的三个 Tab 内完成，见 §9.1。

## 6. FRB 边界

- `packages/localsend_isolates/rust/src/api/server.rs`：`start_server` 新增参数 `share_snapshot: Option<RsShareSnapshot>`，启动时物化成 registry
- `RsHttpServer::update_share(RsShareSnapshot)`：热交换，配合 `ShareNotifier._pushToIsolate()`
- 生成命令：`flutter_rust_bridge_codegen generate`（在 `packages/localsend_isolates/` 下）→ 会自动重写 `app/test/mocks.mocks.dart` 到 80 列，**提交前 `git checkout app/test/mocks.mocks.dart` 回滚**（AGENTS.md 已提示）
- 生成器的 `stem`（动态库名）依赖 `cargo metadata`；若该命令因网络失败，绑定会被写成 `stem: 'UNKNOWN'`，运行时 `initRustLib()` 直接报 "Failed to load dynamic library 'UNKNOWN.dll'"。生成后请确认 `frb_generated.dart` 里是 `rust_lib_localsend_app`
- 共享目录快照**不**走 `SyncState`：它随 server 启动参数与 `update_share` 传递，因此不受 `_PublishSyncStateAction` 广播影响

## 7. 隔离逻辑（Rust handler 落地要点）

```
match (req.method(), req.uri().path()) {
  (&Method::GET, "/api/localsend/v2/share/dirs") => share::dirs(req, state, client_info).await,
  (&Method::GET, "/api/localsend/v2/share/list") => share::list(req, state, client_info).await,
  (&Method::GET, "/api/localsend/v2/share/download") => share::download(req, state, client_info).await,
  ...
}
```

`share::dirs / list / download` 内部一致流程：

1. 从 `client_info.cert_fingerprint()` 拿 fingerprint；`None` → `AppError::Status(403)` 因为加密关了或浏览器无证书
2. `state.registry().trusted_contains(fp)?`
3. 解析 query，`pathguard::PathGuard::resolve(root, sub)?`
4. 组装响应，或流式读文件
5. 成功后 `registry.touch_seen(fp, now)`（coalesce 15s）

`download` 按 `Range` 分支：无 Range 时整文件读入内存后用 `full_body` 返回；有 Range 时只读所需区间并返回 206 + `Content-Range`。文件大小受 OS 内存约束，对 LocalSend 的典型载荷足够。

## 8. 测试矩阵

| Level | Rust | Dart |
|---|---|---|
| Unit | `pathguard::tests` · `registry::tests` · `trusted::tests` | — |
| Integration | `tests/v2_share.rs`（服务端 + 客户端往返，17 例，含「空注册表 404」「启动后挂载立即可见」两条回归） | — |
| End-to-end | 手工冒烟：Windows 版 `flutter build windows --debug` 启动后走通共享页三个 Tab、添加/移除目录、添加信任设备弹层 | — |

## 9. 里程碑

- **M1 · 骨架（本文档）**：Rust models / Registry / PathGuard + Dart models / Provider / UI 空壳；`cargo check --features full` + `flutter analyze` 双绿
- **M2 · Rust handler**：3 个 endpoint 落地 + 集成测试
- **M3 · FRB + isolate**：`start_server(share_snapshot)` 接入；`update_share` 热挂载；Dart notifier 直推 isolate
- **M4 · Flutter 挂真数据 + 路由**：Settings tab 添加入口；接收端浏览页
- **M5 · 平台细节 + persistence**：SAF / NSOpenPanel / iOS 相册；写盘
- **M6 · i18n + 文档 + CI**

### 9.1 落地记录（相对计划的偏差）

- **共享功能收拢到底部第 3 个 Tab**（`HomeTab.shared` → `ShareTabsPage`），Settings 里的入口已移除。该页顶部三个 Tab：浏览共享（`SharedDevicesTab`）、本机共享（`DirectoriesTab`）、信任设备（`TrustedDevicesTab`）。浏览页顶部用胶囊 `ChoiceChip` 行在多台已信任本机的对端之间切换，下方列出当前选中设备共享的目录；进入目录后仍是文件列表页。原 `app/lib/pages/browse/` 已删除。
- **`accessible` 与「无目录」解耦**：对端返回 200 但目录为空时仍记为 `accessible`，这样「已信任但没挂载」的对端会出现在胶囊行并显示「这台设备没有共享目录」，而不是被过滤掉、看起来像功能坏了。
- **M5 的分页改为不透明 offset 游标**（`c<offset>`）：`limit` 缺省等于 `MAX_LIST_PAGE`，越界或非法 `limit` 返回 404，非法 `cursor` 返回 416。服务端整页读出后切片，客户端 `share_list` 透传 `cursor`/`limit`，App 侧「加载更多」逐页追加。
- **M5 的 Range 支持**：`bytes=start-end` / `bytes=start-` / `bytes=-suffix` 三态；命中返回 206 + `Content-Range`，不可满足返回 416，多段 Range 返回 400。客户端 `share_download_to_writer` 接受可选的 `ByteRange`。
- **持久化**：`PersistenceService` 新增 `ls_share_directories` / `ls_share_trusted_devices` 两个键；只有 `longTerm` 目录落盘，`sessionOnly` 仅存内存。
- **UUID 修正**：M1 的目录 id 生成器产出非 UUID 字符串，而 `RsShareSnapshot::into_registry` 会静默丢弃解析失败的 id —— 热挂载此前实际无效。现改用 `uuid` v4。

## 10. 已知不做

- 反向"请求信任"（屏 6 支线）
- 密码 ShareGrant 与撤销 API
- web / cli 客户端访问 share endpoint（决策：仅 App 之间；web.rs 保持单向 push）
- 设备离线/在线状态精确同步（骨架阶段依赖现有多播 heartbeat）
