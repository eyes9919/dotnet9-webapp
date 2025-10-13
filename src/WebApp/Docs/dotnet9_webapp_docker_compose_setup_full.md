# .NET 9 Webアプリ × PostgreSQL ローカル開発環境構築ガイド  
（VS Code + Docker Compose）

---

## 🧭 全体像

このドキュメントでは、以下を実現しました。

| 項目 | 内容 |
|------|------|
| 開発ツール | VS Code（C# Dev Kit利用） |
| 言語・フレームワーク | C# / .NET 9 / ASP.NET Core Razor Pages |
| データベース | PostgreSQL 16 |
| 実行環境 | Docker + Docker Compose |
| 起動方式 | `docker compose up --build` で Web + DB 両方起動 |
| URL | http://localhost:5230/Login |
| 初期ユーザー | admin / admin123! |
| HTTPS | 無効（開発時はHTTPで動作） |

---

## 🪜 ステップ 1：.NET 9 SDK と VS Code 環境構築

### 🎯 目的
.NET SDK 9.0 と VS Code に開発拡張を導入し、プロジェクトをGUI操作で作れるようにする。

### 💡 実施内容

1. [.NET公式サイト](https://dotnet.microsoft.com/ja-jp/download/dotnet/9.0) から  
   **.NET SDK 9.0 (Arm64)** をインストール。  
   ```bash
   dotnet --info
   ```
   でバージョンが `9.0.x` ならOK。

2. VS Code の拡張機能で以下をインストール：  
   - **C# Dev Kit**（Microsoft）  
   - **C#**（Microsoft）  
   - **Docker**（Microsoft）  
   - **YAML**（Red Hat）

3. コマンドパレット（⌘⇧P）→ `C# Dev Kit: Create New Project` を実行し、  
   - テンプレート: **ASP.NET Core Web App (Razor Pages)**  
   - Framework: `.NET 9`  
   - Auth: `None`  
   - HTTPS: `Yes`  
   - Docker: `No`  
   - プロジェクト名: `WebApp`  
   を選択して作成。

---

## 🪜 ステップ 2：PostgreSQLコンテナの構築

### 🎯 目的
Webアプリと接続するためのDBをDockerで起動できるようにする。

### 💡 実施内容

1. プロジェクトルート（`~/dotnet9-webapp`）に  
   `docker-compose.yml` を新規作成。

---

## 🧩 `docker-compose.yml`（最終版）

```yaml
services:
  db:
    image: postgres:16
    container_name: postgres-db
    platform: linux/arm64
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    ports:
      - "5432:5432"
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 5s

  web:
    build:
      context: ./src/WebApp
      dockerfile: Dockerfile
    container_name: dotnet9-webapp
    platform: linux/arm64
    depends_on:
      db:
        condition: service_healthy
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ASPNETCORE_URLS: http://+:8080
      ConnectionStrings__Default: Host=db;Port=5432;Database=${POSTGRES_DB};Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}
    ports:
      - "5230:8080"
    restart: unless-stopped

volumes:
  postgres-data:
```

---

## 🧩 `.env` ファイル

```env
POSTGRES_USER=appuser
POSTGRES_PASSWORD=apppass
POSTGRES_DB=appdb
```

---

## 🧩 `src/WebApp/Dockerfile`

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS base
WORKDIR /app
EXPOSE 8080

FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src
COPY . .
RUN dotnet restore
RUN dotnet publish -c Release -o /app/publish

FROM base AS final
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "WebApp.dll"]
```

---

## 🪜 ステップ 3：DB接続設定

```json
{
  "ConnectionStrings": {
    "Default": "Host=localhost;Port=5432;Database=appdb;Username=appuser;Password=apppass"
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "AllowedHosts": "*"
}
```

---

## 🧩 `Program.cs`（コメント付き）

```csharp
using Microsoft.EntityFrameworkCore;
using WebApp.Data;
using Microsoft.AspNetCore.Authentication.Cookies;

var builder = WebApplication.CreateBuilder(args);

// Razor Pages サービス登録
builder.Services.AddRazorPages();

// DB接続文字列を設定ファイルまたは環境変数から取得
var conn = builder.Configuration.GetConnectionString("Default")
           ?? Environment.GetEnvironmentVariable("ConnectionStrings__Default")
           ?? throw new InvalidOperationException("Connection string not found");

// PostgreSQL用のDbContextを登録
builder.Services.AddDbContext<AppDbContext>(opt => opt.UseNpgsql(conn));

// Cookie認証を追加
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(o =>
    {
        o.LoginPath = "/Login";            // 未認証時のリダイレクト先
        o.AccessDeniedPath = "/Login";
        o.ExpireTimeSpan = TimeSpan.FromHours(8);
    });

// /Users フォルダ以下は認証が必要
builder.Services.AddRazorPages(o =>
{
    o.Conventions.AuthorizeFolder("/Users");
});

var app = builder.Build();

// DBを自動マイグレーション＋初期データ投入
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    db.Database.Migrate();                  // スキーマ更新
    await AppDbContext.EnsureSeedAdminAsync(db); // 初期admin投入
}

// HTTPSリダイレクトはDevelopmentでは無効化（composeはHTTPで運用）
if (!app.Environment.IsDevelopment())
{
    app.UseHttpsRedirection();
    app.UseHsts();
}

// 静的ファイル・認証・ルーティング設定
app.UseStaticFiles();
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();

app.MapRazorPages(); // Razor Pagesを有効化
app.Run();           // アプリ起動
```

---

## 🧩 `Models/AppUser.cs`（コメント付き）

```csharp
namespace WebApp.Models;

// ユーザー情報テーブルに対応するモデルクラス
public class AppUser
{
    public int Id { get; set; }                      // 主キー
    public string UserName { get; set; } = string.Empty;  // ログインID
    public string DisplayName { get; set; } = string.Empty; // 表示名
    public string PasswordHash { get; set; } = string.Empty; // パスワードハッシュ
    public bool IsAdmin { get; set; }                // 管理者フラグ
}
```

---

## 🧩 `Data/AppDbContext.cs`（コメント付き）

```csharp
using Microsoft.EntityFrameworkCore;
using WebApp.Models;

namespace WebApp.Data;

// DbContextはDBとエンティティを橋渡しするクラス
public class AppDbContext(DbContextOptions<AppDbContext> options) : DbContext(options)
{
    public DbSet<AppUser> Users => Set<AppUser>();  // Usersテーブル

    protected override void OnModelCreating(ModelBuilder mb)
    {
        // モデル構成を定義
        mb.Entity<AppUser>(e =>
        {
            e.HasKey(x => x.Id);
            e.HasIndex(x => x.UserName).IsUnique();
            e.Property(x => x.UserName).HasMaxLength(64).IsRequired();
            e.Property(x => x.DisplayName).HasMaxLength(128).IsRequired();
            e.Property(x => x.PasswordHash).IsRequired();
            e.Property(x => x.IsAdmin).HasDefaultValue(false);
        });
    }

    // 初回にadminユーザーを自動投入
    public static async Task EnsureSeedAdminAsync(AppDbContext db)
    {
        if (!await db.AppUsers.AnyAsync())
        {
            var hash = BCrypt.Net.BCrypt.HashPassword("admin123!");
            db.AppUsers.Add(new AppUser
            {
                UserName = "admin",
                DisplayName = "Administrator",
                PasswordHash = hash,
                IsAdmin = true
            });
            await db.SaveChangesAsync();
        }
    }
}
```

---

## 🪜 ステップ 5：Docker Compose 起動

```bash
cd ~/dotnet9-webapp
docker compose up --build
```

成功時ログ：
```
Now listening on: http://0.0.0.0:8080
```
ブラウザで http://localhost:5230/Login にアクセス。

---

# 付録A：Dockerfile 行ごとの解説（コメント版）

```dockerfile
# ========== 1段目: 実行用の土台イメージ（ランタイム） ==========
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS base   # .NET 9 「実行専用」ランタイム
WORKDIR /app                                       # 作業ディレクトリを /app に
EXPOSE 8080                                        # コンテナが使用するポートを宣言（公開は compose の ports で）

# ========== 2段目: ビルド用ステージ（SDK） ==========
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build     # ビルド用の .NET 9 SDK イメージ
WORKDIR /src                                       # ソース作業ディレクトリ
COPY . .                                           # カレント（Docker コンテキスト）を /src にコピー
RUN dotnet restore                                 # NuGet 依存関係を復元（レイヤーキャッシュが効く）
RUN dotnet publish -c Release -o /app/publish      # 本番向け成果物を /app/publish へ出力

# ========== 3段目: 最終イメージ（軽量・実行用） ==========
FROM base AS final                                 # ランタイムをベースに最終イメージ作成
WORKDIR /app                                       # 実行時の作業ディレクトリ
COPY --from=build /app/publish .                   # 成果物のみコピー（SDKやソースは含めない）
ENTRYPOINT ["dotnet", "WebApp.dll"]                # コンテナ起動時にアプリを実行
```

**ポイント**  
- マルチステージで「ビルド用（重い）」と「実行用（軽い）」を分離 → **小さく速い本番イメージ**。  
- `EXPOSE 8080` は“宣言”。実際の公開は compose の `ports: "5230:8080"`。  
- compose で `ASPNETCORE_URLS=http://+:8080` を渡しているので Kestrel は 8080 を待受。

---

# 付録B：docker-compose.yml 行ごとの解説（コメント版）

```yaml
services:                                  # スタック内のサービス定義を開始
  db:                                      # DBサービス（ホスト名は "db" として他サービスから参照可能）
    image: postgres:16                     # 公式Postgres 16イメージ
    container_name: postgres-db            # わかりやすい固定名
    platform: linux/arm64                  # Apple Silicon 向け（省略可だが明示で安全）
    restart: unless-stopped                # 明示停止しなければ自動再起動
    environment:                           # 初期ユーザー/DB/パスワードを設定（.env から展開）
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    ports:
      - "5432:5432"                        # ホストから psql する場合などに利用
    volumes:
      - ./postgres-data:/var/lib/postgresql/data   # データ永続化（ホストへ保存）
    healthcheck:                           # DBの「接続受付可能」状態を判定
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 3s
      timeout: 3s
      retries: 10
      start_period: 5s

  web:                                     # .NET 9 Razor Pages アプリ
    build:
      context: ./src/WebApp                # Dockerfile 位置
      dockerfile: Dockerfile
    container_name: dotnet9-webapp
    platform: linux/arm64
    depends_on:                            # 起動の依存関係（順序＋状態）
      db:
        condition: service_healthy         # DB が healthy になるまで Web を起動しない
    environment:                           # Web アプリの環境変数
      ASPNETCORE_ENVIRONMENT: Development  # 開発モード
      ASPNETCORE_URLS: http://+:8080       # HTTP/8080 で待受
      ConnectionStrings__Default: Host=db;Port=5432;Database=${POSTGRES_DB};Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}
                                           # 接続先は "db" サービス（内部DNSで解決）
    ports:
      - "5230:8080"                        # ホスト 5230 → コンテナ 8080（ブラウザは http://localhost:5230）
    restart: unless-stopped                # 自動再起動

volumes:                                   # 名前付きボリューム宣言（必要に応じて利用）
  postgres-data:
```

**補足**  
- **サービス名＝内部ホスト名**：`Host=db` と書くだけで DB に届く（同一 Compose ネットワーク内）。  
- **healthcheck + service_healthy**：DB が**準備完了**するまで Web を待たせる。起動順だけの `depends_on` より安全。  
- **環境変数で接続文字列**：設定ファイルを書き換えず、環境ごとの切替が簡単。  
- **ボリューム**：いまはホストフォルダをバインド。名前付きボリュームに切り替える場合は `db.volumes` を `postgres-data:/var/...` に。

---

## 🪜 ステップ 6：起動と確認（おさらい）

```bash
cd ~/dotnet9-webapp
docker compose up --build
```

- Webログに `Now listening on: http://0.0.0.0:8080` が出ればOK  
- ブラウザで **http://localhost:5230/Login**  
- 初期ユーザー **admin / admin123!** でログイン

---

## ✅ まとめ（ここまででできること）

- `docker compose up --build` で **Web + DB 一括起動**  
- DB 初期化・接続・マイグレーション・Seed まで **自動化**  
- 失敗しがちな起動順は **healthcheck + service_healthy** で解決  
- VS Code でコードを編集 → 再ビルドで反映（ホットリロード運用は後から追加可能）
