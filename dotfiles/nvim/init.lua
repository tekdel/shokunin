--[[
  Tekdel's Neovim Configuration

  Structure:
    lua/tekdel/core/     - Core settings (options, keymaps, autocmds)
    lua/tekdel/plugins/  - Plugin configurations
      - editor.lua       - Treesitter, colorscheme, mini.nvim, git
      - telescope.lua    - Fuzzy finder
      - lsp.lua          - Language servers
      - completion.lua   - Autocompletion
      - formatting.lua   - Formatting and linting
      - dap.lua          - Debugging (DAP)
      - neotest.lua      - Testing (Jest, Go)
]]

-- Load core settings first (must be before plugins)
require 'tekdel.core'

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath 'data' .. '/lazy/lazy.nvim'
if not vim.loop.fs_stat(lazypath) then
  local lazyrepo = 'https://github.com/folke/lazy.nvim.git'
  vim.fn.system { 'git', 'clone', '--filter=blob:none', '--branch=stable', lazyrepo, lazypath }
end
vim.opt.rtp:prepend(lazypath)

-- Load plugins
require('lazy').setup({
  -- Import all plugins from tekdel.plugins
  { import = 'tekdel.plugins' },
}, {
  ui = {
    icons = vim.g.have_nerd_font and {} or {
      cmd = '⌘',
      config = '🛠',
      event = '📅',
      ft = '📂',
      init = '⚙',
      keys = '🗝',
      plugin = '🔌',
      runtime = '💻',
      require = '🌙',
      source = '📄',
      start = '🚀',
      task = '📌',
      lazy = '💤 ',
    },
  },
  -- Performance
  performance = {
    rtp = {
      disabled_plugins = {
        'gzip',
        'matchit',
        'matchparen',
        'netrwPlugin',
        'tarPlugin',
        'tohtml',
        'tutor',
        'zipPlugin',
      },
    },
  },
})
