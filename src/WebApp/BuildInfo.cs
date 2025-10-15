using System.Reflection;

namespace WebApp.Models;

/// <summary>
/// ビルド時のバージョン情報と日時を格納するモデル。
/// GitHub Actions やローカルビルドで環境変数により注入される。
/// </summary>
public sealed class BuildInfo
{
    /// <summary>
    /// アプリのバージョン文字列（例: v0.1.0+build123）。
    /// </summary>
    public string Version { get; init; } = "v0.1.0";

    /// <summary>
    /// ビルド時刻（UTC ISO8601形式）。
    /// </summary>
    public string BuildTime { get; init; } = "unknown";

    public BuildInfo()
    {
        // Assemblyに埋め込まれた情報があればそれを使用
        var asm = Assembly.GetExecutingAssembly();
        Version = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                  ?? Environment.GetEnvironmentVariable("APP_VERSION")
                  ?? "v0.1.0";

        BuildTime = asm.GetCustomAttributes<AssemblyMetadataAttribute>()
                       .FirstOrDefault(a => a.Key == "BuildTime")?.Value
                    ?? Environment.GetEnvironmentVariable("BUILD_TIME")
                    ?? "unknown";
    }
}