using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.EntityFrameworkCore;
using WebApp.Data;          // ← DbContext

namespace WebApp.Pages
{
    public class LoginModel : PageModel
    {
        private readonly AppDbContext _db;

        public LoginModel(AppDbContext db)
        {
            _db = db;
        }

        [BindProperty]
        public InputModel Input { get; set; } = new();

        public string? ErrorMessage { get; set; }
        public string? ReturnUrl { get; set; }

        public class InputModel
        {
            public string UserName { get; set; } = string.Empty;
            public string Password { get; set; } = string.Empty;
        }

        public void OnGet(string? returnUrl = null)
        {
            // ループ防止：ローカルURLのみ許可、未指定ならTOP
            if (!string.IsNullOrEmpty(returnUrl) && Url.IsLocalUrl(returnUrl))
                ReturnUrl = returnUrl;
            else
                ReturnUrl = "/";
        }

        public async Task<IActionResult> OnPostAsync(string? returnUrl = null)
        {
            // ループ防止
            if (!string.IsNullOrEmpty(returnUrl) && Url.IsLocalUrl(returnUrl))
                ReturnUrl = returnUrl;
            else
                ReturnUrl = "/";

            if (!ModelState.IsValid)
            {
                ErrorMessage = "入力内容を確認してください。";
                return Page();
            }

            // ★ ここを AppUsers に修正
            var user = await _db.AppUsers
                .AsNoTracking()
                .SingleOrDefaultAsync(u => u.UserName == Input.UserName);

            if (user == null || !BCrypt.Net.BCrypt.Verify(Input.Password, user.PasswordHash))
            {
                ErrorMessage = "ユーザー名またはパスワードが正しくありません。";
                return Page();
            }

            var claims = new List<Claim>
            {
                new Claim(ClaimTypes.Name, user.UserName),
                new Claim("DisplayName", user.DisplayName ?? user.UserName),
                new Claim(ClaimTypes.Role, user.IsAdmin ? "Admin" : "User")
            };

            var identity = new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme);
            var principal = new ClaimsPrincipal(identity);

            await HttpContext.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, principal,
                new AuthenticationProperties
                {
                    IsPersistent = true,
                    ExpiresUtc = DateTimeOffset.UtcNow.AddHours(8)
                });

            // ログイン後は Users 一覧をデフォルトに（要望反映）
            var fallback = "/Users";
            return LocalRedirect(Url.IsLocalUrl(ReturnUrl) ? ReturnUrl! : fallback);
        }
    }
}