#!/bin/sh
# Runs the unit tests. With only the Command Line Tools installed (no Xcode),
# swift-testing lives outside the default search path, so point the compiler at it.
set -e
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$F/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
