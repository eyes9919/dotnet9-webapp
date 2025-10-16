# dotnet9-webapp

.NET 9 / C# 製のサンプル Web アプリケーションです。  
ローカル開発・CI/CD・AWS Fargate デプロイまでを一貫して自動化することを目的としています。

---

## 目次
- [dotnet9-webapp](#dotnet9-webapp)
  - [目次](#目次)
  - [概要](#概要)
  - [前提環境](#前提環境)
  - [ディレクトリ構成](#ディレクトリ構成)
  - [初回セットアップ](#初回セットアップ)
    - [.env の例](#env-の例)
  - [ローカル実行（Docker Compose）](#ローカル実行docker-compose)
    - [健康チェック構成（抜粋）](#健康チェック構成抜粋)
  - [テスト実行](#テスト実行)
  - [GitHub Actions（CI/CD）](#github-actionscicd)
  - [Copilot を用いた AWS デプロイ](#copilot-を用いた-aws-デプロイ)
    - [1. Copilot 環境構築](#1-copilot-環境構築)
    - [2. デプロイ](#2-デプロイ)
    - [3. Secrets 管理](#3-secrets-管理)
  - [トラブルシューティング](#トラブルシューティング)

---

## 概要

このリポジトリは、以下の技術スタックで構成されています。

| 要素 | 技術スタック |
|------|--------------|
| 言語 | C# (.NET 9) |
| フレームワーク | ASP.NET Core Minimal API |
| DB | PostgreSQL 16 (Dockerコンテナ) |
| インフラ | AWS ECS/Fargate（Copilot CLI 管理） |
| CI/CD | GitHub Actions |
| テスト | xUnit + Integration Tests |
| コンテナ管理 | Docker Compose / Copilot |
| シークレット管理 | AWS SSM Parameter Store |

---

## 前提環境

| 環境 | バージョン | 備考 |
|------|------------|------|
| macOS / Windows | 最新 | Apple Silicon (M1/M2/M3) 対応 |
| Docker Desktop | 4.30+ | `docker compose` コマンド使用可 |
| .NET SDK | 9.0.100+ | `dotnet` CLI 使用 |
| AWS CLI | 2.15+ | 認証済みプロファイルが必要 |
| Copilot CLI | 1.32+ | `brew install aws/tap/copilot-cli` で導入可 |

---

## ディレクトリ構成

```bash
dotnet9-webapp/
├── src/                        # アプリ本体
│   ├── WebApp/
│   └── WebApp.csproj
├── tests/
│   └── WebApp.IntegrationTests/
├── .github/
│   └── workflows/
│       └── ci.yml              # CI/CDワークフロー
├── docker-compose.yml
├── .env                        # 環境変数（ローカル用）
├── .env.sample                 # 雛形
├── copilot/
│   ├── webapp/manifest.yml
│   └── addons/
├── pgconf/                     # PostgreSQL初期設定ファイル
└── scripts/
    ├── rebuild_aws.sh
    └── destroy_aws.sh
```

---

## 初回セットアップ

```bash
# 1. クローン
git clone https://github.com/eyes9919/dotnet9-webapp.git
cd dotnet9-webapp

# 2. .envファイル作成
cp .env.sample .env

# 3. Dockerビルド
docker compose build

# 4. 初回DBセットアップ
docker compose up -d db
```

### .env の例

```dotenv
ASPNETCORE_ENVIRONMENT=Development
POSTGRES_USER=appuser
POSTGRES_PASSWORD=apppass
POSTGRES_DB=webappdb
POSTGRES_PORT=5432
```

---

## ローカル実行（Docker Compose）

```bash
# サービス起動
docker compose up -d

# ログ確認
docker compose logs -f webapp
```

### 健康チェック構成（抜粋）

`docker-compose.yml` 内では、PostgreSQL のヘルスチェックを行い、WebApp 起動を待機します。

```yaml
depends_on:
  db:
    condition: service_healthy
```

アクセスURL:  
**http://localhost:9999**

---

## テスト実行

```bash
# 単体テスト
dotnet test

# カバレッジ付き実行（CI連携用）
dotnet test --collect:"XPlat Code Coverage"
```

統合テストでは `WebApp.IntegrationTests` が PostgreSQL コンテナと連携して動作します。

---

## GitHub Actions（CI/CD）

`/.github/workflows/ci.yml` により自動ビルド・テスト・デプロイが行われます。

| 要素 | 内容 |
|------|------|
| `on.push` | mainブランチ・`chore/*`ブランチで起動 |
| `dotnet build/test` | 自動ビルド＆テスト |
| `needs:` | テスト成功後のみ deploy ジョブを実行 |
| `if:` | mainブランチのみ AWS デプロイ実施 |

キャッシュを効かせたビルド手順例：

```yaml
- name: Restore dependencies
  run: dotnet restore

- name: Build
  run: dotnet build --no-restore

- name: Test
  run: dotnet test --no-build --collect:"XPlat Code Coverage"
```

---

## Copilot を用いた AWS デプロイ

### 1. Copilot 環境構築

```bash
# 初回セットアップ
copilot init
```

または、既存環境に追加する場合：

```bash
copilot env init --name test --profile default --region ap-northeast-1
```

### 2. デプロイ

```bash
copilot deploy --name webapp --env test
```

### 3. Secrets 管理

あなたの環境では Secrets を変数展開ではなく、**明示パス指定**する必要があります：

```yaml
secrets:
  ADMIN_PASSWORD: /copilot/webapp/test/secrets/ADMIN_PASSWORD
```

この形式を `copilot/webapp/manifest.yml` に統一してください。

---

## トラブルシューティング

| 現象 | 確認ポイント |
|------|--------------|
| アプリが起動しない | `dotnet build` のエラー有無 |
| DB接続失敗 | `.env` の環境変数と `depends_on` 設定を確認 |
| MシリーズMacでイメージ取得失敗 | `platform: linux/arm64` が定義されているか |
| ポート競合エラー | `9999` / `5432` が他アプリで使用されていないか |
| Copilot Secrets 未検出 | SSM パスが `/copilot/...` 形式で一致しているか |
