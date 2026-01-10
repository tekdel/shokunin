-- Debug Adapter Protocol (DAP) configuration
-- Supports: Go, JavaScript, TypeScript, Elixir

return {
  'mfussenegger/nvim-dap',
  dependencies = {
    -- DAP UI
    'rcarriga/nvim-dap-ui',
    'nvim-neotest/nvim-nio',

    -- Virtual text for variable values
    'theHamsta/nvim-dap-virtual-text',

    -- Mason integration
    'williamboman/mason.nvim',
    'jay-babu/mason-nvim-dap.nvim',

    -- Go adapter
    'leoluz/nvim-dap-go',
  },

  config = function()
    local dap = require 'dap'
    local dapui = require 'dapui'

    -- Virtual text setup (shows variable values inline)
    require('nvim-dap-virtual-text').setup {
      display_callback = function(variable)
        local name = string.lower(variable.name)
        local value = string.lower(variable.value)
        -- Mask sensitive values
        if name:match 'secret' or name:match 'api' or value:match 'secret' or value:match 'api' then
          return '*****'
        end
        -- Truncate long values
        if #variable.value > 15 then
          return ' ' .. string.sub(variable.value, 1, 15) .. '... '
        end
        return ' ' .. variable.value
      end,
    }

    -- Mason DAP setup - installs debug adapters
    require('mason-nvim-dap').setup {
      automatic_setup = true,
      handlers = {},
      ensure_installed = {
        'delve', -- Go debugger
        'js-debug-adapter', -- JS/TS debugger
        'codelldb', -- Rust/C/C++ debugger
      },
    }

    -- DAP UI setup
    dapui.setup {
      icons = { expanded = '▾', collapsed = '▸', current_frame = '*' },
      controls = {
        icons = {
          pause = '⏸',
          play = '▶',
          step_into = '⏎',
          step_over = '⏭',
          step_out = '⏮',
          step_back = 'b',
          run_last = '▶▶',
          terminate = '⏹',
          disconnect = '⏏',
        },
      },
    }

    -- Auto open/close DAP UI
    dap.listeners.before.attach.dapui_config = function() dapui.open() end
    dap.listeners.before.launch.dapui_config = function() dapui.open() end
    dap.listeners.before.event_terminated.dapui_config = function() dapui.close() end
    dap.listeners.before.event_exited.dapui_config = function() dapui.close() end
    dap.listeners.after.event_initialized['dapui_config'] = dapui.open
    dap.listeners.before.event_terminated['dapui_config'] = dapui.close
    dap.listeners.before.event_exited['dapui_config'] = dapui.close

    -------------------------
    -- Keymaps
    -------------------------
    local map = vim.keymap.set
    map('n', '<F5>', dap.continue, { desc = 'Debug: Start/Continue' })
    map('n', '<F1>', dap.step_into, { desc = 'Debug: Step Into' })
    map('n', '<F2>', dap.step_over, { desc = 'Debug: Step Over' })
    map('n', '<F3>', dap.step_out, { desc = 'Debug: Step Out' })
    map('n', '<F7>', dapui.toggle, { desc = 'Debug: Toggle UI' })
    map('n', '<F13>', dap.restart, { desc = 'Debug: Restart' })
    map('n', '<leader>b', dap.toggle_breakpoint, { desc = 'Debug: Toggle Breakpoint' })
    map('n', '<leader>B', function()
      dap.set_breakpoint(vim.fn.input 'Breakpoint condition: ')
    end, { desc = 'Debug: Conditional Breakpoint' })
    map('n', '<leader>gb', dap.run_to_cursor, { desc = 'Debug: Run to Cursor' })
    map('n', '<space>?', function()
      dapui.eval(nil, { enter = true })
    end, { desc = 'Debug: Eval under cursor' })

    -------------------------
    -- Go Debugger (delve)
    -------------------------
    require('dap-go').setup()

    -------------------------
    -- JavaScript/TypeScript Debugger
    -------------------------
    -- pwa-node adapter using Mason's js-debug-adapter
    dap.adapters['pwa-node'] = {
      type = 'server',
      host = '::1',
      port = '${port}',
      executable = {
        command = 'js-debug-adapter',
        args = { '${port}' },
      },
    }

    -- JS/TS configurations
    for _, language in ipairs { 'typescript', 'javascript' } do
      dap.configurations[language] = {
        {
          type = 'pwa-node',
          request = 'launch',
          name = 'Launch file',
          program = '${file}',
          cwd = '${workspaceFolder}',
          sourceMaps = true,
          resolveSourceMapLocations = {
            '${workspaceFolder}/**',
            '!**/node_modules/**',
          },
        },
        {
          type = 'pwa-node',
          request = 'attach',
          name = 'Attach',
          processId = require('dap.utils').pick_process,
          cwd = '${workspaceFolder}',
          sourceMaps = true,
          resolveSourceMapLocations = {
            '${workspaceFolder}/**',
            '!**/node_modules/**',
          },
        },
      }
    end

    -------------------------
    -- Rust Debugger (codelldb)
    -------------------------
    dap.adapters.codelldb = {
      type = 'server',
      port = '${port}',
      executable = {
        command = 'codelldb',
        args = { '--port', '${port}' },
      },
    }

    dap.configurations.rust = {
      {
        name = 'Launch',
        type = 'codelldb',
        request = 'launch',
        program = function()
          return vim.fn.input('Path to executable: ', vim.fn.getcwd() .. '/target/debug/', 'file')
        end,
        cwd = '${workspaceFolder}',
        stopOnEntry = false,
      },
      {
        name = 'Launch (cargo build first)',
        type = 'codelldb',
        request = 'launch',
        program = function()
          -- Build first
          vim.fn.system('cargo build')
          -- Find the binary name from Cargo.toml
          local cargo_toml = vim.fn.getcwd() .. '/Cargo.toml'
          if vim.fn.filereadable(cargo_toml) == 1 then
            local content = table.concat(vim.fn.readfile(cargo_toml), '\n')
            local name = content:match('%[package%].-name%s*=%s*"([^"]+)"')
            if name then
              return vim.fn.getcwd() .. '/target/debug/' .. name
            end
          end
          return vim.fn.input('Path to executable: ', vim.fn.getcwd() .. '/target/debug/', 'file')
        end,
        cwd = '${workspaceFolder}',
        stopOnEntry = false,
      },
    }

    -------------------------
    -- Elixir Debugger
    -------------------------
    local elixir_ls_debugger = vim.fn.exepath 'elixir-ls-debugger'
    if elixir_ls_debugger ~= '' then
      dap.adapters.mix_task = {
        type = 'executable',
        command = elixir_ls_debugger,
      }

      dap.configurations.elixir = {
        {
          type = 'mix_task',
          name = 'Phoenix server',
          task = 'phx.server',
          request = 'launch',
          projectDir = '${workspaceFolder}',
          exitAfterTaskReturns = false,
          debugAutoInterpretAllModules = false,
        },
      }
    end
  end,
}
