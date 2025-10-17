# Data Protection 鍵リングを PostgreSQL に格納して共有する方法

この手順では、`dotnet9-webapp` で使用している Data Protection 鍵（Cookie暗号鍵）を
PostgreSQL に保存して、複数インスタンス間で共有する方法を説明します。

---

## 1. パッケージ追加

```bash
dotnet add src/WebApp/WebApp.csproj package Microsoft.AspNetCore.DataProtection.EntityFrameworkCore
```

---

## 2. エンティティを追加（DataProtectionKey）

既存の `AppDbContext` に `DbSet<DataProtectionKey>` を追加します。

```csharp
using Microsoft.AspNetCore.DataProtection.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore;

namespace WebApp.Data
{
    public class AppDbContext : DbContext, IDataProtectionKeyContext
    {
        public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) {}

        // 既存の DbSet<YourEntities>... に加えて
        public DbSet<DataProtectionKey> DataProtectionKeys { get; set; } = default!;

        protected override void OnModelCreating(ModelBuilder modelBuilder)
        {
            base.OnModelCreating(modelBuilder);

            modelBuilder.Entity<DataProtectionKey>(b =>
            {
                b.ToTable("data_protection_keys");      // テーブル名
                b.HasKey(x => x.Id);
                b.HasIndex(x => x.FriendlyName).IsUnique(false);
            });
        }
    }
}
```

---

## 3. マイグレーション作成＆適用

```bash
# 生成
dotnet ef migrations add AddDataProtectionKeys -p src/WebApp -s src/WebApp

# 適用（ローカル環境で実行）
dotnet ef database update -p src/WebApp -s src/WebApp
```

> 本番では、リリース前にマイグレーションを適用しておくのが安全です。

---

## 4. Program.cs の設定変更

`PersistKeysToFileSystem` を削除し、`PersistKeysToDbContext` に変更します。

```csharp
builder.Services.AddDataProtection()
    .PersistKeysToDbContext<AppDbContext>()          // ← PostgreSQL に保存
    .SetApplicationName("WebApp-Prod");              // ← 環境名を区別（例：WebApp-Stg, WebApp-Prod）
```

---

## 5. 運用上の注意

| 項目 | 内容 |
|------|------|
| **共有範囲** | `SetApplicationName()` が同じインスタンス間で共有される |
| **テーブル構造** | `data_protection_keys` テーブルに XML 形式で格納 |
| **鍵の保護** | XML 内は平文。必要に応じて `ProtectKeysWithCertificate()` 等を利用 |
| **初回生成** | 起動時に DB に自動生成。テーブルが存在しないと失敗 |
| **可用性** | DB 障害時は Cookie の発行/復号ができなくなるため、Aurora Multi-AZ 等で冗長化推奨 |

---

## 6. 最終構成（抜粋）

**Program.cs**
```csharp
builder.Services.AddDbContext<AppDbContext>(opt =>
    opt.UseNpgsql(conn, npgsqlOptions =>
    {
        npgsqlOptions.EnableRetryOnFailure(5, TimeSpan.FromSeconds(10), null);
    })
    .EnableDetailedErrors()
    .EnableSensitiveDataLogging()
);

builder.Services.AddDataProtection()
    .PersistKeysToDbContext<AppDbContext>()   // ★ DB共有
    .SetApplicationName("WebApp-Prod");       // ★ 環境識別
```

**AppDbContext.cs**
```csharp
public class AppDbContext : DbContext, IDataProtectionKeyContext
{
    public DbSet<DataProtectionKey> DataProtectionKeys { get; set; } = default!;

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);
        modelBuilder.Entity<DataProtectionKey>(b =>
        {
            b.ToTable("data_protection_keys");
            b.HasKey(x => x.Id);
        });
    }
}
```

---

## まとめ

| 状況 | 結果 |
|------|------|
| 鍵リングの保存先 | PostgreSQL |
| 鍵の永続化 | DB内で保持（全インスタンス共有） |
| インスタンス間共有 | **可能（同一 ApplicationName に限る）** |
| メリット | Fargate / ECS 環境で自動的に Cookie 鍵が共有され、ログイン維持が安定 |
| デメリット | DB障害時に鍵アクセス不可となるため、可用性と冗長性が前提 |

---

これにより、Fargate などで複数インスタンスを動かしても Cookie 認証が切れなくなります。
