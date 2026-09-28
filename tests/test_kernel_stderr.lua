-- Exercise the real job pipe and production stderr handler without Jupyter.
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/test_kernel_stderr.lua

local h = require('tests.helpers')
local kernel = require('ipynb.kernel')
local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')

print(string.rep('=', 60))
print('Running kernel stderr tests')
print(string.rep('=', 60))

h.run_test('tcp_warning_is_hidden_and_real_stderr_is_shown', function()
  local state = { cells = {} }
  local jobstart = vim.fn.jobstart
  local notify = vim.notify
  local job_id, exit_code
  local shown = {}
  local ok, err = xpcall(function()
    vim.notify = function(msg)
      if msg:find('Kernel bridge stderr: ', 1, true) == 1 then
        shown[#shown + 1] = msg:sub(#'Kernel bridge stderr: ' + 1)
      end
    end
    vim.fn.jobstart = function(_, opts)
      local on_exit = opts.on_exit
      opts.on_exit = function(id, code, event)
        on_exit(id, code, event)
        exit_code = code
      end
      -- Only substitute the command, preserving the production job options.
      job_id = jobstart({
        vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE',
        '-l', tests_dir .. '/fixtures/kernel_stderr_emitter.lua',
      }, opts)
      return job_id
    end

    assert(kernel.start_bridge(state, vim.v.progpath), 'Bridge job should start')
    assert(vim.wait(10000, function()
      return exit_code ~= nil
    end, 10), 'Emitter timed out')
    -- Drain the scheduled notifications after the process exits.
    vim.wait(200)
    h.assert_eq(exit_code, 0, 'Emitter should exit successfully')
    h.assert_eq(
      table.concat(shown, ' | '),
      'Traceback: something broke | trailing line without newline',
      'Only real stderr lines should be shown, each whole'
    )
  end, debug.traceback)

  vim.fn.jobstart = jobstart
  vim.notify = notify
  if job_id and job_id > 0 and exit_code == nil then
    vim.fn.jobstop(job_id)
    vim.fn.jobwait({ job_id }, 1000)
  end
  assert(ok, err)
end)

if h.summary() then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
