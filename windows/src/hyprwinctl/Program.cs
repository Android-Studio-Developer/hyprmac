using Hyprwin.Core;

const string usage = """
hyprwinctl: control hyprwin (like hyprctl)

usage: hyprwinctl [-j] <command> [args]

commands:
  dispatch <dispatcher> [args]   e.g. dispatch workspace 2, dispatch exec start "" wt.exe
  reload                         reload the config
  workspaces | activeworkspace   workspace info
  clients | activewindow         window info
  monitors | binds | version
  configerrors | skippedbinds    config problems / binds that need Linux-only programs
  listen                         print events (workspace>>2, activewindow>>...) until stopped

offline (no running hyprwin needed):
  rice ...                       install/apply dotfiles rices (hyprwinctl rice help)
  check-config [PATH]            parse the config, show skipped binds and errors
  list                           windows hyprwin would manage (moves nothing)
  print-default-config

  -j   JSON output
""";

var list = args.ToList();
bool json = list.Remove("-j");
if (list.Count == 0 || list[0] is "-h" or "--help" or "help")
{
    Console.WriteLine(usage);
    return list.Count == 0 ? 1 : 0;
}

var offline = new Dictionary<string, string>
{
    ["check-config"] = "--check-config", ["list"] = "--list", ["print-default-config"] = "--print-default-config",
};
if (list[0] == "rice" || offline.ContainsKey(list[0]))
{
    LuaConfig.Install();
    var configPath = Environment.GetEnvironmentVariable("HYPRWIN_CONFIG") ?? Config.DefaultPath;
    if (offline.TryGetValue(list[0], out var flag)) list[0] = flag;
    return Hyprwin.Program.RunCli([.. list], configPath);
}

try
{
    if (list[0] == "listen")
    {
        PipeClient.Listen(HyprwinInfo.EventPipeName, Console.WriteLine);
        return 0;
    }
    var reply = PipeClient.Send((json ? "j/" : "") + string.Join(" ", list), HyprwinInfo.PipeName);
    Console.WriteLine(reply);
    bool failed = (list[0] == "dispatch" && reply != "ok") || reply.StartsWith("unknown request");
    return failed ? 1 : 0;
}
catch (IOException e)
{
    Console.Error.WriteLine(e.Message);
    return 1;
}
