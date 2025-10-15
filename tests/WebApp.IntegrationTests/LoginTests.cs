using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Threading.Tasks;
using FluentAssertions;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace WebApp.IntegrationTests;

public class LoginTests : IClassFixture<WebAppFactory>
{
    private readonly WebAppFactory _factory;

    public LoginTests(WebAppFactory factory)
    {
        _factory = factory;
    }

    [Fact]
    public async Task Login_As_Admin_Should_RedirectToHome()
    {
        // NOTE: フォームのinput nameはアプリ側に合わせて下さい。
        // もし "UserId" / "Password" でない場合は下の2行を修正。
        var user = "admin";
        var pass = System.Environment.GetEnvironmentVariable("ADMIN_PASSWORD") ?? "admin123!";

        var client = _factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            AllowAutoRedirect = false  // ログイン成功時の 302 を検出するため
        });

        var content = new StringContent($"UserId={Uri.EscapeDataString(user)}&Password={Uri.EscapeDataString(pass)}",
            Encoding.UTF8, "application/x-www-form-urlencoded");

        var res = await client.PostAsync("/Login", content);

        // 成功なら 302（あるいは 303/301）でログイン後ページへリダイレクト想定
        res.StatusCode.Should().BeOneOf(HttpStatusCode.Redirect, HttpStatusCode.SeeOther, HttpStatusCode.Moved);

        // Locationヘッダの存在もチェック
        res.Headers.Location.Should().NotBeNull();
    }
}

/// <summary>
/// WebApp 用の TestServer ファクトリ。
/// コンフィグは環境変数経由で既定の接続文字列/ADMIN_PASSWORDを渡せます。
/// </summary>
public class WebAppFactory : WebApplicationFactory<Program>
{
    protected override IHost CreateHost(IHostBuilder builder)
    {
        // 必要に応じてテスト時の環境変数をここで上書き可能
        // 例：ConnectionStrings__Default が必須起動ならCI側で設定済み

        return base.CreateHost(builder);
    }
}
