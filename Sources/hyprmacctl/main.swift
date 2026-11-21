import Foundation
import HyprmacCore

let usage = """
hyprmacctl: control hyprmac (like hyprctl)

usage: hyprmacctl [-j] <command> [args]

commands:
  dispatch <dispatcher> [args]   e.g. dispatch workspace 2, dispatch exec open -a Safari
  reload                         reload the config
  workspaces | activeworkspace   workspace info
  clients | activewindow         window info
  monitors | binds | version
  configerrors                   problems in the config
  listen                         print events (workspace>>2, activewindow>>...) until stopped

  -j   JSON output

tip: alias hyprctl=hyprmacctl
"""

var args = Array(CommandLine.arguments.dropFirst())
var json = false
if let i = args.firstIndex(of: "-j") {
    json = true
    args.remove(at: i)
}
guard let cmd = args.first, cmd != "-h", cmd != "--help", cmd != "help" else {
    print(usage)
    exit(args.isEmpty ? 1 : 0)
}

let uid = getuid()

if cmd == "listen" {
    do {
        let fd = try Control.connect(HyprmacInfo.eventSocketPath(uid: uid))
        setvbuf(stdout, nil, _IOLBF, 0)
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            FileHandle.standardOutput.write(Data(buf[0..<n]))
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

let request = (json ? "j/" : "") + args.joined(separator: " ")
do {
    let reply = try Control.send(request, socket: HyprmacInfo.socketPath(uid: uid))
    print(reply)
    let failed = cmd == "dispatch" && reply != "ok"
    exit(failed || reply.hasPrefix("unknown request") ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
