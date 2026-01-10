-- Core Neovim options
-- These are loaded before plugins

vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.g.expandtab = true
vim.g.tabstop = 2
vim.g.shiftwidth = 2

vim.g.have_nerd_font = true

-- Line numbers
vim.opt.number = true
vim.opt.relativenumber = true

-- Mouse
vim.opt.mouse = 'a'

-- Don't show mode (shown in statusline)
vim.opt.showmode = false

-- Clipboard sync with OS
vim.opt.clipboard = 'unnamedplus'

-- Indentation
vim.opt.breakindent = true

-- Undo history
vim.opt.undofile = true

-- Search
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = true

-- UI
vim.opt.signcolumn = 'yes'
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.cursorline = true
vim.opt.scrolloff = 10

-- Whitespace display
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Live substitution preview
vim.opt.inccommand = 'split'

-- Folding (treesitter-based)
vim.o.foldexpr = 'nvim_treesitter#foldexpr()'
vim.o.foldlevel = 20
vim.o.foldcolumn = '1'
vim.o.foldmethod = 'expr'

-- Termguicolors
if vim.fn.has 'termguicolors' then
  vim.opt.termguicolors = true
end
