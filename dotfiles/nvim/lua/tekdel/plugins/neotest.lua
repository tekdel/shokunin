-- Neotest configuration
-- Supports: Jest, Go

return {
  'nvim-neotest/neotest',
  dependencies = {
    'nvim-neotest/nvim-nio',
    'nvim-lua/plenary.nvim',
    'nvim-treesitter/nvim-treesitter',
    -- Test adapters
    'nvim-neotest/neotest-jest',
    'nvim-neotest/neotest-go',
    -- DAP integration for debugging tests
    'mfussenegger/nvim-dap',
  },

  config = function()
    -- Helper: Find jest config file
    local function find_jest_config(path)
      local config_files = {
        'jest.config.js',
        'jest.config.ts',
        'jest.config.mjs',
        'jest.config.cjs',
        'jest.config.json',
      }

      -- Start from the given path and search up
      local current = path
      while current ~= '/' do
        for _, config in ipairs(config_files) do
          local config_path = current .. '/' .. config
          if vim.fn.filereadable(config_path) == 1 then
            return config_path
          end
        end
        -- Also check package.json for jest config
        local pkg_path = current .. '/package.json'
        if vim.fn.filereadable(pkg_path) == 1 then
          local content = vim.fn.readfile(pkg_path)
          local json_str = table.concat(content, '\n')
          if json_str:match '"jest"' then
            return pkg_path
          end
        end
        current = vim.fn.fnamemodify(current, ':h')
      end
      return nil
    end

    -- Helper: Find project root (where package.json is)
    local function find_project_root(path)
      local current = path
      while current ~= '/' do
        if vim.fn.filereadable(current .. '/package.json') == 1 then
          return current
        end
        current = vim.fn.fnamemodify(current, ':h')
      end
      return vim.fn.getcwd()
    end

    require('neotest').setup {
      -- Diagnostic output
      output = {
        enabled = true,
        open_on_run = 'short',
      },
      -- Status in the sign column
      status = {
        enabled = true,
        signs = true,
        virtual_text = false,
      },
      -- Summary window
      summary = {
        enabled = true,
        animated = true,
        follow = true,
        expand_errors = true,
      },
      -- Adapters
      adapters = {
        -- Jest adapter with smart config detection
        require 'neotest-jest' {
          jestCommand = function(path)
            local root = find_project_root(path)
            -- Check for yarn
            if vim.fn.filereadable(root .. '/yarn.lock') == 1 then
              return 'yarn test --'
            end
            -- Check for pnpm
            if vim.fn.filereadable(root .. '/pnpm-lock.yaml') == 1 then
              return 'pnpm test --'
            end
            -- Default to npx jest
            return 'npx jest'
          end,
          jestConfigFile = function(path)
            local config = find_jest_config(vim.fn.fnamemodify(path, ':h'))
            if config then
              return config
            end
            -- Fallback: let jest find it
            return 'jest.config.js'
          end,
          env = { CI = true },
          cwd = function(path)
            return find_project_root(vim.fn.fnamemodify(path, ':h'))
          end,
        },
        -- Go adapter
        require 'neotest-go' {
          experimental = {
            test_table = true,
          },
          args = { '-count=1', '-timeout=60s' },
        },
      },
    }
  end,

  -- Keymaps
  keys = {
    {
      '<leader>tr',
      function() require('neotest').run.run() end,
      desc = '[T]est [R]un nearest',
    },
    {
      '<leader>tf',
      function() require('neotest').run.run(vim.fn.expand '%') end,
      desc = '[T]est [F]ile',
    },
    {
      '<leader>td',
      function() require('neotest').run.run { strategy = 'dap' } end,
      desc = '[T]est [D]ebug nearest',
    },
    {
      '<leader>ts',
      function() require('neotest').summary.toggle() end,
      desc = '[T]est [S]ummary toggle',
    },
    {
      '<leader>to',
      function() require('neotest').output_panel.toggle() end,
      desc = '[T]est [O]utput toggle',
    },
    {
      '<leader>tO',
      function() require('neotest').output.open { enter = true, auto_close = true } end,
      desc = '[T]est [O]utput (floating)',
    },
    {
      '<leader>ta',
      function() require('neotest').run.run(vim.fn.getcwd()) end,
      desc = '[T]est [A]ll in project',
    },
    {
      '<leader>tl',
      function() require('neotest').run.run_last() end,
      desc = '[T]est [L]ast',
    },
    {
      '<leader>tx',
      function() require('neotest').run.stop() end,
      desc = '[T]est stop (e[X]it)',
    },
    {
      '[t',
      function() require('neotest').jump.prev { status = 'failed' } end,
      desc = 'Previous failed test',
    },
    {
      ']t',
      function() require('neotest').jump.next { status = 'failed' } end,
      desc = 'Next failed test',
    },
  },
}
