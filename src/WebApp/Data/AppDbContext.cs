using Microsoft.EntityFrameworkCore;

namespace WebApp.Data;

public class AppDbContext : DbContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }

    // ユーザーテーブル
    public DbSet<AppUser> AppUsers => Set<AppUser>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

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
    }
}