using System.IO.Pipes;
using System.Text;

namespace Hyprwin.Core;

/// <summary>Client side of hyprwin's control pipe (used by hyprwinctl and `hyprwin rice`).</summary>
public static class PipeClient
{
    public static string Send(string request, string pipeName, int timeoutMs = 3000)
    {
        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.CurrentUserOnly);
        try { pipe.Connect(timeoutMs); }
        catch (TimeoutException) { throw new IOException("hyprwin is not running"); }
        var bytes = Encoding.UTF8.GetBytes(request + "\n");
        pipe.Write(bytes);
        pipe.Flush();
        using var reader = new StreamReader(pipe, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    /// <summary>Streams event lines until the pipe closes.</summary>
    public static void Listen(string pipeName, Action<string> onLine)
    {
        using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.In, PipeOptions.CurrentUserOnly);
        try { pipe.Connect(3000); }
        catch (TimeoutException) { throw new IOException("hyprwin is not running"); }
        using var reader = new StreamReader(pipe, Encoding.UTF8);
        while (reader.ReadLine() is { } line) onLine(line);
    }
}
