# GraniteOS 2 Zig SDK

The SDK compiles third-party apps against the exact typed API used by built-in
programs. The runtime is source-linked into a static, non-PIE AArch64 ELF, so
there is no dynamic loader or library-version ambiguity at install time.

Build the example from the repository root:

```sh
zig build --build-file sdk/build.zig -Dname=hello-granite
```

The stripped release ELF is written under `sdk/zig-out/bin/` (or the install
prefix printed by Zig). Use `-Dsource=path/to/app.zig`; paths are relative to
the SDK directory. Both `@import("granite")` and `@import("lib")` expose:

- typed syscall wrappers and capability handles;
- IPC protocols and service discovery;
- compositor, UI, drawing, input, preferences, and notification APIs;
- filesystem, networking, HTTP, and TLS clients;
- audio, media, time, and utility modules.

Apps must define `pub fn main(args: []const []const u8) u8`. GUI apps should
use `granite.desktop`, `granite.window`, and `granite.wm`, as shown in
`example/app.zig`. The normal installed-app grant set intentionally excludes
raw devices, interrupts, DMA, and privileged kernel authorities.

Edit `package.json`, then publish:

```sh
cd sdk
go run . \
  --repository https://repo.example \
  --elf zig-out/bin/hello-granite
```

The publisher reads `GRANITE_REPO_TOKEN` by default. Use `--token` only when
overriding it for one invocation.

The ABI tag changes when syscall numbers, startup grants, executable layout,
or a required service contract changes incompatibly. Rebuild and republish
against the new SDK when that happens.
