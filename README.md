# go-asm.nvim

A Neovim client for **go-asm**, a language server for NASM/Intel-syntax
assembly that not only checks your code but *runs* it — assembling each line
live, executing it in an emulator, and showing register state inline as virtual
text. It targets x86-64, 32-bit x86 (`BITS 32`) and RISC-V (RV64I+M+A+Zicsr),
auto-detected per buffer.

- **Diagnostics** — every line assembled on change; unknown mnemonics are
  errors, unencoded-but-valid instructions are hints, so a coverage gap never
  paints working code red.
- **Hover** — encoded bytes (`48 89 d8`, 3 bytes) plus matching operand forms.
- **Completion & signature help** — mnemonics by prefix, operand forms as you type.
- **Live run** — execute the buffer, see per-line effects and final registers.
- **Stepping debugger** — step / step-over / step-back, breakpoints, conditional
  breakpoints, memory dump.

## Requirements

- Neovim **0.11+**
- `curl` (only for `:GoAsmInstall`)

The server itself is a prebuilt, dependency-free static binary — no Go
toolchain needed.

## Install

The server binary is distributed via
[GitHub Releases](https://github.com/SorinS/go-asm/releases). `:GoAsmInstall`
fetches the build for your platform into `stdpath("data")/go-asm/bin`, so it
needs no `sudo` and no `PATH` changes.

### lazy.nvim

```lua
{
  "SorinS/go-asm",
  lazy = false,
  build = ":GoAsmInstall",
  config = function() require("go_asm") end,
}
```

Loading eagerly is deliberate. `require("go_asm")` only registers two autocommands
and two commands — no server starts until you open an `.asm` file — while
lazy-loading on `ft` would leave `:GoAsmInstall`, `:GoAsmInfo` and
`:checkhealth go_asm` undefined until then, which is precisely when you need
them if something is wrong.

### packer.nvim

```lua
use {
  "SorinS/go-asm",
  run = ":GoAsmInstall",
  config = function() require("go_asm") end,
}
```

### Manual

```sh
git clone https://github.com/SorinS/go-asm \
  ~/.local/share/nvim/site/pack/plugins/start/go-asm
```

```lua
-- init.lua
require("go_asm")
```

Then run `:GoAsmInstall` once.

Open any `.asm` file and press `<leader>rr`.

## Keymaps

Set on the buffer when the server attaches — no global bindings.

| Key | Action | | Key | Action |
|---|---|---|---|---|
| `<leader>rr` | run buffer | | `<leader>rs` | step |
| `<leader>rc` | run to cursor | | `<leader>ro` | step over |
| `<leader>rg` | registers panel (toggle) | | `<leader>rS` | step back |
| `<leader>rx` | toggle overlay | | `<leader>rR` | restart |
| `K` | hover — bytes + decode | | `<leader>rn` | continue |
| | | | `<leader>rq` | quit debug |
| | | | `<leader>rb` | breakpoint |
| | | | `<leader>rB` | conditional breakpoint |
| | | | `<leader>rm` | memory dump |

A conditional breakpoint prompts for `<reg> <op> <value>`, e.g. `rcx == 0`.

## Commands

| Command | Description |
|---|---|
| `:GoAsmInstall` | Download the server version this plugin expects |
| `:GoAsmInstall latest` | Download the newest release instead |
| `:GoAsmInstall v0.1.0` | Download a specific release |
| `:GoAsmInfo` | Show the resolved binary, its version and the platform |
| `:checkhealth go_asm` | Diagnose install and version problems |

## Versioning

The plugin and the server are released together under one tag, and the plugin
pins the server build it was written against:

```lua
require("go_asm").version  --> "v0.6.0"
```

`:GoAsmInstall` fetches exactly that. Client and server share custom LSP
methods (`asm/run`, `asm/debug/*`), so an arbitrary pairing is not safe — a
mismatch surfaces as requests that fail rather than as anything obviously
version-related, which is why `:checkhealth go_asm` compares the two and warns.

Update both together (your plugin manager, then `:GoAsmInstall`). To deliberately
run a different server, `:GoAsmInstall latest` or `:GoAsmInstall <tag>`.

The server reports its own build too:

```sh
go-asm --version    # go-asm v0.6.0 (abc1234)
```

## Configuration

There is nothing to configure for normal use. Two fields on the module act as
escape hatches, set **before** the server starts (i.e. before opening an `.asm`
buffer):

```lua
local go_asm = require("go_asm")
go_asm.cmd     = "/path/to/go-asm"  -- use a specific binary (e.g. a local build)
go_asm.repo    = "you/your-fork"    -- install from a fork's releases
go_asm.version = "v0.1.0"           -- pin a different server release
```

The binary is resolved in this order: `go_asm.cmd` → `PATH` →
`stdpath("data")/go-asm/bin` → `~/.local/bin` → `~/bin` → `~/go/bin`. The
absolute fallbacks matter because a GUI-launched Neovim inherits no shell
`PATH`.

To rebind, map to the module functions directly — `require("go_asm").run()`,
`.run_to_cursor()`, `.registers()`, `.clear()`, `.dbg_step()`, `.dbg_stepover()`,
`.dbg_stepback()`, `.dbg_restart()`, `.dbg_continue()`, `.dbg_stop()`,
`.toggle_breakpoint()`, `.cond_breakpoint()`, `.memory()`.

## Supported platforms

`darwin-arm64`, `darwin-amd64`, `linux-amd64`, `linux-arm64`, `windows-amd64`.

Every release ships a `SHA256SUMS` file, so a download can be verified:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
```

On a platform with no published build, open an issue.

## Protocol

Beyond standard LSP, the server implements custom requests: `asm/run` and
`asm/debug/{start,step,stepover,stepback,continue,restart,memory,stop}`.

## License

MIT — see [LICENSE](LICENSE).

The `go-asm` server ships as a binary under the same terms. It is original
work, apart from its RISC-V core and parts of its memory subsystem, which are
inherited from [tinyemu-go](https://github.com/jtolio) and ultimately from
Fabrice Bellard's TinyEMU, also MIT. Full notices ship as `LICENSE.txt` with
each release asset.
