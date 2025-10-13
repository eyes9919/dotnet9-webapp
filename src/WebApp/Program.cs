using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authorization;
using Microsoft.EntityFrameworkCore;
using Microsoft.AspNetCore.DataProtection;
using WebApp.Data;

var builder = WebApplication.CreateBuilder(args);

// Razor Pages 有効化
builder.Services.AddRazorPages();

// HttpContextAccessor 登録（_Layout.cshtml などで使用）
builder.Services.AddHttpContextAccessor();

// DataProtection キー永続化（Cookieエラー防止、開発用）
builder.Services.AddDataProtection()
    .PersistKeysToFileSystem(new DirectoryInfo("/tmp/aspnet-dp-keys"))
    .SetApplicationName("WebApp");

// DB 接続設定
var conn = builder.Configuration.GetConnectionString("Default")
           ?? Environment.GetEnvironmentVariable("ConnectionStrings__Default")
           ?? throw new InvalidOperationException("Connection string not found");

builder.Services.AddDbContext<AppDbContext>(opt =>
    opt.UseNpgsql(conn, npgsqlOptions =>
    {
        npgsqlOptions.EnableRetryOnFailure(
            maxRetryCount: 5,
            maxRetryDelay: TimeSpan.FromSeconds(10),
            errorCodesToAdd: null);
    })
    .EnableDetailedErrors()
    .EnableSensitiveDataLogging()
);

// Cookie 認証設定
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(o =>
    {
        o.LoginPath = "/Login";
        o.AccessDeniedPath = "/Login";
        o.ExpireTimeSpan = TimeSpan.FromHours(8);
    });

// 認可ポリシー（既定は要ログイン）
builder.Services.AddAuthorization(o =>
{
    o.FallbackPolicy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
});

// Razor Pages 認可設定
builder.Services.AddRazorPages(o =>
{
    // 匿名アクセスを許可するページ
    o.Conventions.AllowAnonymousToPage("/Index");
    o.Conventions.AllowAnonymousToPage("/Login");
    o.Conventions.AllowAnonymousToPage("/Privacy");
    o.Conventions.AllowAnonymousToPage("/Links");
    o.Conventions.AllowAnonymousToPage("/Error");
    o.Conventions.AllowAnonymousToPage("/");
});

var app = builder.Build();

// DB マイグレーションと admin 初期化
using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    try
    {
        db.Database.Migrate();

        // admin ユーザーの初期投入または更新
        var adminUser = db.AppUsers.FirstOrDefault(u => u.UserName == "admin");
        var adminPassword = Environment.GetEnvironmentVariable("ADMIN_PASSWORD") ?? "admin123!";

        if (adminUser == null)
        {
            db.AppUsers.Add(new AppUser
            {
                UserName = "admin",
                DisplayName = "Administrator",
                PasswordHash = BCrypt.Net.BCrypt.HashPassword(adminPassword),
                IsAdmin = true
            });
            app.Logger.LogInformation("Seeded new admin user.");
        }
        else
        {
            adminUser.PasswordHash = BCrypt.Net.BCrypt.HashPassword(adminPassword);
            db.AppUsers.Update(adminUser);
            app.Logger.LogInformation("Updated existing admin password.");
        }

        db.SaveChanges();
    }
    catch (Exception ex)
    {
        app.Logger.LogError(ex, "Database migration or seeding failed.");
    }
}

// 例外処理
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseRouting();

// 認証／認可
app.UseAuthentication();
app.UseAuthorization();

// Razor Pages のルートのみマッピング
app.MapRazorPages();

app.Run();