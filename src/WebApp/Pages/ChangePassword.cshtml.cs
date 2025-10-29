using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using WebApp.Data;              // ← 追加
using WebApp.Models;            // ← 追加
using BCrypt.Net;               // ← 追加（ハッシュ化用）

namespace WebApp.Pages
{
    [Authorize]
    public class ChangePasswordModel : PageModel
    {
        private readonly AppDbContext _db;
        private readonly ILogger<ChangePasswordModel> _logger;

        public ChangePasswordModel(AppDbContext db, ILogger<ChangePasswordModel> logger)
        {
            _db = db;
            _logger = logger;
        }

        public string? SuccessMessage { get; set; }

        [BindProperty]
        public InputModel Input { get; set; } = new InputModel();

        public class InputModel
        {
            [Required]
            [Display(Name = "New password")]
            [StringLength(100, MinimumLength = 8, ErrorMessage = "Password must be at least 8 characters.")]
            public string NewPassword { get; set; } = "";

            [Required]
            [Display(Name = "Confirm password")]
            [Compare("NewPassword", ErrorMessage = "Passwords do not match.")]
            public string ConfirmPassword { get; set; } = "";
        }

        public IActionResult OnGet()
        {
            return Page();
        }

        public IActionResult OnPost()
        {
            if (!ModelState.IsValid)
            {
                return Page();
            }

            try
            {
                // 現在ログインしているユーザー名を取得
                var userName = User?.Identity?.Name;
                if (string.IsNullOrWhiteSpace(userName))
                {
                    _logger.LogWarning("Unauthorized access to ChangePassword.");
                    return RedirectToPage("/Login");
                }

                // 該当ユーザーをDBから取得
                var user = _db.AppUsers.FirstOrDefault(u => u.UserName == userName);
                if (user == null)
                {
                    _logger.LogWarning("User not found for password change: {UserName}", userName);
                    return RedirectToPage("/Login");
                }

                // 新しいパスワードをハッシュ化
                user.PasswordHash = BCrypt.Net.BCrypt.HashPassword(Input.NewPassword);

                // 保存
                _db.AppUsers.Update(user);
                _db.SaveChanges();

                SuccessMessage = "Password updated successfully.";
                _logger.LogInformation("Password updated for user: {UserName}", userName);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error changing password.");
                ModelState.AddModelError(string.Empty, "Unexpected error occurred. Please try again later.");
            }

            return Page();
        }
    }
}