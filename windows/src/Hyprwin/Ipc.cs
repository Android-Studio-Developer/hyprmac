using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Text;

namespace Hyprwin;

/// <summary>Request/response pipe: a client writes one line, gets the reply, disconnects.
/// The handler runs on the UI thread.</summary>
sealed class IpcServer(string name, Func<string, string> handler, SynchronizationContext ui)
{
    public void Start() => new Thread(Loop) { IsBackground = true, Name = "hyprwin-ipc" }.Start();

    void Loop()
    {
        while (true)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.CurrentUserOnly);
                pipe.WaitForConnection();
                var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, leaveOpen: true);
                var request = (reader.ReadLine() ?? "").Trim();
                string reply = "";
                ui.Send(_ => reply = handler(request), null);
                var bytes = Encoding.UTF8.GetBytes(reply);
                pipe.Write(bytes);
                pipe.Flush();
                pipe.WaitForPipeDrain();
            }
            catch (IOException) { }
            catch (Exception e)
            {
                Program.Log($"ipc: {e.Message}");
                Thread.Sleep(200);
            }
        }
    }
}

/// <summary>Event stream like Hyprland's socket2: every client gets lines such as "workspace>>2".</summary>
sealed class EventServer(string name)
{
    sealed class Client(NamedPipeServerStream pipe)
    {
        public readonly BlockingCollection<string> Queue = new(boundedCapacity: 1000);
        public readonly NamedPipeServerStream Pipe = pipe;
        public volatile bool Dead;
    }

    readonly List<Client> clients = [];
    readonly Lock gate = new();

    public void Start() => new Thread(Accept) { IsBackground = true, Name = "hyprwin-events" }.Start();

    void Accept()
    {
        while (true)
        {
            try
            {
                var pipe = new NamedPipeServerStream(name, PipeDirection.Out, NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.CurrentUserOnly);
                pipe.WaitForConnection();
                var c = new Client(pipe);
                lock (gate) clients.Add(c);
                new Thread(() => Write(c)) { IsBackground = true }.Start();
            }
            catch (Exception) { Thread.Sleep(200); }
        }
    }

    void Write(Client c)
    {
        try
        {
            foreach (var line in c.Queue.GetConsumingEnumerable())
            {
                var b = Encoding.UTF8.GetBytes(line);
                c.Pipe.Write(b);
                c.Pipe.Flush();
            }
        }
        catch (Exception) { }
        c.Dead = true;
        c.Pipe.Dispose();
        lock (gate) clients.Remove(c);
    }

    public void Emit(string evt, string data)
    {
        var line = $"{evt}>>{data}\n";
        lock (gate)
        {
            foreach (var c in clients)
                if (!c.Dead && !c.Queue.TryAdd(line)) { c.Dead = true; c.Queue.CompleteAdding(); }
        }
    }
}
