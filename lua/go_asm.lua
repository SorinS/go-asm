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

local function exe(path)
  return path .. ((M.platform() or ""):match("^windows") and ".exe" or "")
end

-- binary resolves the server: an explicit override, then PATH, then the
-- :GoAsmInstall location, then the usual manual-install dirs. A GUI-launched
-- nvim inherits no shell PATH, so the absolute fallbacks matter.
function M.binary()
  if M.cmd and vim.fn.executable(M.cmd) == 1 then return M.cmd end
  if vim.fn.executable("go-asm") == 1 then return "go-asm" end
  local candidates = { exe(vim.fs.joinpath(install_dir(), "go-asm")) }
  for _, dir in ipairs({ "~/.local/bin", "~/bin", "~/go/bin" }) do
    candidates[#candidates + 1] = exe(vim.fn.expand(dir .. "/go-asm"))
  end
  for _, path in ipairs(candidates) do
    if vim.fn.executable(path) == 1 then return path end
  end
  return nil
end

-- install downloads the release asset for this platform into install_dir.
-- `tag` defaults to the latest release. Safe to re-run; it overwrites.
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
  local asset = exe("go-asm-" .. plat)
  local url = tag
      and ("https://github.com/%s/releases/download/%s/%s"):format(M.repo, tag, asset)
      or ("https://github.com/%s/releases/latest/download/%s"):format(M.repo, asset)
  local dest = exe(vim.fs.joinpath(install_dir(), "go-asm"))
  vim.fn.mkdir(install_dir(), "p")
  vim.notify("go-asm: downloading " .. asset .. "…")
  -- -f so an HTML 404 page is never written over the binary.
  vim.system({ "curl", "-fsSL", "--retry", "2", "-o", dest, url }, { text = true }, function(res)
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

-- nonzero renders the non-zero registers of a list, using the exact hex string
-- the server sends (JSON numbers lose precision above 2^53) and the float
-- interpretation for FP registers.
local function nonzero(regs)
  local parts = {}
  for _, r in ipairs(regs or {}) do
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
-- Live run (one-shot)
-- ---------------------------------------------------------------------------
local render_debug -- forward declaration (defined in the debugger section)

local function render(bufnr, result)
  clear(bufnr)
  vim.b[bufnr].asm_last = result
  vim.b[bufnr].asm_render = "run"
  local lastLine = -1
  for _, line in ipairs(result.lines or {}) do
    if line.line > lastLine then lastLine = line.line end
    if line.text and line.text ~= "" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, line.line, 0, {
        virt_text = { { "  " .. line.text, "Comment" } }, virt_text_pos = "eol" })
    end
  end
  if result.stop == "reached-line" and result.stopLine and result.stopLine >= 0 then
    vim.api.nvim_buf_set_extmark(bufnr, ns, result.stopLine, 0, {
      virt_text = { { "  ◀ cursor", "DiagnosticHint" } }, virt_text_pos = "eol" })
  end
  if lastLine >= 0 then
    local fin = nonzero(result.final)
    if fin ~= "" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, lastLine, 0,
        { virt_lines = { { { "  ⇒ " .. fin, "String" } } } })
    end
  end
  local lvl = vim.log.levels.INFO
  if result.stop == "fault" or result.stop == "assemble-error" then
    lvl = vim.log.levels.ERROR
  elseif result.stop == "max-steps" or result.stop == "ran-outside-program" then
    lvl = vim.log.levels.WARN
  end
  local msg = ("asm[%s%d]: %s (%d steps)"):format(result.arch or "?", result.bits or 0, result.stop or "?", result.steps or 0)
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
  client:request("asm/run", { textDocument = { uri = vim.uri_from_bufnr(bufnr) }, line = line },
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

-- registers: float with the full register file from the last run (`final`) or
-- the current debug step (`regs`).
function M.registers()
  local res = vim.b[vim.api.nvim_get_current_buf()].asm_last
  local regs = res and (res.final or res.regs)
  if not regs then
    vim.notify("go-asm: run (<leader>rr) or step (<leader>rs) first", vim.log.levels.WARN)
    return
  end
  local lines = { ("registers — %s%d  (q/Esc/move to close)"):format(res.arch or "?", res.bits or 0) }
  for _, r in ipairs(regs) do
    local isFP = r.name:match("^f[tsa]") ~= nil
    if not isFP or (r.hex and r.hex ~= "0x0") then -- show all GPRs + non-zero FP regs
      local extra = r.float and ("  = " .. r.float) or ""
      lines[#lines + 1] = ("  %-5s %-18s%s"):format(r.name, r.hex or "?", extra)
    end
  end
  float_open("reg", lines)
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
  if st.stop == "assemble-error" then
    vim.notify("go-asm debug: " .. (st.error or "assemble error"), vim.log.levels.ERROR)
    return
  end
  local anchor = st.line
  if st.line and st.line >= 0 then
    dbg_line[bufnr] = st.line
    vim.api.nvim_buf_set_extmark(bufnr, ns, st.line, 0, {
      line_hl_group = "Visual",
      virt_text = { { "  ▶ step " .. (st.steps or 0), "DiagnosticInfo" } },
      virt_text_pos = "eol",
    })
    local regs = nonzero(st.regs)
    if regs ~= "" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, st.line, 0,
        { virt_lines = { { { "    " .. regs, "Comment" } } } })
    end
    pcall(vim.api.nvim_win_set_cursor, 0, { st.line + 1, 0 })
  else
    anchor = dbg_line[bufnr]
    if anchor then
      local regs = nonzero(st.regs)
      if regs ~= "" then
        vim.api.nvim_buf_set_extmark(bufnr, ns, anchor, 0,
          { virt_lines = { { { "  ⇒ " .. regs, "String" } } } })
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
    for _, r in ipairs((res or {})[key] or {}) do
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
        local bytes = res.bytes or {}
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

  vim.api.nvim_create_user_command("GoAsmInstall", function() M.install() end,
    { desc = "Download the go-asm server for this platform" })
  vim.api.nvim_create_user_command("GoAsmInfo", function()
    local bin = M.binary()
    vim.notify(("go-asm: %s\nplatform: %s\nrepo: %s"):format(
      bin or "NOT FOUND (run :GoAsmInstall)", M.platform() or "unsupported", M.repo))
  end, { desc = "Show the resolved go-asm binary and platform" })

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
