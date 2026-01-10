-- Editor plugins: Treesitter, colorscheme, statusline, etc.

return {
  -- Treesitter for syntax highlighting and more
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'master',
    lazy = false,
    build = ':TSUpdate',
    config = function()
      ---@diagnostic disable-next-line: missing-fields
      require('nvim-treesitter.configs').setup {
        ensure_installed = {
          'bash', 'c', 'html', 'css', 'lua', 'luadoc',
          'markdown', 'markdown_inline', 'vim', 'vimdoc',
          'typescript', 'javascript', 'tsx', 'json', 'yaml',
          'rust', 'go', 'gomod', 'gosum',
          'dockerfile', 'sql', 'prisma',
        },
        sync_install = false,
        auto_install = true,
        highlight = {
          enable = true,
          additional_vim_regex_highlighting = false,
        },
        indent = { enable = true },
      }
    end,
  },

  -- Gruvbox Material colorscheme
  {
    'sainnhe/gruvbox-material',
    priority = 1000,
    init = function()
      vim.g.gruvbox_material_background = 'medium'
      vim.g.gruvbox_material_palette = 'material'
      vim.g.gruvbox_material_enable_italic = 1
      vim.g.gruvbox_material_better_performance = 1
      vim.g.gruvbox_material_sign_column_background = 'none'

      -- Custom highlights
      local grpid = vim.api.nvim_create_augroup('custom_highlights_gruvboxmaterial', {})
      vim.api.nvim_create_autocmd('ColorScheme', {
        group = grpid,
        pattern = 'gruvbox-material',
        command = 'hi NvimTreeNormal                     guibg=#181818 |'
          .. 'hi NvimTreeEndOfBuffer                guibg=#181818 |'
          .. 'hi NoiceCmdlinePopupBorderCmdline     guifg=#ea6962 guibg=#282828 |'
          .. 'hi TelescopePromptBorder              guifg=#ea6962 guibg=#282828 |'
          .. 'hi TelescopePromptNormal              guifg=#ea6962 guibg=#282828 |'
          .. 'hi TelescopePromptTitle               guifg=#ea6962 guibg=#282828 |'
          .. 'hi TelescopePromptPrefix              guifg=#ea6962 guibg=#282828 |'
          .. 'hi TelescopePromptCounter             guifg=#ea6962 guibg=#282828 |'
          .. 'hi TelescopePreviewTitle              guifg=#89b482 guibg=#282828 |'
          .. 'hi TelescopePreviewBorder             guifg=#89b482 guibg=#282828 |'
          .. 'hi TelescopeResultsTitle              guifg=#89b482 guibg=#282828 |'
          .. 'hi TelescopeResultsBorder             guifg=#89b482 guibg=#282828 |'
          .. 'hi TelescopeMatching                  guifg=#d8a657 guibg=#282828 |'
          .. 'hi TelescopeSelection                 guifg=#ffffff guibg=#32302f |'
          .. 'hi FloatBorder                        guifg=#ea6962 guibg=#282828 |'
          .. 'hi NormalFloat                        guibg=#282828 |'
          .. 'hi IndentBlanklineContextChar         guifg=#d3869b',
      })
      vim.cmd.colorscheme 'gruvbox-material'
      vim.cmd.hi 'Comment gui=none'
    end,
  },

  -- Which-key for keybinding hints
  {
    'folke/which-key.nvim',
    event = 'VimEnter',
    config = function()
      require('which-key').setup()
      require('which-key').add {
        { '<leader>c', group = '[C]ode' },
        { '<leader>d', group = '[D]ocument' },
        { '<leader>r', group = '[R]ename' },
        { '<leader>s', group = '[S]earch' },
        { '<leader>w', group = '[W]orkspace' },
        { '<leader>t', group = '[T]est' },
        { '<leader>g', group = '[G]it' },
        { '<leader>q', group = '[Q]uickfix' },
      }
    end,
  },

  -- Mini.nvim collection
  {
    'echasnovski/mini.nvim',
    config = function()
      -- Text objects
      require('mini.ai').setup { n_lines = 500 }
      -- Statusline
      local statusline = require 'mini.statusline'
      statusline.setup { use_icons = vim.g.have_nerd_font }
      statusline.section_location = function()
        return '%2l:%-2v'
      end
      statusline.section_git = function()
        return ''
      end
    end,
  },

  -- Git signs in gutter
  {
    'lewis6991/gitsigns.nvim',
    opts = {
      signs = {
        add = { text = '+' },
        change = { text = '~' },
        delete = { text = '_' },
        topdelete = { text = '‾' },
        changedelete = { text = '~' },
      },
    },
    config = function(_, opts)
      require('gitsigns').setup(opts)
      vim.keymap.set('n', '<leader>gp', ':Gitsigns preview_hunk<CR>', { desc = '[G]it [P]review hunk' })
    end,
  },

  -- Git commands
  {
    'tpope/vim-fugitive',
    config = function()
      vim.keymap.set('n', '<leader>gg', ':Git<CR>', { desc = '[G]it status' })
    end,
  },

  -- Comment plugin
  { 'numToStr/Comment.nvim', opts = {} },

  -- Detect tabstop/shiftwidth
  'tpope/vim-sleuth',

  -- File tree
  {
    'nvim-tree/nvim-tree.lua',
    opts = {},
  },

  -- Todo comments
  {
    'folke/todo-comments.nvim',
    event = 'VimEnter',
    dependencies = { 'nvim-lua/plenary.nvim' },
    opts = {
      signs = false,
      colors = {
        info = { 'DiagnosticInfo', '#d3869b' },
      },
    },
  },
}
