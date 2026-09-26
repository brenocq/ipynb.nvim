-- Keymap registration tests for ipynb.nvim
-- Run with: nvim --headless -u tests/minimal_init.lua -l tests/test_keymaps.lua

local h = require('tests.helpers')

-- which-key is not a test dependency: stand in for it and record every spec the
-- plugin hands to it, so the tests can check where each one is registered.
local added = {}
package.loaded['which-key'] = {
  add = function(spec)
    table.insert(added, spec)
  end,
}

print('')
print(string.rep('=', 60))
print('Running keymap registration tests')
print(string.rep('=', 60))
print('')

--------------------------------------------------------------------------------
-- Test: which-key entries are local to the notebook buffer
-- Open a notebook and collect what it registers with which-key.
-- Expected: every spec carries the notebook's facade buffer, so the notebook
-- group under <leader>k does not appear in unrelated buffers.
--------------------------------------------------------------------------------
h.run_test('which_key_specs_are_buffer_local', function()
  added = {}
  h.open_notebook('simple.ipynb')
  local facade_buf = h.get_facade_buf()

  h.assert_true(#added > 0, 'Opening a notebook should register its keymaps with which-key')
  for _, spec in ipairs(added) do
    h.assert_eq(spec.buffer, facade_buf, 'which-key specs must be scoped to the notebook buffer')
  end
end)

--------------------------------------------------------------------------------
-- Test: each notebook registers for its own buffer
-- Open two notebooks one after the other.
-- Expected: each registration is scoped to the facade of the notebook that made
-- it, never to the other one and never global.
--------------------------------------------------------------------------------
h.run_test('which_key_specs_follow_their_notebook', function()
  h.close_all_notebooks()
  added = {}
  h.open_notebook('simple.ipynb')
  local first_buf = h.get_facade_buf()
  local first_count = #added

  h.open_notebook('three_cells.ipynb')
  local second_buf = h.get_facade_buf()

  h.assert_true(first_buf ~= second_buf, 'The two notebooks should have different facade buffers')
  h.assert_true(#added > first_count, 'The second notebook should register its own specs')
  for i, spec in ipairs(added) do
    local expected = i <= first_count and first_buf or second_buf
    h.assert_eq(spec.buffer, expected, 'Spec ' .. i .. ' should belong to the notebook that added it')
  end
end)

--------------------------------------------------------------------------------
-- Print summary and exit
--------------------------------------------------------------------------------
local success = h.summary()
if success then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
