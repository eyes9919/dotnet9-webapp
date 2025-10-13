using System.Reflection;

namespace WebApp.Utils
{
    public static class VersionInfo
    {
        // `InformationalVersion`（推奨）→ なければ Assembly Version
        public static string AppVersion =>
            Assembly.GetExecutingAssembly()
                    .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
                    .InformationalVersion
            ?? Assembly.GetExecutingAssembly().GetName().Version?.ToString()
            ?? "unknown";

        // ビルド番号などを環境変数から表示（任意）
        public static string BuildLabel =>
            Environment.GetEnvironmentVariable("APP_BUILD") ?? "";
    }
}