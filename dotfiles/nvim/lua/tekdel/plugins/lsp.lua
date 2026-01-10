-- LSP Configuration
-- Handles language server setup, Mason, and LSP keymaps

return {
  'neovim/nvim-lspconfig',
  dependencies = {
    -- Mason for LSP management
    'williamboman/mason.nvim',
    'williamboman/mason-lspconfig.nvim',
    'WhoIsSethDaniel/mason-tool-installer.nvim',
    -- Status updates
    { 'j-hui/fidget.nvim', opts = {} },
    -- Neovim Lua development
    { 'folke/neodev.nvim', opts = {} },
  },

  config = function()
    -- LspAttach autocommand for buffer-local keymaps
    vim.api.nvim_create_autocmd('LspAttach', {
      group = vim.api.nvim_create_augroup('tekdel-lsp-attach', { clear = true }),
      callback = function(event)
        local map = function(keys, func, desc)
          vim.keymap.set('n', keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
        end

        local telescope = require 'telescope.builtin'

        -- Navigation
        map('gd', telescope.lsp_definitions, '[G]oto [D]efinition')
        map('gr', telescope.lsp_references, '[G]oto [R]eferences')
        map('gI', telescope.lsp_implementations, '[G]oto [I]mplementation')
        map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')
        map('<leader>D', telescope.lsp_type_definitions, 'Type [D]efinition')

        -- Symbols
        map('<leader>ds', telescope.lsp_document_symbols, '[D]ocument [S]ymbols')
        map('<leader>ws', telescope.lsp_dynamic_workspace_symbols, '[W]orkspace [S]ymbols')

        -- Actions
        map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')
        map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction')
        map('K', vim.lsp.buf.hover, 'Hover Documentation')

        -- Document highlight on cursor hold
        local client = vim.lsp.get_client_by_id(event.data.client_id)
        if client and client.server_capabilities.documentHighlightProvider then
          vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
            buffer = event.buf,
            callback = vim.lsp.buf.document_highlight,
          })
          vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
            buffer = event.buf,
            callback = vim.lsp.buf.clear_references,
          })
        end

        -- Trigger codelens refresh
        vim.api.nvim_exec_autocmds('User', { pattern = 'LspAttached' })
      end,
    })

    -- Capabilities (enhanced by nvim-cmp)
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    capabilities = vim.tbl_deep_extend('force', capabilities, require('cmp_nvim_lsp').default_capabilities())

    local lspconfig = require 'lspconfig'

    -- Server configurations
    local servers = {
      -- Lua
      lua_ls = {
        settings = {
          Lua = {
            completion = { callSnippet = 'Replace' },
          },
        },
      },
      -- TypeScript/JavaScript
      ts_ls = {
        filetypes = { 'javascript', 'typescript', 'javascriptreact', 'typescriptreact' },
        settings = {
          typescript = {
            inlayHints = { enabled = true },
          },
          javascript = {
            inlayHints = { enabled = true },
          },
        },
      },
      -- Go
      gopls = {
        settings = {
          gopls = {
            analyses = {
              unusedparams = true,
            },
            staticcheck = true,
          },
        },
      },
      -- Markdown
      markdown_oxide = {
        root_dir = lspconfig.util.root_pattern('.git', vim.fn.getcwd()),
      },
      -- CSS
      cssls = {},
      -- HTML
      html = {},
      -- Tailwind
      tailwindcss = {},
      -- Prisma
      prismals = {},
    }

    -- Mason setup
    require('mason').setup()

    -- Tools to install
    local ensure_installed = vim.tbl_keys(servers or {})
    vim.list_extend(ensure_installed, {
      'stylua', -- Lua formatter
      'prettierd', -- JS/TS formatter
      'eslint_d', -- JS/TS linter
      'js-debug-adapter', -- JS/TS debugger
      'delve', -- Go debugger
    })
    require('mason-tool-installer').setup { ensure_installed = ensure_installed }

    -- Mason-lspconfig setup
    require('mason-lspconfig').setup {
      handlers = {
        function(server_name)
          local server = servers[server_name] or {}
          server.capabilities = vim.tbl_deep_extend('force', {}, capabilities, server.capabilities or {})
          lspconfig[server_name].setup(server)
        end,
      },
    }
  end,
}
