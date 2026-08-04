# Plan: OIDC Access Token Auto-Refresh（低风险）

> 实现已按本计划落地。细节见 session plan 与源码 `TokenRefresher.swift`。

## Goals

1. 查用量前对即将/已经过期且持有 `refresh_token` 的 OIDC 凭证，调用 `auth.x.ai` 标准 refresh grant。
2. 写回 profile `auth.json`（`key` / `expires_at` / 可选新 RT）。
3. 风险控制：仅官方 token 端点、低频、flock + 原子写、permanent 失败即停、不绕配额。

## Non-goals

完整 OAuth 登录、委托 CLI、Keychain、Settings 开关、企业自定义 IdP（首版仅 `auth.x.ai`）。

## Key modules

| 文件 | 职责 |
|------|------|
| `AuthReader.swift` | `needsRefresh` / `canSilentRefresh` / OIDC 字段；全过期时优先可 refresh 的 entry |
| `TokenRefresher.swift` | `AuthFileLock` + `ensureFresh` |
| `ProfileStore.swift` | 用量刷新前 `ensureFresh` |
| `UsageFetcher.swift` | 401 单次 ensureFresh + retry |

## DoD

见实现 PR / 手测清单（过期+RT 可恢复；invalid_grant 不重试风暴；权限 0600）。
