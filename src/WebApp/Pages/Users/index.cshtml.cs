using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.EntityFrameworkCore;
using WebApp.Data;

namespace WebApp.Pages.AppUsers;

public class IndexModel : PageModel
{
    private readonly AppDbContext _db;

    public IndexModel(AppDbContext db)
    {
        _db = db;
    }

    public IList<AppUser> Items { get; set; } = new List<AppUser>();

    public async Task OnGetAsync()
    {
        Items = await _db.AppUsers
            .OrderBy(u => u.UserName)
            .ToListAsync();
    }
}