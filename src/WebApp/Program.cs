using Microsoft.AspNetCore.Authentication.Cookies;   // Cookie 認証（サインイン/サインアウトや認可で使う）を有効化するための名前空間
using Microsoft.AspNetCore.Authorization;             // 認可（ポリシー/要件など）の機能を提供する名前空間
using Microsoft.EntityFrameworkCore;                  // Entity Framework Core（DbContext/マイグレーション等）を使うための名前空間
using Microsoft.AspNetCore.DataProtection;            // ASP.NET Core データ保護（Cookie暗号鍵の保管など）を扱う名前空間
using WebApp.Data;                                   // アプリ固有のデータ層（AppDbContext など）への参照
using WebApp.Models; // ← BuildInfo.cs 用              // アプリ固有のモデル（BuildInfo など）への参照

var builder = WebApplication.CreateBuilder(args);     // ホスト/サービス/設定を構築するためのビルダを作成（Minimal Hosting）

// Razor Pages 有効化
builder.Services.AddRazorPages();                     // Razor Pages をサービスに登録（/Pages の .cshtml をルーティング対象にする）

// HttpContextAccessor 登録（_Layout.cshtml などで使用）
builder.Services.AddHttpContextAccessor();            // View/サービスから HttpContext を取得できるようにするアクセサをDI登録

// DataProtection キー永続化（Cookieエラー防止、開発用）
builder.Services.AddDataProtection()                  // データ保護（Cookie暗号、CSRFトークン等）機能を構成
    .PersistKeysToFileSystem(new DirectoryInfo("/tmp/aspnet-dp-keys")) // 暗号キーをファイルに永続化（コンテナ/再起動でもキーを共有）
    .SetApplicationName("WebApp");                    // 同一キーリングを共有するApp名を指定（スロット/複数インスタンス間で整合させる）

// DB 接続設定
var conn = builder.Configuration.GetConnectionString("Default") // appsettings の "ConnectionStrings:Default" を優先して取得
           ?? Environment.GetEnvironmentVariable("ConnectionStrings__Default") // 上記が無い場合は環境変数から取得（K8s/ECSで一般的）
           ?? throw new InvalidOperationException("Connection string not found"); // どちらも無ければ起動時に例外（必須設定のため）

builder.Services.AddDbContext<AppDbContext>(opt =>   // AppDbContext をDIに登録（スコープド）
    opt.UseNpgsql(conn, npgsqlOptions =>             // Npgsql（PostgreSQL）プロバイダを使用し接続文字列を設定
    {
        npgsqlOptions.EnableRetryOnFailure(          // 一時的な障害を想定した再試行戦略（Transient fault handling）
            maxRetryCount: 5,                        // 最大5回までリトライ
            maxRetryDelay: TimeSpan.FromSeconds(10), // リトライ間隔の上限は10秒
            errorCodesToAdd: null);                  // 追加のエラーコード無し（デフォルトの再試行対象を使用）
    })
    .EnableDetailedErrors()                          // 詳細なDB例外情報を有効化（開発/検証向け：本番では慎重に）
    .EnableSensitiveDataLogging()                    // 機微情報を含むログ出力を許可（開発向け：本番は無効推奨）
);

// Cookie 認証設定
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme) // Cookie認証を既定スキームとして有効化
    .AddCookie(o =>                                 // Cookie の詳細設定
    {
        o.LoginPath = "/Login";                     // 未認証アクセス時のリダイレクト先（ログインページ）
        o.AccessDeniedPath = "/Login";              // 権限不足時の遷移先（ここでは同じくログインへ）
        o.ExpireTimeSpan = TimeSpan.FromHours(8);   // 認証Cookieの有効期限（8時間）
    });

// 認可ポリシー（既定は要ログイン）
builder.Services.AddAuthorization(o =>              // 認可ポリシーを構成
{
    o.FallbackPolicy = new AuthorizationPolicyBuilder() // 明示ポリシー未指定の全エンドポイントに適用されるフォールバック
        .RequireAuthenticatedUser()                // 既定で「認証済みユーザー必須」にする
        .Build();
});

// Razor Pages 認可設定
builder.Services.AddRazorPages(o =>                 // ページごとの認可ルールを追加構成
{
    // 匿名アクセスを許可するページ
    o.Conventions.AllowAnonymousToPage("/Index");   // トップページを匿名許可
    o.Conventions.AllowAnonymousToPage("/Login");   // ログインページは匿名許可
    o.Conventions.AllowAnonymousToPage("/Privacy"); // プライバシーポリシーは匿名許可
    o.Conventions.AllowAnonymousToPage("/Links");   // リンク集は匿名許可
    o.Conventions.AllowAnonymousToPage("/Error");   // エラーページは匿名許可
    o.Conventions.AllowAnonymousToPage("/");        // ルート（/）も匿名許可（Indexと重複指定だが明示）
});

// ==========================================================
// BuildInfo を DI に登録（ヘッダーで動的に利用）
// ==========================================================
// Program.cs（AddRazorPages などの後でOK）
builder.Services.AddSingleton<WebApp.Models.BuildInfo>(_ => new WebApp.Models.BuildInfo());
// ↑ ビルド時刻やバージョンなどを載せるユーティリティをSingletonでDI登録。レイアウトやフッターで参照する想定。

// ==========================================================

var app = builder.Build();                          // ここでWebアプリのパイプライン（ミドルウェア）を構築

// DB マイグレーションと admin 初期化
using (var scope = app.Services.CreateScope())      // スコープを作ってスコープドサービス（DbContext）を解決
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>(); // DIからAppDbContextを取得
    try
    {
        db.Database.Migrate();                      // 現在のモデルに合わせてDBを自動マイグレーション（起動時適用）

        // admin ユーザーの初期投入または更新
        var adminUser = db.AppUsers.FirstOrDefault(u => u.UserName == "admin"); // 既存のadminユーザー検索
        var adminPassword = Environment.GetEnvironmentVariable("ADMIN_PASSWORD") ?? "admin123!";
        // ↑ 管理者パスワードを環境変数から取得。無ければデフォルト（開発用）。本番では必ず環境変数で上書き必須。

        if (adminUser == null)                      // adminが未作成なら
        {
            db.AppUsers.Add(new AppUser
            {
                UserName = "admin",
                DisplayName = "Administrator",
                PasswordHash = BCrypt.Net.BCrypt.HashPassword(adminPassword), // パスワードをハッシュ化して保存
                IsAdmin = true
            });
            app.Logger.LogInformation("Seeded new admin user."); // 新規投入したことをログ
        }
        else                                        // すでに存在する場合は
        {
            adminUser.PasswordHash = BCrypt.Net.BCrypt.HashPassword(adminPassword); // パスワードを更新（毎起動で上書きの挙動）
            db.AppUsers.Update(adminUser);
            app.Logger.LogInformation("Updated existing admin password."); // 更新ログ
        }

        db.SaveChanges();                            // 変更の確定（INSERT/UPDATE を発行）
    }
    catch (Exception ex)
    {
        app.Logger.LogError(ex, "Database migration or seeding failed."); // 失敗時はログに残す（起動は継続）
    }
}

// 例外処理
if (!app.Environment.IsDevelopment())               // 開発環境以外（staging/prod等）のとき
{
    app.UseExceptionHandler("/Error");              // 例外をキャッチして /Error ページへ（ユーザー向けに安全な応答）
    app.UseHsts();                                  // HSTS を有効化（HTTPS強制：ブラウザにポリシーを配布）
}

app.UseHttpsRedirection();                          // HTTPアクセスをHTTPSへリダイレクト
app.UseStaticFiles();                               // wwwroot 等の静的ファイル（CSS/JS/画像）を配信
app.UseRouting();                                   // ルーティング（エンドポイントマッピングの前段）

// 認証／認可
app.UseAuthentication();                            // 認証ミドルウェア（Cookieを検証してユーザーに紐付け）
app.UseAuthorization();                             // 認可ミドルウェア（ポリシー/属性に基づきアクセス制御）

// Razor Pages のルートのみマッピング
app.MapRazorPages();                                // Razor Pages をエンドポイントにマップ（/Pages 下を公開）

app.Run();                                          // Webサーバ（Kestrel）を起動して待ち受け開始