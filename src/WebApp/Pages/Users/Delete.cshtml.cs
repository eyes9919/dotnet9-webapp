using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using WebApp.Data;

namespace WebApp.Pages.AppUsers;

public class DeleteModel : PageModel
{
    private readonly AppDbContext _db;

    public DeleteModel(AppDbContext db)
    {
        _db = db;
    }

    public AppUser? Target { get; set; }

    public async Task<IActionResult> OnGetAsync(int id)
    {
        Target = await _db.AppUsers.FindAsync(id);
        if (Target is null) return NotFound();
        return Page();
    }

    public async Task<IActionResult> OnPostAsync(int id)
    {
        var user = await _db.AppUsers.FindAsync(id);
        if (user is null) return NotFound();

        _db.AppUsers.Remove(user);
        await _db.SaveChangesAsync();
        return RedirectToPage("./Index");
    }
}