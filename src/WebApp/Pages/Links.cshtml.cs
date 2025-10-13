using Microsoft.AspNetCore.Mvc.RazorPages;
using System.Collections.Generic;

namespace WebApp.Pages;

public class LinksModel : PageModel
{
    public List<LinkItem> Items { get; private set; } = new();

    public void OnGet()
    {
        Items = new List<LinkItem>
        {
            new LinkItem
            {
                Title = "トップページ",
                Url = Url.Content("~/"),
                Description = "アプリのトップ画面（Welcome）",
                RequiresLogin = false
            },
            new LinkItem
            {
                Title = "ログイン",
                Url = Url.Content("~/Login"),
                Description = "ユーザー認証用ページ",
                RequiresLogin = false
            },
            new LinkItem
            {
                Title = "ユーザー一覧",
                Url = Url.Content("~/Users"),
                Description = "登録ユーザーの一覧表示（要ログイン）",
                RequiresLogin = true
            },
            new LinkItem
            {
                Title = "ユーザー追加",
                Url = Url.Content("~/Users/Create"),
                Description = "新しいユーザーの追加（要ログイン）",
                RequiresLogin = true
            }
        };
    }

    public class LinkItem
    {
        public string Title { get; set; } = "";
        public string Url { get; set; } = "";
        public string Description { get; set; } = "";
        public bool RequiresLogin { get; set; }
    }
}