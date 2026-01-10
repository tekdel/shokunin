-- Core keymaps (non-plugin)

local map = vim.keymap.set

-- Clear search highlight
map('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Diagnostics
map('n', '[d', vim.diagnostic.goto_prev, { desc = 'Go to previous [D]iagnostic message' })
map('n', ']d', vim.diagnostic.goto_next, { desc = 'Go to next [D]iagnostic message' })
map('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Show diagnostic [E]rror messages' })
map('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Quickfix navigation
map('n', '<leader>qo', ':copen<CR>', { desc = 'Open [Q]uickfix list' })
map('n', '<leader>qc', ':cclose<CR>', { desc = 'Close [Q]uickfix list' })
map('n', '<leader>qj', ':cnext<CR>', { desc = 'Next quickfix entry' })
map('n', '<leader>qk', ':cprev<CR>', { desc = 'Previous quickfix entry' })

-- System clipboard
map('n', '<leader>y', '"+y', { desc = 'Yank to system clipboard' })
map('v', '<leader>y', '"+y', { desc = 'Yank to system clipboard' })
map('n', '<leader>Y', 'gg"+yG', { desc = 'Yank entire buffer to system clipboard' })

-- Terminal mode
map('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- Window navigation
map('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus left' })
map('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus right' })
map('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus down' })
map('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus up' })

-- Center screen after scroll
map('n', '<C-d>', '<C-d>zz')
map('n', '<C-u>', '<C-u>zz')

-- Tmux sessionizer
map('n', '<C-f>', '<cmd>silent !tmux neww tmux-sessionizer<CR>')

-- Make file executable
map('n', '<leader>x', '<cmd>!chmod +x %<CR>', { silent = true })

-- Move lines in visual mode
map('v', 'J', ":m '>+1<CR>gv=gv", { desc = 'Move selection down' })
map('v', 'K', ":m '<-2<CR>gv=gv", { desc = 'Move selection up' })

-- Paste without yanking replaced text
map('v', '<leader>p', '"_dP', { desc = 'Paste without yanking' })

-- File explorer
map('n', '<leader>ef', ':Explore<CR>', { desc = '[E]xplore [F]iles' })
