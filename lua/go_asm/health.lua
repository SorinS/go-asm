-- :checkhealth go_asm — reports the server binary, platform and prerequisites.
local M = {}

function M.check()
  local go_asm = require("go_asm")
  vim.health.start("go_asm")

  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("neovim " .. tostring(vim.version()))
  else
    vim.health.error("neovim 0.11+ required (client:request and vim.system are used)")
  end

  local plat = go_asm.platform()
  if plat then
    vim.health.ok("platform: " .. plat)
  else
    local u = vim.uv.os_uname()
    vim.health.warn(("no release build for %s/%s"):format(u.sysname, u.machine),
      { "Open an issue at https://github.com/" .. go_asm.repo .. "/issues",
        "Or set require('go_asm').cmd to a go-asm binary you have" })
  end

  local bin = go_asm.binary()
  if not bin then
    vim.health.error("go-asm server not found", { "Run :GoAsmInstall" })
  else
    vim.health.ok("server: " .. bin)
    local have = go_asm.server_version()
    if not have then
      vim.health.warn("server version unknown (predates --version, or did not respond)",
        { "Reinstall with :GoAsmInstall to get " .. go_asm.version })
    elseif have == go_asm.version then
      vim.health.ok("version: " .. have)
    else
      -- A client/server mismatch shows up as failing asm/* requests, not as an
      -- obviously wrong version, so surface it here.
      vim.health.warn(("version: %s, but this client expects %s"):format(have, go_asm.version),
        { "Run :GoAsmInstall to install the expected version" })
    end
  end

  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl: " .. vim.fn.exepath("curl"))
  else
    vim.health.warn("curl not found — :GoAsmInstall needs it")
  end
end

return M
