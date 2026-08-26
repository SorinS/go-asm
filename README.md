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
- **Runs Linux programs** — `write`, `exit` and `read` are emulated through both
  the x86-64 `syscall` gate and the 32-bit `int 0x80` one, so a hand-written
  hello-world prints its output inline.

## Syntax

**go-asm follows NASM conventions.** Source is NASM/Intel syntax, not GNU as or
MASM, and the assembler is checked against nasm's own output.

The distinctions that catch people out:

| | NASM (what go-asm expects) | Not this |
|---|---|---|
| Comments | `; comment` | `# …`, `// …`, `/* … */` (GNU as / C) |
| Address of a label | `mov rsi, msg` | — |
| Contents at a label | `mov al, [msg]` | MASM's bare `mov al, msg` |
| Operand order | `mov dst, src` | AT&T's `mov src, dst` |
| Registers | `rax`, `eax` | AT&T's `%rax` |
| Immediates | `5`, `0x1f`, `1Fh`, `1010b`, `17o` | AT&T's `$5` |
| Sized memory | `mov byte [x], 1` | `movb` suffixes |

Square brackets mean dereference, and their absence means the address — the
explicitness is deliberate, and it is the main difference from MASM.

Data definitions (`db`/`dw`/`dd`/`dq`), labels with or without a colon,
`section`, `global`, `extern` and `BITS 32` all work as nasm defines them.
`equ` and `$` are not implemented yet.

### What is supported

Everything below is verified against the assembler, not aspirational.

**Directives**

| Supported | Not yet |
|---|---|
| `BITS 32` / `BITS 64` | `org` |
| `section` / `segment` | `times` |
| `global`, `extern` | `align` |
| `default`, `cpu` | `incbin` |
| `equ`, including `equ $-msg` | |

**Preprocessor**

Object-like `%define` only — `%define N 5`, then `N` anywhere afterwards.
Substitution is whole-word and skips string literals, so a macro named `N`
neither rewrites `COUNT` nor the `N` in `db 'N'`. The directive itself is
case-insensitive (`%DEFINE`), as in nasm; macro names are not.

Function-like `%define f(a)`, `%macro`, `%assign`, `%if` and `%include` are not
implemented, and say so rather than failing as a bad operand.

**Expressions**

Full constant expressions: `+ - * / % << >> & | ^ ~` and parentheses, over
literals, symbols, character constants (`'A'`), `$` (here) and `$$` (section
start).

Values track whether they relocate, following nasm: an address moves with the
load address, `end-start` is a length and does not, and adding two addresses is
an error rather than nonsense.

**Data and labels**

- `db` `dw` `dd` `dq`, including strings in single or double quotes, with commas
  and semicolons inside them (`db "hello, world", 10`)
- `resb` `resw` `resd` `resq`
- Labels with a colon (`msg:`) or without (`msg db 1`), local labels (`.loop`),
  and forward references
- A bare label is its address (`mov rsi, msg`); `[msg]` and `[rel msg]` are its
  contents
- Not yet: `dt`/`do`/`dy`/`dz`, and backtick strings with `\n` escapes

**Operands**

- Registers: `rax`–`r15` in all widths (`r8d`, `r8w`, `r8b`), high-byte `ah`/`ch`,
  and `spl`/`bpl`/`sil`/`dil`
- Memory: `[reg]`, `[reg+disp]`, `[base+index*scale+disp]`, `[label]`,
  `[rel label]`, size keywords `byte`/`word`/`dword`/`qword` (`ptr` is accepted
  and ignored), and 32-bit addressing under `BITS 32`
- Immediates: `5`, `0x1f`, `1Fh`, `0b101`, `101b`, `0o17`, `17o`, negatives
- Not yet: segment registers, SSE/AVX registers (`xmm`/`ymm`/`zmm`), the
  `strict` keyword

**Instructions**

Data movement, arithmetic and logic, `jmp`/`jcc` (short and near, chosen the way
nasm chooses), the `loop` family, `call`/`ret`, `push`/`pop`, `setcc`, `cmovcc`,
`imul` in all its forms including nasm's `imul reg, imm` shorthand,
`movzx`/`movsx`, `mul`/`div`, shifts, `bsf`/`bt`, `cpuid`, `hlt`, `syscall`,
`int`, and the `rep`/`lock` prefixes.

Encoding is checked against nasm itself: a sweep assembles every general-purpose
form in nasm's table and compares bytes, currently matching on **86.8%** of
them. The shortfall is almost entirely APX/EVEX/VEX/XOP — recent vector and
extension encodings — rather than classic instructions.

**Running programs**

Linux syscalls are emulated through both the x86-64 `syscall` gate and the
32-bit `int 0x80` gate: `write`, `exit` and `read`. Output appears inline under
the program as you run or step.

A small set of libc entry points is stubbed for `extern` declarations —
`printf`, `puts`, `putchar`, `exit` — covering `%d %i %u %x %X %o %c %s %p %%`,
in both the SysV register convention and 32-bit cdecl. There is no linker: these
are emulated, not linked, and the set is deliberately output-only. Nothing
allocates, reads input, or manipulates strings.

An instruction the encoder does not reach yet is reported as a *hint* rather
than an error, so a coverage gap never paints working code red.

### File extensions

The plugin attaches on Neovim's `asm` and `nasm` filetypes, which between them
cover `.asm`, `.nasm`, `.s` and `.S` — there is no extension list to configure.

Attaching is not the same as understanding, though. `.S` conventionally means
**GNU as** source, a different dialect, so such a file attaches and is then
flagged line by line:

```
line 1: unknown instruction: /*
line 4: unknown instruction: .text
line 5: unknown instruction: .globl
```

That is the dialect being wrong, not the file being broken. GNU as directives
(`.text`, `.globl`, `.byte`, `.asciz`, …) are not implemented on any target,
and on x86 neither is AT&T syntax — `%rax`, reversed operands, `movb` suffixes.

Comment characters, however, do follow each target's own convention:

| Target | Comments accepted |
|---|---|
| x86 / x86-64 | `;` |
| RISC-V | `#`, `;` |
| ARM64 | `//`, leading `#`, `;` |

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
require("go_asm").version  --> "v0.8.0"
```

`:GoAsmInstall` fetches exactly that. Client and server share custom LSP
methods (`asm/run`, `asm/debug/*`), so an arbitrary pairing is not safe — a
mismatch surfaces as requests that fail rather than as anything obviously
version-related, which is why `:checkhealth go_asm` compares the two and warns.

Update both together (your plugin manager, then `:GoAsmInstall`). To deliberately
run a different server, `:GoAsmInstall latest` or `:GoAsmInstall <tag>`.

The server reports its own build too:

```sh
go-asm --version    # go-asm v0.8.0 (abc1234)
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
