# LocalGet

[![CI](https://github.com/cenlongzhen/localget/actions/workflows/ci.yml/badge.svg)](https://github.com/cenlongzhen/localget/actions/workflows/ci.yml)

LocalGet 是一个局域网文件传输应用，基于 [LocalSend](https://github.com/localsend/localsend) 二次开发。除了原有的「就近收发文件」，它增加了 **共享目录**：在设备上挂载若干本地目录，被信任的设备就能直接浏览并下载里面的文件，无需先发送。

- [与 LocalSend 的关系](#与-localsend-的关系)
- [功能](#功能)
  - [收发文件](#收发文件)
  - [共享目录](#共享目录)
- [共享协议](#共享协议)
- [仓库结构](#仓库结构)
- [构建](#构建)
- [测试](#测试)
- [平台与网络](#平台与网络)
- [许可证](#许可证)

## 与 LocalSend 的关系

LocalGet 是 LocalSend 的派生项目，沿用同一套传输协议（v2.2）与 HTTP/HTTPS 端口，因此 **可以与官方 LocalSend 互相收发文件**。设备之间不依赖任何服务器：发现走 UDP 多播，传输走点对点的 HTTPS，TLS 证书由每台设备即时生成。

共享目录是本项目在既有服务器上新增的一组只读接口（`/api/localsend/v2/share/*`），官方客户端不认识这些路径，会忽略它们；本项目的客户端在探测到对端不支持时会显示「无共享」而不是报错。

## 功能

### 收发文件

与原版一致：局域网内自动发现设备、多文件/目录发送、文本消息、手动输入 IP 直连、收藏设备、接收历史、接收确认与自动接收（含仅对收藏设备自动接收）、加密开关、带二维码的浏览器接收页、命令行客户端等。

### 共享目录

底部第三个 Tab「共享」包含三个子页：

**浏览共享** — 查看其他设备开放给你的目录。

- 顶部胶囊在「已信任本机」的多台对端之间切换，每台带设备类型图标
- 目录页逐级下钻，面包屑带分割线，返回键回上一级
- 工具栏：历史记录、宫格/列表切换、排序与筛选
  - 排序：按名称、按类型、从小到大、从大到小、从新到旧、从旧到新
  - 筛选：仅图片 / 音频 / 视频 / 文档 / 安装包（按平台分组，当前平台排前）/ 压缩包
- 列表模式按类型显示文件图标；宫格模式显示缩略图（图片本身、视频封面、音频专辑封面，无封面回落为音乐图标）
- 下载进度条旁的叉号可取消并删除未完成的残件
- 下载完成后进入接收历史；本次停留在页面期间，已下载的条目点击直接打开本地文件，重新进入页面则恢复为可下载状态

**本机共享** — 管理本机开放的目录。

- 挂载任意本地目录，可命名、可设为只读
- 「长期挂载」写入持久化配置，重启后保留；「本次会话」随服务器停止自动卸载，不落盘
- 点击条目编辑名称/路径/只读/类型，右侧按钮直接移除挂载（只撤销挂载，不动磁盘文件）
- Android 上挂载目录需要「所有文件访问权限」（`MANAGE_EXTERNAL_STORAGE`），否则拿不到真实路径

**信任设备** — 维护可以访问本机共享的白名单。

- 从局域网发现列表中多选添加；开关控制单台设备的信任状态
- 全部 / 已信任 / 未信任 三档胶囊筛选，并显示最近一次访问时间
- 信任关系只认 mTLS 客户端证书指纹，不需要口令或确认弹窗

## 共享协议

共享接口挂在既有服务器（默认端口 `53317`）的 URL 前缀 `/api/localsend/v2/share/` 下，只读、无上传/删除。

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/api/localsend/v2/share/dirs` | 列出可访问的共享目录 |
| GET | `/api/localsend/v2/share/list` | 列出目录内容，`dir` + `sub` + `cursor` + `limit`（1..=1000） |
| GET | `/api/localsend/v2/share/download` | 下载文件，`dir` + `path`，支持 `Range` |

- **鉴权**：以 TLS 客户端证书的 SHA-256（大写十六进制）匹配信任集合，未命中返回 `403`；TLS 关闭时退回请求方标识（用于集成测试），正常 App 间通信始终走证书指纹
- **路径防穿越**：相对路径拒绝绝对前缀、`..` 与 NUL，拼接后 `canonicalize` 再校验是否仍在目录根内
- **分页**：不透明 offset 游标（`c<offset>`），越界 `416`，`limit` 非法 `404`
- **Range**：`bytes=start-end` / `bytes=start-` / `bytes=-suffix` 三态，命中返回 `206` + `Content-Range`，不可满足返回 `416`，多段返回 `400`
- **热挂载**：目录与信任列表通过 `Arc<RwLock<…>>` 在运行期更新，改动无需重启服务器

实现位于 `packages/core/src/share/`（模型、注册表、路径守卫）与 `packages/core/src/http/server/share.rs`（三个 handler）；端到端往返测试见 `packages/core/tests/v2_share.rs`，完整设计契约见 [docs/share-directory.md](docs/share-directory.md)。

## 仓库结构

| 路径 | 内容 |
|------|------|
| `app/` | Flutter 应用（`localsend_app`）：UI、Provider、持久化、平台通道 |
| `packages/localsend_isolates/` | Dart isolate 层 + `flutter_rust_bridge` 绑定，含 Flutter 插件 crate |
| `packages/core/` | Rust crate `localsend`：协议、HTTP 服务端/客户端、加密、共享目录、WebRTC |
| `packages/typed_isolates/` | 带类型收发通道的 isolate 封装 |
| `server/` | WebRTC 信令服务器（Axum，`/v1/ws`） |
| `cli/` | 终端客户端 `localsend-cli` |
| `support/scripts/` | 各平台打包脚本（MSIX、Inno Setup、AppImage 等） |

四个 Rust crate 共用一个 Cargo workspace（根 `Cargo.toml`），三个 Dart 包共用一个 pub workspace。

依赖方向：`app` → `localsend_isolates` → (`typed_isolates`, 插件 crate → `localsend` core)。

## 构建

Flutter 版本固定在 `.fvmrc`（当前 `3.47.9`），Rust 版本固定在 `rust-toolchain.toml`（当前 `1.97.1`）。推荐用 [fvm](https://fvm.app) 管理 Flutter 版本。

```bash
cd app
fvm flutter pub get
fvm dart run build_runner build   # dart_mappable / freezed / flutter_gen / mockito
fvm dart run slang                # i18n 代码生成
fvm flutter run
```

Rust 侧：

```bash
cargo check                                        # 根目录，四个 crate
cargo clippy --features full --all-targets -p localsend   # core 必须带 --features full
```

FRB 绑定代码生成（在 `packages/localsend_isolates/` 下）：

```bash
flutter_rust_bridge_codegen generate
```

> 生成器会把 `app/test/mocks.mocks.dart` 重写成 80 列，出现该差异时回滚此文件。

打包：

```bash
cd app
flutter build windows      # 或 apk / appbundle / ipa / macos / linux
```

发布用脚本在 `support/scripts/`，版本号必须同时出现在 `app/pubspec.yaml`、`support/scripts/compile_windows_exe-inno.iss` 与 `cli/Cargo.toml`，否则 CI 会失败。

## 测试

CI 执行的内容：

```bash
# app
cd app
fvm dart format --set-exit-if-changed lib test
fvm flutter analyze
fvm flutter test

# Rust
cargo clippy --features full --all-targets -p localsend
cargo test --features full -p localsend
cargo test --package server
cargo check --package rust_lib_localsend_app --package localsend-cli
```

`packages/core` 的模块无条件声明、依赖却可选，裸 `cargo check` 会失败，必须带 `--features full`。

## 平台与网络

| 平台 | 最低版本 | 备注 |
|------|----------|------|
| Android | 7.0 | 共享目录需要「所有文件访问权限」 |
| Windows | 10 | |
| macOS | 12 Monterey | |
| iOS | 15.0 | |
| Linux | — | 需要 `xdg-desktop-portal` 及对应桌面实现 |

若设备互相不可见，请确认：

- 防火墙放行 TCP/UDP `53317`（如 `sudo ufw allow 53317`）
- 路由器未开启 AP 隔离（访客网络常默认开启）
- Windows 网络配置文件为「专用网络」
- VPN 未拦截局域网流量；必要时用「手动输入 IP」直连

## 许可证

本项目是 LocalSend 的派生作品，因此采用 **双许可**：

- 从 LocalSend 派生的代码仍为 **Apache License 2.0**，版权归 Tien Do Nam 及 LocalSend 贡献者所有，完整文本见 [LICENSE](LICENSE)，修改说明见 [NOTICE](NOTICE)
- 本项目新增的代码（共享目录协议、共享页 UI 等）以 **MIT License** 发布，文本见 [LICENSE-MIT](LICENSE-MIT)

Apache-2.0 是宽松许可证，允许再许可与商业使用，但不允许把上游代码单方面改成 MIT；因此整仓不能整体换成 MIT，只能对新增部分单独授权。分发时请同时保留 `LICENSE`、`NOTICE` 与 `LICENSE-MIT`。

## 致谢

- [LocalSend](https://github.com/localsend/localsend) — 原始应用与协议实现
- [LocalSend Protocol](https://github.com/localsend/protocol)
- 依赖层级图见 [support/docs/dependency-hierarchy.svg](support/docs/dependency-hierarchy.svg)
