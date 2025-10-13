using System.ComponentModel.DataAnnotations;

namespace WebApp.Data;

public class AppUser
{
    public int Id { get; set; }

    [Required, MaxLength(64)]
    public string UserName { get; set; } = string.Empty;

    [MaxLength(128)]
    public string? DisplayName { get; set; }

    [Required, MaxLength(200)]
    public string PasswordHash { get; set; } = string.Empty;

    public bool IsAdmin { get; set; }

    public DateTime CreatedAtUtc { get; set; } = DateTime.UtcNow;
}