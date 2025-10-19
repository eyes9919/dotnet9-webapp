using Microsoft.EntityFrameworkCore;
using Microsoft.AspNetCore.DataProtection.EntityFrameworkCore;
using WebApp.Models;

namespace WebApp.Data;

public class AppDbContext : DbContext, IDataProtectionKeyContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }

    // ユーザーテーブル
    public DbSet<AppUser> AppUsers => Set<AppUser>();

    // Data Protection 鍵リング（Cookie 暗号鍵など）を保持するテーブル
    public DbSet<DataProtectionKey> DataProtectionKeys { get; set; } = default!;

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        // AppUser のマッピング
        modelBuilder.Entity<AppUser>(e =>
        {
            e.ToTable("app_users");
            e.HasKey(x => x.Id);
            e.Property(x => x.Id).ValueGeneratedOnAdd();

            e.Property(x => x.UserName)
                .HasMaxLength(64)
                .IsRequired();
            e.HasIndex(x => x.UserName).IsUnique();

            e.Property(x => x.DisplayName)
                .HasMaxLength(128);

            e.Property(x => x.PasswordHash)
                .HasMaxLength(200)
                .IsRequired();

            e.Property(x => x.IsAdmin).HasDefaultValue(false);
            e.Property(x => x.CreatedAtUtc)
                .HasDefaultValueSql("CURRENT_TIMESTAMP");
        });

        // DataProtectionKey のマッピング
        modelBuilder.Entity<DataProtectionKey>(b =>
        {
            b.ToTable("data_protection_keys");   // テーブル名（PostgreSQL向けにスネークケース）
            b.HasKey(x => x.Id);
            b.HasIndex(x => x.FriendlyName).IsUnique(false);

            // 省略可能だが、念のため制約を付与
            // b.Property(x => x.FriendlyName).HasMaxLength(1024);
            b.Property(x => x.Xml).IsRequired();
        });
    }
}