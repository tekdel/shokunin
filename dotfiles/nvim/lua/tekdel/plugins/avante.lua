return {
  {
    'yetone/avante.nvim',
    event = 'VeryLazy',
    version = false,
    opts = {
      debug = false,
      provider = 'claude',
      auto_suggestions_provider = nil,

      providers = {
        claude = {
          endpoint = 'https://api.anthropic.com',
          model = 'claude-sonnet-4-20250514',
          timeout = 30000, -- Timeout in milliseconds
          extra_request_body = {
            temperature = 0.75,
            max_tokens = 64000,
          },
        },
        openai = {
          endpoint = 'https://api.openai.com/v1',
          model = 'gpt-4o-mini', -- your desired model (or use gpt-4o, etc.)
          timeout = 30000, -- Timeout in milliseconds, increase this for reasoning models
          extra_request_body = {
            temperature = 0.75,
            max_tokens = 20480,
          },
        },

        -- Ollama Config
        ollama = {
          model = 'qwen3:1.7b',
        },
      },
    },
    build = 'make',
    dependencies = {
      'nvim-treesitter/nvim-treesitter',
      'stevearc/dressing.nvim',
      'nvim-lua/plenary.nvim',
      'MunifTanjim/nui.nvim',
      'hrsh7th/nvim-cmp',
      'nvim-tree/nvim-web-devicons',
      -- Optional:
      'echasnovski/mini.pick',
      'nvim-telescope/telescope.nvim',
      'ibhagwan/fzf-lua',
      {
        -- Make sure to set this up properly if you have lazy=true
        'MeanderingProgrammer/render-markdown.nvim',
        opts = {
          file_types = { 'markdown', 'Avante' },
        },
        ft = { 'markdown', 'Avante' },
      },
    },
  },
}
