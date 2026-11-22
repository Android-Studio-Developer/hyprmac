namespace Hyprwin.Shell;

/// <summary>What the shell needs from the window manager.</summary>
public interface IShellBackend
{
    ShellState State { get; }
    /// <summary>Raised on the UI thread when workspaces, focus or titles change.</summary>
    event Action? Changed;
    /// <summary>Runs a Hyprland dispatcher; returns an error or null.</summary>
    string? Dispatch(string dispatcher, string arg);
    void Exec(string command);
    void Quit();
}

public sealed record ShellState(
    int Workspace,
    IReadOnlyList<int> Occupied,
    string ActiveApp,
    string ActiveTitle);

public sealed record ShellOptions(bool HideTaskbar, string Scheme, double FrameThickness = 10, double BarWidth = 52);
