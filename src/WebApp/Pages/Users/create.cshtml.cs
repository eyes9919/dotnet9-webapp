using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using WebApp.Data;
using BCryptNet = BCrypt.Net.BCrypt;

namespace WebApp.Pages.AppUsers;

public class CreateModel : PageModel
{
    private readonly AppDbContext _db;

    public CreateModel(AppDbContext db)
    {
        _db = db;
    }

    [BindProperty]
    public string InputUserName { get; set; } = string.Empty;

    [BindProperty]
    public string InputDisplayName { get; set; } = string.Empty;

    [BindProperty]
    public string InputPassword { get; set; } = string.Empty;

    [BindProperty]
    public bool InputIsAdmin { get; set; }

    public void OnGet() { }

    public async Task<IActionResult> OnPostAsync()
    {
        if (!ModelState.IsValid)
        {
            return Page();
        }

        if (string.IsNullOrWhiteSpace(InputUserName) ||
            string.IsNullOrWhiteSpace(InputDisplayName) ||
            string.IsNullOrWhiteSpace(InputPassword))
        {
            ModelState.AddModelError(string.Empty, "必須項目を入力してください。");
            return Page();
        }

        var entity = new AppUser
        {
            UserName = InputUserName.Trim(),
            DisplayName = InputDisplayName.Trim(),
            PasswordHash = BCryptNet.HashPassword(InputPassword),
            IsAdmin = InputIsAdmin
        };

        _db.AppUsers.Add(entity);
        await _db.SaveChangesAsync();

        return RedirectToPage("./Index");
    }
}