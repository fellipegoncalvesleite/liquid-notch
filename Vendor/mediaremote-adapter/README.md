# mediaremote-adapter (vendored)

Source of [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) at commit
`0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd`, BSD 3-Clause (see `LICENSE`). Only the adapter's sources (plus the test client's header, which `test.m` imports),
header and Perl script are kept (no test client, no CMake).

MediaRemote answers only Apple's own processes since macOS 15.4. `/usr/bin/perl` is one, so the
adapter is a framework that the Perl script loads into perl, which then streams Now Playing as JSON
lines. `tools/build_adapter.sh` compiles it with clang into `.build/adapter/MediaRemoteAdapter.framework`;
`build_app.sh` embeds the framework in `Contents/Frameworks` and the script in `Contents/Resources`.
This is the app's only private-API use; the Swift side (`Sources/NowPlaying`) only runs the process.
