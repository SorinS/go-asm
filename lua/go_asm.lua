-- go_asm.lua — assembly language server + live emulation + stepping debugger.
--
-- The `go-asm` server is a prebuilt binary. `:GoAsmInstall` fetches the release
-- matching this platform; the plugin then resolves it from PATH, the install
-- dir, or the usual ~/bin locations. See README.md.
--
-- Keymaps (normal mode, in an asm buffer), all under <leader>:
--   run:    rr run buffer · rc run to cursor · rg registers · rx clear
--   debug:  rs step · ro step over · rS step back · rR restart
--           rn continue · rq quit · rb breakpoint · rB conditional bp · rm memory
--   K       hover (bytes + decode)

local M = {}
local ns = vim.api.nvim_create_namespace("asm_live") -- run/debug overlay

-- ---------------------------------------------------------------------------
-- Server binary: locating it, and fetching a release build
-- ---------------------------------------------------------------------------

-- repo is the GitHub repo that publishes the go-asm release assets. Point this
-- at a fork to install that fork's builds instead.
M.repo = "SorinS/go-asm"

-- version is the server release this client is built against. :GoAsmInstall
-- fetches exactly this by default: the client and server share custom methods
-- (asm/run, asm/debug/*), so an arbitrary pairing is not safe. Pass "latest"
-- or an explicit tag to override.
M.version = "v0.9.0"

-- max_steps bounds a run so a non-terminating program cannot hang the editor.
-- nil uses the server's default (1,000,000 — about 1.4s for a program that
-- never ends). Raise it for something genuinely long-running.
M.max_steps = nil

-- install_dir is where :GoAsmInstall drops the binary — under nvim's data dir,
-- so it survives plugin reinstalls and needs no privileges or PATH edits.
local function install_dir()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "go-asm", "bin")
end

-- platform returns the "<os>-<arch>" release-asset suffix for this machine, or
-- nil where no build is published.
function M.platform()
  local u = vim.uv.os_uname()
  local os_name = ({ Darwin = "darwin", Linux = "linux", Windows_NT = "windows" })[u.sysname]
  local arch = ({ arm64 = "arm64", aarch64 = "arm64", x86_64 = "amd64", amd64 = "amd64" })[u.machine]
  if not os_name or not arch then return nil end
  return os_name .. "-" .. arch
end

local function is_windows()
  return (M.platform() or ""):match("^windows") ~= nil
end

-- asset_name is the release asset published for a platform. Windows keeps .exe
-- so the download is runnable as-is; everywhere else the asset is .bin and the
-- extension is dropped on install.
local function asset_name(plat)
  return ("go-asm.%s.%s"):format(plat, plat:match("^windows") and "exe" or "bin")
end

-- local_name is what the server is called once installed.
local function local_name()
  return "go-asm" .. (is_windows() and ".exe" or "")
end

-- binary resolves the server: an explicit override, then PATH, then the
-- :GoAsmInstall location, then the usual manual-install dirs. A GUI-launched
-- nvim inherits no shell PATH, so the absolute fallbacks matter.
function M.binary()
  if M.cmd and vim.fn.executable(M.cmd) == 1 then return M.cmd end
  if vim.fn.executable("go-asm") == 1 then return "go-asm" end
  local candidates = { vim.fs.joinpath(install_dir(), local_name()) }
  for _, dir in ipairs({ "~/.local/bin", "~/bin", "~/go/bin" }) do
    candidates[#candidates + 1] = vim.fn.expand(dir .. "/" .. local_name())
  end
  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) == 1 then return path end
  end
  return nil
end

-- server_version runs the resolved binary's --version. Returns nil when the
-- server is missing, predates the flag, or hangs (it would otherwise sit
-- waiting on stdin for LSP traffic).
function M.server_version()
  local bin = M.binary()
  if not bin then return nil end
  local ok, res = pcall(function()
    return vim.system({ bin, "--version" }, { text = true, stdin = false }):wait(2000)
  end)
  if not ok or res.code ~= 0 then return nil end
  return (res.stdout or ""):match("go%-asm%s+(%S+)")
end

-- install downloads the release asset for this platform into install_dir.
-- `tag` defaults to M.version; pass "latest" for the newest release. Safe to
-- re-run; it overwrites.
function M.install(tag)
  local plat = M.platform()
  if not plat then
    local u = vim.uv.os_uname()
    vim.notify(("go-asm: no release build for %s/%s — build from source"):format(u.sysname, u.machine),
      vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable("curl") ~= 1 then
    vim.notify("go-asm: curl is required to install", vim.log.levels.ERROR)
    return
  end
  local asset = asset_name(plat)
  tag = tag or M.version
  local url = (tag == "latest")
      and ("https://github.com/%s/releases/latest/download/%s"):format(M.repo, asset)
      or ("https://github.com/%s/releases/download/%s/%s"):format(M.repo, tag, asset)
  local dest = vim.fs.joinpath(install_dir(), local_name())
  vim.fn.mkdir(install_dir(), "p")
  vim.notify(("go-asm: downloading %s (%s)…"):format(asset, tag))
  -- -f so an HTML 404 page is never written over the binary. --retry-connrefused
  -- because a plain --retry ignores a refused connection; --connect-timeout so a
  -- black-holed network fails instead of hanging on "downloading…"; and the
  -- speed guard to abort a connection that opens and then stalls — under 1 KB/s
  -- for 30s is dead, but the threshold is low enough not to punish a slow link.
  vim.system({ "curl", "-fsSL", "--retry", "3", "--retry-connrefused",
    "--connect-timeout", "10", "--speed-time", "30", "--speed-limit", "1000",
    "-o", dest, url }, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        vim.fn.delete(dest)
        vim.notify(("go-asm: download failed (curl %d) — %s\n%s"):format(res.code, url, res.stderr or ""),
          vim.log.levels.ERROR)
        return
      end
      vim.uv.fs_chmod(dest, 493) -- 0755
      vim.notify("go-asm: installed → " .. dest)
    end)
  end)
end

local function client_for(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = "go-asm" })[1]
end

local function clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr or 0, ns, 0, -1)
end

-- arr normalises a JSON array that the server may send as null. Neovim decodes
-- JSON null to vim.NIL, which is *truthy*, so the usual `x or {}` does not
-- guard it — ipairs then throws "table expected, got userdata". The server
-- sends null for `lines` and `final` when a program fails to assemble.
local function arr(v)
  if v == nil or v == vim.NIL then return {} end
  return v
end

-- nonzero renders the non-zero registers of a list, using the exact hex string
-- the server sends (JSON numbers lose precision above 2^53) and the float
-- interpretation for FP registers.
local function nonzero(regs)
  local parts = {}
  for _, r in ipairs(arr(regs)) do
    if r.hex and r.hex ~= "0x0" then
      parts[#parts + 1] = ("%s=%s"):format(r.name, r.float or r.hex)
    end
  end
  return table.concat(parts, "  ")
end

-- ---------------------------------------------------------------------------
-- Shared toggle-float (used by registers + memory)
-- ---------------------------------------------------------------------------
local float = { win = nil, kind = nil }

local function float_close()
  if float.win and vim.api.nvim_win_is_valid(float.win) then
    vim.api.nvim_win_close(float.win, true)
  end
  float.win, float.kind = nil, nil
end

-- float_open shows lines; pressing the same kind's key again, moving the
-- cursor, or q/<Esc> (when focused) closes it.
local function float_open(kind, lines)
  if float.win and vim.api.nvim_win_is_valid(float.win) and float.kind == kind then
    float_close()
    return
  end
  float_close()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, #l) end
  float.win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor", row = 1, col = 0, width = w + 1, height = #lines,
    style = "minimal", border = "rounded",
  })
  float.kind = kind
  vim.api.nvim_create_autocmd(
    { "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "WinScrolled" },
    { buffer = vim.api.nvim_get_current_buf(), once = true, callback = float_close })
  vim.keymap.set("n", "q", float_close, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", float_close, { buffer = buf, nowait = true })
end

-- ---------------------------------------------------------------------------
-- Registers side panel
-- ---------------------------------------------------------------------------
-- A persistent vertical split rather than a float: registers are something you
-- watch *while* stepping, and a float that closes on cursor movement cannot do
-- that. The panel refreshes from whichever buffer produced the last result.
local reg = { win = nil, buf = nil }

local function reg_visible()
  return reg.win ~= nil and vim.api.nvim_win_is_valid(reg.win)
end

local function reg_close()
  if reg_visible() then vim.api.nvim_win_close(reg.win, true) end
  reg.win = nil
end

-- reg_text renders the register file, or an explanation when nothing has run
-- yet. The empty state has to say what the panel is *for*: a bare list of key
-- hints here reads like the register listing itself, which is the opposite of
-- what it means.
-- reg_name is the buffer's filename, for the panel header. There is one panel
-- for all buffers and it follows whichever last ran, so without a name it can
-- silently show another file's registers.
local function reg_name(bufnr)
  local n = bufnr and vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_buf_get_name(bufnr) or ""
  return n ~= "" and vim.fn.fnamemodify(n, ":t") or "[no name]"
end

local function reg_text(res, name)
  local regs = res and (res.final or res.regs)
  if regs == vim.NIL then regs = nil end
  if not regs or #regs == 0 then
    return {
      "registers — nothing run yet",
      (" %s"):format(name or "?"),
      "",
      "Shows the CPU registers once",
      "the program has run.",
      "",
      "  <leader>rr  run",
      "  <leader>rs  step",
    }
  end
  local lines = {
    ("registers — %s%d"):format(res.arch or "?", res.bits or 0),
    (" %s"):format(name or "?"),
    "",
  }
  for _, r in ipairs(regs) do
    local isFP = r.name:match("^f[tsa]") ~= nil
    if not isFP or (r.hex and r.hex ~= "0x0") then -- all GPRs + non-zero FP regs
      local extra = r.float and ("  = " .. r.float) or ""
      lines[#lines + 1] = ("%-5s %-18s%s"):format(r.name, r.hex or "?", extra)
    end
  end
  return lines
end

local function reg_fill(res, name)
  if not (reg.buf and vim.api.nvim_buf_is_valid(reg.buf)) then return end
  vim.bo[reg.buf].modifiable = true
  vim.api.nvim_buf_set_lines(reg.buf, 0, -1, false, reg_text(res, name))
  vim.bo[reg.buf].modifiable = false
end

-- reg_refresh is called after every run and step so the panel never shows stale
-- state; it is a no-op when the panel is closed.
local function reg_refresh(bufnr)
  if reg_visible() then reg_fill(vim.b[bufnr].asm_last, reg_name(bufnr)) end
end

local function reg_show(bufnr)
  if not (reg.buf and vim.api.nvim_buf_is_valid(reg.buf)) then
    reg.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[reg.buf].buftype = "nofile"
    vim.bo[reg.buf].swapfile = false
    vim.bo[reg.buf].filetype = "go-asm-registers"
    vim.keymap.set("n", "q", reg_close, { buffer = reg.buf, nowait = true })
  end
  reg_fill(vim.b[bufnr].asm_last, reg_name(bufnr))
  -- win = -1 splits the tabpage, giving a full-height sidebar; enter = false
  -- leaves the cursor in the source buffer.
  reg.win = vim.api.nvim_open_win(reg.buf, false, { split = "right", win = -1, width = 36 })
  vim.wo[reg.win].number = false
  vim.wo[reg.win].relativenumber = false
  vim.wo[reg.win].signcolumn = "no"
  vim.wo[reg.win].wrap = false
  vim.wo[reg.win].winfixwidth = true
end

-- output_lines renders what the program wrote via the syscall shim as virtual
-- lines. Control characters are escaped so a stray \r or \t cannot corrupt the
-- display, and a trailing newline is dropped — it is the normal way to end
-- output and an empty final line would just look like a bug.
local function output_lines(out)
  if not out or out == vim.NIL or out == "" then return nil end
  out = out:gsub("\n$", "")
  local lines = {}
  for _, l in ipairs(vim.split(out, "\n", { plain = true })) do
    l = l:gsub("%c", function(c) return ("\\x%02x"):format(c:byte()) end)
    lines[#lines + 1] = { { "  stdout │ ", "Comment" }, { l, "String" } }
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Live run (one-shot)
-- ---------------------------------------------------------------------------
local render_debug -- forward declaration (defined in the debugger section)

-- in_buf reports whether a 0-based line index exists in the buffer. Every line
-- the server sends is checked: an extmark on a line that is not there raises a
-- hard error from nvim_buf_set_extmark, taking down the whole render, and the
-- buffer can legitimately be shorter than the result if it was edited while the
-- request was in flight.
local function in_buf(bufnr, line)
  return type(line) == "number" and line >= 0 and line < vim.api.nvim_buf_line_count(bufnr)
end

local function render(bufnr, result)
  clear(bufnr)
  vim.b[bufnr].asm_last = result
  vim.b[bufnr].asm_render = "run"
  reg_refresh(bufnr)
  local lastLine = -1
  for _, line in ipairs(arr(result.lines)) do
    if in_buf(bufnr, line.line) then
      if line.line > lastLine then lastLine = line.line end
      if line.text and line.text ~= "" then
        vim.api.nvim_buf_set_extmark(bufnr, ns, line.line, 0, {
          virt_text = { { "  " .. line.text, "Comment" } }, virt_text_pos = "eol" })
      end
    end
  end
  if result.stop == "reached-line" and in_buf(bufnr, result.stopLine) then
    vim.api.nvim_buf_set_extmark(bufnr, ns, result.stopLine, 0, {
      virt_text = { { "  ◀ cursor", "DiagnosticHint" } }, virt_text_pos = "eol" })
  end
  if in_buf(bufnr, lastLine) then
    local virt = output_lines(result.output) or {}
    local fin = nonzero(result.final)
    if fin ~= "" then
      virt[#virt + 1] = { { "  ⇒ " .. fin, "String" } }
    end
    if #virt > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lastLine, 0, { virt_lines = virt })
    end
  end
  local lvl = vim.log.levels.INFO
  if result.stop == "fault" or result.stop == "assemble-error" then
    lvl = vim.log.levels.ERROR
  elseif result.stop == "max-steps" or result.stop == "ran-outside-program" then
    lvl = vim.log.levels.WARN
  end
  local msg = ("asm[%s%d]: %s (%d steps)"):format(result.arch or "?", result.bits or 0, result.stop or "?", result.steps or 0)
  if result.stop == "exited" then
    msg = msg .. (" — exit %d"):format(result.exitCode or 0)
  end
  if result.error and result.error ~= "" then msg = msg .. " — " .. result.error end
  vim.notify(msg, lvl)
end

local function run(line)
  local bufnr = vim.api.nvim_get_current_buf()
  local client = client_for(bufnr)
  if not client then
    vim.notify("go-asm: no client attached to this buffer", vim.log.levels.ERROR)
    return
  end
  client:request("asm/run",
    { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, line = line, maxSteps = M.max_steps },
    function(err, result)
      if err then
        vim.notify("asm/run: " .. vim.inspect(err), vim.log.levels.ERROR)
      elseif result then
        render(bufnr, result)
      end
    end, bufnr)
end

function M.run() run(-1) end
function M.run_to_cursor() run(vim.api.nvim_win_get_cursor(0)[1] - 1) end

-- clear toggles the overlay: hide it if shown, restore the last run/step if
-- hidden. (Stepping or running redraws it regardless.)
function M.clear()
  local b = vim.api.nvim_get_current_buf()
  if #vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {}) > 0 then
    clear(b)
    return
  end
  local res = vim.b[b].asm_last
  if not res then
    return
  end
  if vim.b[b].asm_render == "debug" then
    render_debug(b, res)
  else
    render(b, res)
  end
end

-- registers toggles the side panel showing the full register file from the last
-- run (`final`) or the current debug step (`regs`).
function M.registers()
  if reg_visible() then
    reg_close()
    return
  end
  reg_show(vim.api.nvim_get_current_buf())
end

-- ---------------------------------------------------------------------------
-- Stepping debugger
-- ---------------------------------------------------------------------------
local ns_bp = vim.api.nvim_create_namespace("asm_bp")
local breakpoints = {} -- bufnr -> { [line]=true }
local conditions = {}  -- bufnr -> { [line]={reg,op,value} }
local dbg_line = {}    -- bufnr -> last current line

local function bps_for(b) breakpoints[b] = breakpoints[b] or {}; return breakpoints[b] end
local function conds_for(b) conditions[b] = conditions[b] or {}; return conditions[b] end

local function redraw_breakpoints(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_bp, 0, -1)
  for line, on in pairs(bps_for(bufnr)) do
    if on then
      vim.api.nvim_buf_set_extmark(bufnr, ns_bp, line, 0,
        { sign_text = "●", sign_hl_group = "DiagnosticError" })
    end
  end
  for line, c in pairs(conds_for(bufnr)) do
    vim.api.nvim_buf_set_extmark(bufnr, ns_bp, line, 0, {
      sign_text = "◆", sign_hl_group = "DiagnosticWarn",
      virt_text = { { ("  ? %s %s 0x%x"):format(c.reg, c.op, c.value), "DiagnosticWarn" } },
      virt_text_pos = "eol",
    })
  end
end

function M.toggle_breakpoint()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local set = bps_for(bufnr)
  set[line] = (not set[line]) or nil
  redraw_breakpoints(bufnr)
end

-- cond_breakpoint prompts for a "reg op value" condition on the cursor line.
function M.cond_breakpoint()
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local cset = conds_for(bufnr)
  if cset[line] then -- toggle off
    cset[line] = nil
    redraw_breakpoints(bufnr)
    return
  end
  vim.ui.input({ prompt = "Break when (e.g. rcx == 0): " }, function(input)
    if not input or input == "" then return end
    local reg, op, val = input:match("^%s*([%w_]+)%s*([=<>!]+)%s*(.+)%s*$")
    local value = val and tonumber((val:gsub("%s+$", "")))
    if not reg or not value then
      vim.notify("condition must be: <reg> <==|!=|<|>|<=|>=> <value>", vim.log.levels.ERROR)
      return
    end
    cset[line] = { reg = reg, op = op, value = value }
    redraw_breakpoints(bufnr)
    vim.notify(("conditional breakpoint @%d: %s %s 0x%x"):format(line + 1, reg, op, value))
  end)
end

render_debug = function(bufnr, st)
  clear(bufnr)
  vim.b[bufnr].asm_last = st
  vim.b[bufnr].asm_render = "debug"
  reg_refresh(bufnr)
  if st.stop == "assemble-error" then
    vim.notify("go-asm debug: " .. (st.error or "assemble error"), vim.log.levels.ERROR)
    return
  end
  local anchor = st.line
  if in_buf(bufnr, st.line) then
    dbg_line[bufnr] = st.line
    vim.api.nvim_buf_set_extmark(bufnr, ns, st.line, 0, {
      line_hl_group = "Visual",
      virt_text = { { "  ▶ step " .. (st.steps or 0), "DiagnosticInfo" } },
      virt_text_pos = "eol",
    })
    -- st.output is everything written so far, not just this step, so the
    -- panel shows the program's output accumulating as you step.
    local virt = output_lines(st.output) or {}
    local regs = nonzero(st.regs)
    if regs ~= "" then
      virt[#virt + 1] = { { "    " .. regs, "Comment" } }
    end
    if #virt > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, st.line, 0, { virt_lines = virt })
    end
    pcall(vim.api.nvim_win_set_cursor, 0, { st.line + 1, 0 })
  else
    anchor = dbg_line[bufnr]
    if in_buf(bufnr, anchor) then
      local virt = output_lines(st.output) or {}
      local regs = nonzero(st.regs)
      if regs ~= "" then
        virt[#virt + 1] = { { "  ⇒ " .. regs, "String" } }
      end
      if #virt > 0 then
        vim.api.nvim_buf_set_extmark(bufnr, ns, anchor, 0, { virt_lines = virt })
      end
    end
  end
  local lvl = (st.stop == "fault") and vim.log.levels.ERROR or vim.log.levels.INFO
  local tail = (st.stop ~= "" and st.stop) or ("at line " .. ((st.line or 0) + 1))
  vim.notify(("debug[%s%d]: %s (step %d)"):format(st.arch or "?", st.bits or 0, tail, st.steps or 0), lvl)
end

local function dbg(method, extra)
  local bufnr = vim.api.nvim_get_current_buf()
  local client = client_for(bufnr)
  if not client then
    vim.notify("go-asm: no client attached to this buffer", vim.log.levels.ERROR)
    return
  end
  local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
  for k, v in pairs(extra or {}) do params[k] = v end
  client:request(method, params, function(err, state)
    if err then
      vim.notify(method .. ": " .. vim.inspect(err), vim.log.levels.ERROR)
    elseif state then
      render_debug(bufnr, state)
    end
  end, bufnr)
end

function M.dbg_step() dbg("asm/debug/step") end
function M.dbg_stepover() dbg("asm/debug/stepover") end
function M.dbg_stepback() dbg("asm/debug/stepback") end
function M.dbg_restart() dbg("asm/debug/restart") end

function M.dbg_continue()
  local bufnr = vim.api.nvim_get_current_buf()
  local bps, conds = {}, {}
  for line, on in pairs(bps_for(bufnr)) do
    if on then bps[#bps + 1] = line end
  end
  for line, c in pairs(conds_for(bufnr)) do
    conds[#conds + 1] = { line = line, reg = c.reg, op = c.op, value = c.value }
  end
  dbg("asm/debug/continue", { breakpoints = bps, conditions = conds })
end

function M.dbg_stop()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = client_for(bufnr)
  if client then
    client:request("asm/debug/stop", { textDocument = { uri = vim.uri_from_bufnr(bufnr) } },
      function() end, bufnr)
  end
  dbg_line[bufnr] = nil
  clear(bufnr)
end

-- memory: prompt for an address (register name or 0xADDR) and hex-dump it.
local function resolve_addr(bufnr, s)
  s = s:gsub("%s+", "")
  local n = tonumber(s)
  if n then return n end
  local res = vim.b[bufnr].asm_last
  for _, key in ipairs({ "regs", "final" }) do
    for _, r in ipairs(arr((res or {})[key])) do
      if r.name == s then return r.value end
    end
  end
  return nil
end

function M.memory()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = client_for(bufnr)
  if not client then
    vim.notify("go-asm: no client attached", vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = "Memory at (reg or 0xADDR): " }, function(input)
    if not input or input == "" then return end
    local addr = resolve_addr(bufnr, input)
    if not addr then
      vim.notify("go-asm: unknown address " .. input .. " (run/step first to resolve a register)", vim.log.levels.ERROR)
      return
    end
    client:request("asm/debug/memory",
      { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, addr = addr, count = 64 },
      function(err, res)
        if err or not res then
          vim.notify("asm/debug/memory: " .. vim.inspect(err), vim.log.levels.ERROR)
          return
        end
        if res.error and res.error ~= "" then
          vim.notify("go-asm: " .. res.error, vim.log.levels.WARN)
          return
        end
        local lines = { ("memory @ 0x%x  (q/Esc/move to close)"):format(res.addr) }
        local bytes = arr(res.bytes)
        for row = 0, #bytes - 1, 16 do
          local hex, asc = "", ""
          for i = 0, 15 do
            local b = bytes[row + i + 1]
            if b then
              hex = hex .. ("%02x "):format(b)
              asc = asc .. ((b >= 32 and b < 127) and string.char(b) or ".")
            end
          end
          lines[#lines + 1] = (" 0x%08x: %-48s %s"):format(res.addr + row, hex, asc)
        end
        float_open("mem", lines)
      end, bufnr)
  end)
end

-- ---------------------------------------------------------------------------
-- One-time setup: filetype, server start, keymaps.
-- ---------------------------------------------------------------------------
if not vim.g.go_asm_loaded then
  vim.g.go_asm_loaded = true

  vim.filetype.add({ extension = { asm = "asm", nasm = "nasm" } })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = { "asm", "nasm" },
    callback = function(args)
      local cmd = M.binary()
      if not cmd then
        vim.notify("go-asm: server binary not found — run :GoAsmInstall", vim.log.levels.ERROR)
        return
      end
      vim.lsp.start({ name = "go-asm", cmd = { cmd }, root_dir = vim.fs.dirname(args.file) })
    end,
  })

  vim.api.nvim_create_user_command("GoAsmInstall", function(o)
    M.install(o.args ~= "" and o.args or nil)
  end, { nargs = "?", desc = "Download the go-asm server ([tag] | latest)" })
  vim.api.nvim_create_user_command("GoAsmInfo", function()
    local bin = M.binary()
    local have = M.server_version()
    vim.notify(("plugin:   %s\nserver:   %s\nbinary:   %s\nplatform: %s\nrepo:     %s"):format(
      M.version, have or "unknown", bin or "NOT FOUND (run :GoAsmInstall)",
      M.platform() or "unsupported", M.repo))
  end, { desc = "Show the resolved go-asm binary, version and platform" })

  vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
      local c = vim.lsp.get_client_by_id(args.data.client_id)
      if c and c.name == "go-asm" then
        local function map(lhs, fn, desc)
          vim.keymap.set("n", lhs, fn, { buffer = args.buf, desc = desc })
        end
        -- run
        map("<leader>rr", M.run, "asm: run buffer")
        map("<leader>rc", M.run_to_cursor, "asm: run to cursor")
        map("<leader>rg", M.registers, "asm: registers")
        map("<leader>rx", M.clear, "asm: clear overlay")
        -- debug
        map("<leader>rs", M.dbg_step, "asm: step")
        map("<leader>ro", M.dbg_stepover, "asm: step over")
        map("<leader>rS", M.dbg_stepback, "asm: step back")
        map("<leader>rR", M.dbg_restart, "asm: restart")
        map("<leader>rn", M.dbg_continue, "asm: continue")
        map("<leader>rq", M.dbg_stop, "asm: quit debug")
        map("<leader>rb", M.toggle_breakpoint, "asm: breakpoint")
        map("<leader>rB", M.cond_breakpoint, "asm: conditional breakpoint")
        map("<leader>rm", M.memory, "asm: memory")
      end
    end,
  })
end

return M
