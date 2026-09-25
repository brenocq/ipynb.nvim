-- Math in markdown cells ($$ blocks and inline $...$), rendered in place of
-- its source.
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/test_markdown_math.lua

local h = require('tests.helpers')
local config = require('ipynb.config')
local images = require('ipynb.images')
local latex = require('ipynb.latex')
local markdown_math = require('ipynb.markdown_math')

print(string.rep('=', 60))
print('Running markdown math tests')
print(string.rep('=', 60))

config.get().images.cache_dir = vim.fn.tempname()

local have_tools = latex.is_available()
if not have_tools then
  print('  (' .. table.concat(latex.tools, ', ') .. ' not all found: rendering tests are skipped)')
end

h.run_test('finds_display_blocks_and_inline_math', function()
  local source = table.concat({
    'Inline $a+b$ and mid-sentence $$x^2$$ render inline.', -- 0
    '',
    '$$\\int_0^1 x\\,dx$$', -- 2
    '',
    '$$', -- 4
    '\\sum_{n=1}^\\infty \\frac{1}{n^2}',
    '$$', -- 6
    '',
    '- item',
    '  $$ e^{i\\pi} + 1 = 0 $$', -- 9
    '',
    '```',
    '$$not math$$',
    '```',
    'Prices $5 and $10, spaced $ x $ and `$code$` are not math, but $x$.', -- 14
  }, '\n')
  local found = {}
  for _, block in ipairs(markdown_math.find_math(source)) do
    local kind = block.display and 'display' or 'inline'
    local text = block.text:gsub('\n', ' ')
    table.insert(found, ('%s %d:%d-%d:%d %s'):format(kind, block.first, block.first_col, block.last, block.last_col, text))
  end
  h.assert_eq(table.concat(found, '\n'), table.concat({
    'inline 0:7-0:12 $a+b$',
    'inline 0:30-0:37 $x^2$',
    'display 2:0-2:18 $$\\int_0^1 x\\,dx$$',
    'display 4:0-6:2 $$ \\sum_{n=1}^\\infty \\frac{1}{n^2} $$',
    'display 9:2-9:24 $$ e^{i\\pi} + 1 = 0 $$',
    'inline 14:63-14:66 $x$',
  }, '\n'))
end)

-- The terminal image layer needs a graphics terminal: stand in with marker
-- rows, IMAGE_ROWS tall, so the tests see where each image row lands.
local IMAGE_ROWS = 3
local function with_fake_image_layer(fn)
  local supports, file_lines = images.supports_placeholders, images.get_file_virt_lines
  images.supports_placeholders = function()
    return true
  end
  images.get_file_virt_lines = function()
    local rows = {}
    for i = 1, IMAGE_ROWS do
      table.insert(rows, { { '[image row ' .. i .. ']', 'Normal' } })
    end
    return rows, IMAGE_ROWS
  end
  local ok, err = xpcall(fn, debug.traceback)
  images.supports_placeholders, images.get_file_virt_lines = supports, file_lines
  assert(ok, err)
end

---Open a notebook with the given markdown cells
---@param sources string[]
---@return NotebookState
local function open_markdown(sources)
  h.close_all_notebooks()
  local cells = {}
  for i, source in ipairs(sources) do
    table.insert(cells, { cell_type = 'markdown', id = 'm' .. i, metadata = vim.empty_dict(), source = { source } })
  end
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({ vim.json.encode({ nbformat = 4, nbformat_minor = 5, metadata = vim.empty_dict(), cells = cells }) }, path)
  return h.open_notebook_path(path)
end

---What the math namespace draws on each buffer row, e.g. '12: conceal [image row 1]'
---@param state NotebookState
---@return string
local function drawn(state)
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.facade_buf, markdown_math.ns, 0, -1, { details = true })) do
    local row, details, parts = mark[3] > 0 and (mark[2] .. ':' .. mark[3]) or mark[2], mark[4], {}
    if details.conceal then
      table.insert(parts, 'conceal')
    end
    for _, chunk in ipairs(details.virt_text or {}) do
      if chunk[1]:find('%S') then
        table.insert(parts, chunk[1])
      end
    end
    for _, line in ipairs(details.virt_lines or {}) do
      local text = {}
      for _, chunk in ipairs(line) do
        table.insert(text, chunk[1])
      end
      table.insert(parts, 'below: ' .. vim.trim(table.concat(text)))
    end
    table.insert(rows, row .. ': ' .. table.concat(parts, ' '))
  end
  return table.concat(rows, '\n')
end

---Wait until the math namespace draws something
local function wait_drawn(state, pattern)
  return vim.wait(20000, function()
    return drawn(state):find(pattern) ~= nil
  end, 10)
end

h.run_test('display_math_replaces_its_source_lines', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    -- Buffer rows: marker 0, 'One line:' 1, '' 2, block 3, '' 4, 'Three:' 5, block 6-8
    local state = open_markdown({ 'One line:\n\n$$x^2$$\n\nThree:\n$$\n\\frac{a}{b}\n$$' })
    h.assert_true(wait_drawn(state, 'image row'), 'The math should render')
    h.assert_eq(drawn(state), table.concat({
      '3: below: │ [image row 2] below: │ [image row 3]',
      '3: conceal [image row 1]',
      '6: conceal [image row 1]',
      '7: conceal [image row 2]',
      '8: conceal [image row 3]',
    }, '\n'))
  end)
end)

h.run_test('short_image_sits_in_the_middle_of_a_tall_block', function()
  if not have_tools then
    return
  end
  local rows = IMAGE_ROWS
  IMAGE_ROWS = 1
  local ok, err = xpcall(function()
    with_fake_image_layer(function()
      local state = open_markdown({ '$$\na + b\n$$' })
      h.assert_true(wait_drawn(state, 'image row'), 'The math should render')
      h.assert_eq(drawn(state), '1: conceal\n2: conceal [image row 1]\n3: conceal')
    end)
  end, debug.traceback)
  IMAGE_ROWS = rows
  assert(ok, err)
end)

h.run_test('editing_a_cell_shows_its_source_until_it_closes', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    -- Buffer rows: first cell's math on row 2, second cell's on row 7
    local state = open_markdown({ 'Text\n$$x$$', 'Other\n$$y$$' })
    h.assert_true(wait_drawn(state, '7: conceal'), 'Both cells should render')

    h.enter_cell(1)
    h.assert_eq(drawn(state):find('2: ', 1, true), nil, 'The edited cell should show its source')
    h.assert_true(drawn(state):find('7: conceal', 1, true) ~= nil, 'Other cells stay rendered')

    h.exit_cell()
    h.assert_true(wait_drawn(state, '2: conceal'), 'Closing the float should render the cell again')
  end)
end)

h.run_test('cell_operations_keep_math_in_place', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    local state = open_markdown({ '$$x$$' })
    h.assert_true(wait_drawn(state, '1: conceal'), 'The math should render')

    require('ipynb.facade').insert_cell(state, 0, 'markdown')
    -- The new empty cell takes rows 0-2 and a blank line; the math moves to row 5.
    h.assert_true(wait_drawn(state, '5: conceal'), 'The math should follow its cell')
    h.assert_eq(drawn(state):find('1: ', 1, true), nil, 'Nothing should be left at the old row')
  end)
end)

h.run_test('inline_math_replaces_its_source_within_the_line', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    -- Buffer row 1: 'Energy $E = mc^2$ and $$x$$ inline.'
    local state = open_markdown({ 'Energy $E = mc^2$ and $$x$$ inline, not $5.' })
    h.assert_true(wait_drawn(state, '1:22'), 'The math should render')
    h.assert_eq(drawn(state), '1:7: conceal [image row 1]\n1:22: conceal [image row 1]')
  end)
end)

h.run_test('broken_math_keeps_its_source_and_shows_the_error', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    local state = open_markdown({ 'Broken:\n$$\\frac{1}{$$' })
    h.assert_true(wait_drawn(state, 'LaTeX error'), 'The error should be shown')
    h.assert_eq(drawn(state), '2: LaTeX error: File ended while scanning use of \\frac')
  end)
end)

if h.summary() then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
