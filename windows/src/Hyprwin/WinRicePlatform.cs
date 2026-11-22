using System.Diagnostics;
using System.Text;
using Hyprwin.Core;

namespace Hyprwin;

/// <summary>Windows side of `hyprwin rice`: junctions, file links, wallpaper, git.</summary>
sealed class WinRicePlatform : IRicePlatform
{
    static string Folder(Environment.SpecialFolder f) => Environment.GetFolderPath(f);

    public RiceKind Classify(string name, out string? target) =>
        RiceCatalog.ClassifyWindows(name, Folder(Environment.SpecialFolder.UserProfile),
            Folder(Environment.SpecialFolder.ApplicationData), Folder(Environment.SpecialFolder.LocalApplicationData), out target);

    /// <summary>Directory junction: works without admin rights or Developer Mode.</summary>
    public void LinkDirectory(string link, string target)
    {
        var r = Run("cmd.exe", "/d", "/c", "mklink", "/J", link, target);
        if (r != 0 || !Directory.Exists(link)) throw new IOException($"cannot create junction {link}");
    }

    /// <summary>Symlink when allowed (Developer Mode / admin), otherwise a copy (removed on `rice off`).</summary>
    public bool LinkFile(string link, string target)
    {
        try
        {
            File.CreateSymbolicLink(link, target);
            return false;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        File.Copy(target, link);
        return true;
    }

    public string? GetWallpaper()
    {
        var sb = new StringBuilder(520);
        return Native.SystemParametersInfoW(Native.SPI_GETDESKWALLPAPER, (uint)sb.Capacity, sb, 0) && sb.Length > 0 ? sb.ToString() : null;
    }

    public void SetWallpaper(string path) =>
        Native.SystemParametersInfoSet(Native.SPI_SETDESKWALLPAPER, 0, Path.GetFullPath(path), Native.SPIF_UPDATEINIFILE | Native.SPIF_SENDCHANGE);

    public void Git(params string[] args)
    {
        int r;
        try { r = Run("git", args); }
        catch (System.ComponentModel.Win32Exception)
        {
            throw new RiceException("git not found. Install it: winget install Git.Git");
        }
        if (r != 0) throw new RiceException($"git {args.FirstOrDefault()} failed");
    }

    static int Run(string exe, params string[] args)
    {
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        p.WaitForExit();
        return p.ExitCode;
    }
}
