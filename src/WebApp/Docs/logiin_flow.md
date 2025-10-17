# loginflow.md — 起動〜初回ログイン画面表示までの詳細フロー

本ドキュメントは、**`dotnet9-webapp`** が起動してから、ユーザーが初回に **ログイン画面（`/Login`）** を目にするまでに、
「どのプログラムや .cshtml が、どの順番で、なぜ読み込まれるか」を可視化したものです。  
（記載は .NET 9 / Razor Pages / Cookie 認証 を前提。コードは `src/WebApp/Program.cs` を元にしています。）

---

## 目次
- [loginflow.md — 起動〜初回ログイン画面表示までの詳細フロー](#loginflowmd--起動初回ログイン画面表示までの詳細フロー)
  - [目次](#目次)
  - [1. 起動時（プロセス生成〜アプリ構築）](#1-起動時プロセス生成アプリ構築)
  - [2. ホストビルド時に行われる主要処理](#2-ホストビルド時に行われる主要処理)
  - [3. HTTP パイプライン（ミドルウェア）の構成](#3-http-パイプラインミドルウェアの構成)
  - [4. エンドポイントの構成（Razor Pages 探索と認可規則）](#4-エンドポイントの構成razor-pages-探索と認可規則)
  - [5. 初回リクエストの基本シナリオ](#5-初回リクエストの基本シナリオ)
    - [シナリオ A：ユーザーが `/`（または `/Index`）にアクセス](#シナリオ-aユーザーが-または-indexにアクセス)
    - [シナリオ B：ユーザーが **保護ページ**（例：`/Admin`）に直接アクセス](#シナリオ-bユーザーが-保護ページ例adminに直接アクセス)
  - [6. ログイン画面が表示されるシナリオ](#6-ログイン画面が表示されるシナリオ)
    - [6-1. 保護ページからのリダイレクト](#6-1-保護ページからのリダイレクト)
    - [6-2. ユーザーが直接 `/Login` にアクセス](#6-2-ユーザーが直接-login-にアクセス)
  - [7. Razor Pages の表示に関与するファイルの読み込み順序](#7-razor-pages-の表示に関与するファイルの読み込み順序)
  - [8. Cookie 認証・認可の詳細](#8-cookie-認証認可の詳細)
  - [9. DB マイグレーションと管理者ユーザーのシード](#9-db-マイグレーションと管理者ユーザーのシード)
  - [10. Data Protection（Cookie 暗号鍵）の扱い](#10-data-protectioncookie-暗号鍵の扱い)
  - [11. トラブル時の観測ポイント](#11-トラブル時の観測ポイント)
  - [12. 補足：本番運用での注意](#12-補足本番運用での注意)
  - [付録：時系列シーケンス（テキスト図）](#付録時系列シーケンステキスト図)
    - [起動〜待ち受け開始](#起動待ち受け開始)
    - [保護ページアクセス〜ログイン画面表示](#保護ページアクセスログイン画面表示)

---

## 1. 起動時（プロセス生成〜アプリ構築）

```
dotnet WebApp.dll
      │
      └─▶ Program.cs の Main 相当（Minimal Hosting）
            └─ WebApplication.CreateBuilder(args)
```

- `WebApplication.CreateBuilder` が **ホスト** と **DI コンテナ** と **設定ソース**（appsettings.json, 環境変数, コマンドライン）を初期化します。
- `builder.Services` 経由でアプリ機能（Razor Pages、DbContext、認証/認可、HttpContextAccessor など）を DI に登録します。

---

## 2. ホストビルド時に行われる主要処理

Program.cs の主な登録処理（重要なもののみ抽出）：

1) **Razor Pages** … `AddRazorPages()`  
2) **HttpContextAccessor** … `AddHttpContextAccessor()`  
3) **Data Protection** … `AddDataProtection().PersistKeysToFileSystem(...).SetApplicationName("WebApp")`  
4) **EF Core / Npgsql** … `AddDbContext<AppDbContext>(options => UseNpgsql(...).EnableRetryOnFailure(...))`  
5) **Cookie 認証** … `AddAuthentication(...).AddCookie(...)`  
6) **認可（FallbackPolicy）** … `AddAuthorization(options => options.FallbackPolicy = RequireAuthenticatedUser())`  
7) **Razor Pages の認可規則** … `AllowAnonymousToPage("/Index" | "/Login" | "/Privacy" | "/Links" | "/Error" | "/")`  
8) **BuildInfo** … `AddSingleton<BuildInfo>()`（フッター/ヘッダでビルド情報表示用途）

その後 `var app = builder.Build()` により、ミドルウェアパイプラインを構築できる状態になります。

---

## 3. HTTP パイプライン（ミドルウェア）の構成

```
┌─────────────────────────────────────────────────────────┐
│ 1) 例外処理（本番） UseExceptionHandler("/Error")       │
│ 2) HSTS（本番） UseHsts()                               │
│ 3) HTTPS リダイレクト UseHttpsRedirection()             │
│ 4) 静的ファイル配信 UseStaticFiles()                    │
│ 5) ルーティング UseRouting()                            │
│ 6) 認証 UseAuthentication()                              │
│ 7) 認可 UseAuthorization()                               │
│ 8) エンドポイント MapRazorPages()                       │
└─────────────────────────────────────────────────────────┘
```

- 実際の順序は Program.cs の `app.Use...` の記述順。  
- **認証**→**認可**→**エンドポイント** の並びが重要です。

---

## 4. エンドポイントの構成（Razor Pages 探索と認可規則）

- `MapRazorPages()` により、`/Pages` 以下の `*.cshtml` が **ページエンドポイント** としてマッピングされます。  
- 認可のルールは以下の合成で決まります：
  - **FallbackPolicy**：明示指定のないすべてのページに「認証必須」を適用  
  - **AllowAnonymousToPage**：上記の特定ページには匿名アクセスを許可（`/Index`, `/Login`, `/Privacy`, `/Links`, `/Error`, `/`）  
  - ページ／ハンドラーに `[Authorize]` / `[AllowAnonymous]` 属性があればそれが最優先

---

## 5. 初回リクエストの基本シナリオ

### シナリオ A：ユーザーが `/`（または `/Index`）にアクセス
```
Browser ──▶ GET /
             │
             ├─▶ ルーティング（Razor Pages: /Pages/Index.cshtml）
             ├─▶ 認可判定：AllowAnonymous なので通過
             └─▶ ビュー描画：Index.cshtml（_ViewStart/_ViewImports/_Layout 経由）
```

- 既定では **ログインしていなくても Index ページは表示** されます（AllowAnonymous のため）。
- 画面上の「ログイン」リンク等から `/Login` へ遷移するのが自然な導線です。

### シナリオ B：ユーザーが **保護ページ**（例：`/Admin`）に直接アクセス
```
Browser ──▶ GET /Admin
             │
             ├─▶ ルーティング（/Pages/Admin.cshtml と仮定）
             ├─▶ 認可判定：FallbackPolicy により「要ログイン」
             ├─▶ 認証ミドルウェア：未認証のため Challenge（Cookie）
             └─▶ Cookie 認証の既定動作で /Login へ 302 リダイレクト
```

- この「**未認証 → /Login へリダイレクト**」がログイン画面に至る一般的な流れです。

---

## 6. ログイン画面が表示されるシナリオ

### 6-1. 保護ページからのリダイレクト
1. ユーザーが `/Admin` のような保護ページへアクセス  
2. 認可で **未認証** と判定  
3. Cookie 認証（Challenge）により `LoginPath = "/Login"` へ **302 リダイレクト**  
4. **`/Login`** 到達 → `Pages/Login.cshtml` が描画される（匿名許可）

### 6-2. ユーザーが直接 `/Login` にアクセス
1. ブラウザから `GET /Login`  
2. AllowAnonymous のため、そのまま `Pages/Login.cshtml` 表示

> **補足**：ログイン POST（`/Login?handler=...` など）で認証成功後、認証 Cookie が発行され、元々の保護ページ（`ReturnUrl`）へ 302 返却する構成が一般的です。

---

## 7. Razor Pages の表示に関与するファイルの読み込み順序

`/Login`（`Pages/Login.cshtml`）を例に、レンダリング時のファイル読取順を整理します。

```
1) _ViewStart.cshtml         （/Pages または /Views の上位で実行: レイアウト等の既定設定）
2) _ViewImports.cshtml       （TagHelper/Using などの取り込み）
3) Login.cshtml              （対象ページの本体: ページモデル Login.cshtml.cs があれば先に OnGet/OnPost 実行）
4) _Layout.cshtml            （レンダリングで使用されるレイアウト: ヘッダ/フッタ/メニューなど）
5) 部分ビュー/パーシャル    （必要に応じて _Partial*.cshtml や TagHelper, ViewComponent が呼ばれる）
```

- **ページモデル（`Login.cshtml.cs`）** が存在する場合、`OnGet` / `OnPost` などのハンドラが先に実行され、`ModelState` / `ViewData` を経て `Login.cshtml` へ渡されます。
- `_Layout.cshtml` では `BuildInfo`（DI登録済み）をインジェクトして、ビルド情報やナビゲーション、ログイン状態表示などに用いることができます。

---

## 8. Cookie 認証・認可の詳細

- Program.cs での設定：
  - `AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme).AddCookie(options => { LoginPath = "/Login"; AccessDeniedPath = "/Login"; ... })`
  - 認証されていないユーザーが保護ページを要求すると、**Challenge** により `LoginPath` へリダイレクトされます。
  - 認証は **Cookie** を通じて維持され、`ExpireTimeSpan = 8h` で期限管理。

- 認可：
  - `FallbackPolicy = RequireAuthenticatedUser()` により、明示設定のないページは**既定で保護**されます。
  - `AllowAnonymousToPage("/Login" など)` で、例外的に匿名アクセスを許可。

---

## 9. DB マイグレーションと管理者ユーザーのシード

**起動直後** に以下が行われます（`app.Services.CreateScope()` ブロック内）：

1) `db.Database.Migrate()` … モデルに合わせて DB スキーマを最新化（マイグレーションが適用される）  
2) `ADMIN_PASSWORD` 環境変数を参照し、**admin ユーザーを新規作成またはパスワード更新**  
3) `db.SaveChanges()` でコミット

> 注：本番では「毎起動でパスワードを上書きしない」ように制御した方が安全です。初回のみ投入、または明示フラグ時のみ更新など。

---

## 10. Data Protection（Cookie 暗号鍵）の扱い

- `AddDataProtection().PersistKeysToFileSystem(new DirectoryInfo("/tmp/aspnet-dp-keys")).SetApplicationName("WebApp")`  
- これにより **Cookie の暗号鍵がファイルに永続化** され、**プロセス再起動後も同じ鍵** で復号できます。  
- 複数インスタンスを運用する場合は、**共有ストレージ**（EFS/Redis/SQL等）を使って鍵リングを共有する必要があります。

---

## 11. トラブル時の観測ポイント

- **/Login にリダイレクトされない**  
  - 該当ページが `AllowAnonymousToPage` されていないか（= 既に匿名許可で保護されていない）
  - `UseAuthentication` / `UseAuthorization` の順序（Routing より後、MapRazorPages より前が原則）

- **ログイン後に保護ページへ戻らない**  
  - `ReturnUrl` の受け渡し/検証ロジックが正しいか  
  - `Cookie` が発行されているか（ブラウザの DevTools で確認）

- **起動時に Cookie 例外が出る**  
  - Data Protection のキー永続化パスの権限/書き込み可否を確認

- **起動時に DB エラーが出る**  
  - 接続文字列（`ConnectionStrings:Default` または `ConnectionStrings__Default`）が正しいか  
  - DB の起動順序（Docker Compose の `depends_on` と `healthcheck`）

---

## 12. 補足：本番運用での注意

- **EF マイグレーション**：ジョブ/ワンタイムタスクに分離し、アプリ本体起動時は実行しない運用が安全。  
- **ログレベル/機微情報**：`EnableSensitiveDataLogging()` は本番で無効。  
- **認証 Cookie セキュリティ**：`Cookie.SameSite/SecurePolicy/HttpOnly` のチューニング、HTTPS 強制。  
- **秘密情報**：`ADMIN_PASSWORD` は SSM などのセキュアストアで管理（Copilot は SSM パス指定運用）。

---

## 付録：時系列シーケンス（テキスト図）

### 起動〜待ち受け開始
```
dotnet WebApp.dll
  └─▶ CreateBuilder
        ├─ DI へ各種サービス登録 (RazorPages/EF/Auth/Authz/DataProtection/BuildInfo/...)
        └─ Build() で app 生成
             ├─ 環境が本番なら UseExceptionHandler + UseHsts
             ├─ UseHttpsRedirection → UseStaticFiles → UseRouting
             ├─ UseAuthentication → UseAuthorization
             └─ MapRazorPages
             └─ Run (Kestrel で待ち受け)
```

### 保護ページアクセス〜ログイン画面表示
```
Browser ──▶ GET /Admin
             ├─▶ ルーティング（/Pages/Admin.cshtml）
             ├─▶ 認可チェック（FallbackPolicy: 要ログイン）
             ├─▶ 未認証 → Cookie 認証の Challenge 発動
             └─▶ 302 Location: /Login
Browser ◀───┘

Browser ──▶ GET /Login
             ├─▶ ルーティング（/Pages/Login.cshtml）
             ├─▶ AllowAnonymous のため認可通過
             ├─▶ (Login.cshtml.cs があれば OnGet 実行)
             └─▶ _ViewStart/_ViewImports/_Layout を経由して Login.cshtml 描画
Browser ◀─── HTML（ログイン画面）
```

以上。
