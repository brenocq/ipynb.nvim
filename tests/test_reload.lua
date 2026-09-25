-- Reloading an open notebook from disk (:edit!, or autoread after another
-- program changed the file) must update it in place: the kernel's callbacks
-- hold the notebook state, so a fresh state would strand the kernel.
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/test_reload.lua

local h = require('tests.helpers')
local kernel = require('ipynb.kernel')
local output = require('ipynb.output')
local state_mod = require('ipynb.state')
local tests_dir = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')

print(string.rep('=', 60))
print('Running notebook reload tests')
print(string.rep('=', 60))

local function code_cell(id, source, text)
  return {
    cell_type = 'code',
    id = id,
    metadata = vim.empty_dict(),
    execution_count = text and 1 or vim.NIL,
    outputs = text and { { output_type = 'stream', name = 'stdout', text = { text } } } or {},
    source = { source },
  }
end

local function write_notebook(path, cells)
  vim.fn.writefile({
    vim.json.encode({ nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = cells }),
  }, path)
end

-- Rewrite the file as another program would. The mtime is pushed forward so
-- :checktime notices the change regardless of timestamp resolution.
local function change_on_disk(path, cells)
  write_notebook(path, cells)
  local t = os.time() + 10
  vim.uv.fs_utime(path, t, t)
end

local function open(cells)
  h.close_all_notebooks()
  local path = vim.fn.tempname() .. '.ipynb'
  write_notebook(path, cells)
  return h.open_notebook_path(path), path
end

local function sources(state)
  local parts = {}
  for _, cell in ipairs(state.cells) do
    parts[#parts + 1] = cell.id .. ':' .. cell.source
  end
  return table.concat(parts, ' ')
end

-- Count only the plugin's own buffer autocmds: nvim adds some itself (e.g.
-- vim.diagnostic registers one the first time diagnostics are set).
local function plugin_autocmds(buf)
  local count = 0
  for _, au in ipairs(vim.api.nvim_get_autocmds({ buffer = buf })) do
    local info = type(au.callback) == 'function' and debug.getinfo(au.callback, 'S')
    if info and info.source:match('[/\\]lua[/\\]ipynb[/\\]') then
      count = count + 1
    end
  end
  return count
end

local function output_text(cell)
  local out = cell.outputs and cell.outputs[1]
  if not out then
    return nil
  end
  return type(out.text) == 'table' and table.concat(out.text) or out.text
end

for _, reload in ipairs({ { name = 'edit_bang', cmd = 'edit!' }, { name = 'autoread', cmd = 'checktime' } }) do
  h.run_test(reload.name .. '_updates_notebook_in_place', function()
    local state, path = open({ code_cell('c1', 'a = 1'), code_cell('c2', 'b = 2') })
    local buf = state.facade_buf
    local autocmds = plugin_autocmds(buf)

    change_on_disk(path, { code_cell('c1', 'a = 1'), code_cell('c2', 'b = 22'), code_cell('c3', 'c = 3') })
    vim.cmd(reload.cmd)

    h.assert_true(state_mod.get(buf) == state, 'Reload should keep the notebook state')
    h.assert_eq(sources(state), 'c1:a = 1 c2:b = 22 c3:c = 3')
    h.assert_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'b = 22'),
      'Facade should show the new document')
    h.assert_false(vim.bo[buf].modified, 'A reloaded notebook matches the disk')
    h.assert_eq(plugin_autocmds(buf), autocmds, 'Reload should not duplicate autocmds')
    h.assert_true(vim.treesitter.highlighter.active[buf] ~= nil, 'Highlighting should survive the reload')
  end)
end

h.run_test('kernel_output_reaches_reloaded_notebook', function()
  local state, path = open({ code_cell('c1', 'a = 1'), code_cell('c2', 'b = 2') })
  local jobstart = vim.fn.jobstart
  local ok, err = xpcall(function()
    -- Only substitute the command, preserving the production job options.
    vim.fn.jobstart = function(_, opts)
      return jobstart({
        vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE',
        '-l', tests_dir .. '/fixtures/kernel_echo_bridge.lua',
      }, opts)
    end
    assert(kernel.start_bridge(state, vim.v.progpath), 'Bridge job should start')
    assert(vim.wait(5000, function()
      return state.kernel.connected
    end, 10), 'Bridge should report a started kernel')

    -- A cell inserted above shifts the executed cell to a new index.
    change_on_disk(path, { code_cell('c0', 'z = 0'), code_cell('c1', 'a = 1'), code_cell('c2', 'b = 2') })
    vim.cmd('edit!')
    local reloaded = state_mod.get(state.facade_buf)
    h.assert_true(reloaded == state, 'Reload should keep the notebook attached to its kernel')

    h.assert_true(kernel.execute(reloaded, 3), 'Execute should reach the kernel')
    h.assert_true(vim.wait(5000, function()
      return #reloaded.cells[3].outputs > 0
    end, 10), 'Output should arrive in the reloaded notebook')
    h.assert_eq(output_text(reloaded.cells[3]), 'ran b = 2\n')
  end, debug.traceback)

  vim.fn.jobstart = jobstart
  local job = state.kernel and state.kernel.job_id
  if job then
    -- The echo bridge exits cleanly at EOF.
    vim.fn.chanclose(job, 'stdin')
    vim.fn.jobwait({ job }, 2000)
  end
  assert(ok, err)
end)

h.run_test('reload_keeps_only_unsaved_outputs', function()
  local state, path = open({ code_cell('c1', 'a = 1'), code_cell('c2', 'b = 2', 'saved\n'), code_cell('c3', 'c = 3') })
  -- c1 and c3 ran after loading; c2 still shows the output it was saved with.
  for _, idx in ipairs({ 1, 3 }) do
    output.clear_outputs(state, idx)
    output.append_output(state.cells[idx], { output_type = 'stream', name = 'stdout', text = 'ran\n' })
  end

  -- Another program re-ran c2 and edited c3.
  change_on_disk(path, {
    code_cell('c1', 'a = 1'), code_cell('c2', 'b = 2', 'rerun elsewhere\n'), code_cell('c3', 'c = 33'),
  })
  vim.cmd('checktime')

  h.assert_eq(output_text(state.cells[1]), 'ran\n', 'Unsaved output of unchanged code should survive')
  h.assert_eq(output_text(state.cells[2]), 'rerun elsewhere\n', 'Outputs changed on disk should win')
  h.assert_eq(output_text(state.cells[3]), nil, 'Output of code changed on disk should be dropped')

  -- Once saved, the outputs are on disk and no longer override it.
  vim.cmd('write')
  change_on_disk(path, { code_cell('c1', 'a = 1', 'rerun elsewhere\n'), code_cell('c2', 'b = 2'), code_cell('c3', 'c = 33') })
  vim.cmd('checktime')
  h.assert_eq(output_text(state.cells[1]), 'rerun elsewhere\n', 'Saved outputs should not override the disk')
end)

h.run_test('reload_closes_open_edit_float', function()
  local state, path = open({ code_cell('c1', 'a = 1'), code_cell('c2', 'b = 2') })
  h.enter_cell(2)

  change_on_disk(path, { code_cell('c0', 'z = 0'), code_cell('c1', 'a = 1'), code_cell('c2', 'b = 2') })
  vim.cmd('checktime')

  h.assert_true(state.edit_state == nil, 'Reload should close the edit float')
  h.assert_eq(sources(state), 'c0:z = 0 c1:a = 1 c2:b = 2')

  h.enter_cell(3)
  h.assert_eq(h.get_edit_buffer_content(), 'b = 2', 'Editing should work on the reloaded notebook')
  h.exit_cell()
  h.assert_eq(sources(state), 'c0:z = 0 c1:a = 1 c2:b = 2')
end)

h.run_test('reload_of_deleted_file_keeps_notebook', function()
  local state, path = open({ code_cell('c1', 'a = 1') })
  local autocmds = plugin_autocmds(state.facade_buf)
  vim.fn.delete(path)
  vim.cmd('edit!')

  h.assert_true(state_mod.get(state.facade_buf) == state, 'Reload should keep the notebook state')
  h.assert_eq(#state.cells, 1, 'A missing file reloads as an empty notebook')
  h.assert_eq(plugin_autocmds(state.facade_buf), autocmds, 'Reload should not duplicate autocmds')
end)

-- Exit unloads buffers without deleting them, so cleanup must not depend on
-- BufDelete alone. Run a real nvim to exit it.
h.run_test('exit_deletes_workspace_shadow_file', function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  local path = dir .. '/exit.ipynb'
  local shadow = dir .. '/.ipynb.nvim/exit_shadow.py'
  write_notebook(path, { code_cell('c1', 'a = 1') })

  local result = vim.system({
    vim.v.progpath, '--headless', '-u', tests_dir .. '/minimal_init.lua',
    '-c', "lua require('ipynb').setup({ shadow = { location = 'workspace' } })",
    '-c', 'edit ' .. vim.fn.fnameescape(path),
    '-c', 'lua if not vim.uv.fs_stat(vim.env.IPYNB_TEST_SHADOW) then vim.cmd.cquit(2) end',
    '-c', 'qa!',
  }, { env = { IPYNB_TEST_SHADOW = shadow }, text = true }):wait(30000)

  h.assert_eq(result.code, 0, 'Child nvim should open the notebook and exit cleanly')
  h.assert_eq(vim.fn.filereadable(shadow), 0, 'Exit should delete the workspace shadow file')
end)

if h.summary() then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
