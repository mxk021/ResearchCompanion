using System;
using System.IO;
using System.Threading;
using System.Windows;
using Microsoft.Win32;

namespace ResearchCompanion.Windows;

internal static class App
{
    internal static string Version => typeof(App).Assembly.GetName().Version!.ToString();

    internal static readonly string Profile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ResearchCompanion");
    [STAThread]
    private static void Main()
    {
        using var instance = new Mutex(true, @"Local\ResearchCompanion.Windows", out bool owner);
        if (!owner) return;
        Directory.CreateDirectory(Profile);
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Run(new ResearchWindow());
    }

    internal static bool SystemDark
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
    }
}
