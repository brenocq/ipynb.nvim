-- LaTeX output rendering: text/latex sources become PNGs through latex + dvipng.
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/test_latex.lua

local h = require('tests.helpers')
local config = require('ipynb.config')
local images = require('ipynb.images')
local latex = require('ipynb.latex')
local output = require('ipynb.output')

print(string.rep('=', 60))
print('Running LaTeX rendering tests')
print(string.rep('=', 60))

-- A fresh cache per run, so first lookups always render.
config.get().images.cache_dir = vim.fn.tempname()

local have_tools = latex.is_available()
if not have_tools then
  print('  (latex/dvipng not found: rendering tests are skipped)')
end

---Look up sources in one tick and wait for every started render to finish
---@param sources string[]
---@return table<string, { path: string|nil, failed: boolean }>
local function render_all(sources)
  local pending = 0
  for _, source in ipairs(sources) do
    local path = latex.lookup(source, function()
      pending = pending - 1
    end)
    if not path then
      pending = pending + 1
    end
  end
  assert(vim.wait(20000, function()
    return pending == 0
  end, 10), 'Renders should finish')

  local results = {}
  for _, source in ipairs(sources) do
    local path, failed = latex.lookup(source, function() end)
    results[source] = { path = path, failed = failed }
  end
  return results
end

---@param path string
---@return number width
---@return number height
local function png_size(path)
  local f = assert(io.open(path, 'rb'))
  local header = f:read(24)
  f:close()
  assert(header:sub(1, 8) == '\137PNG\r\n\26\n', 'Should be a PNG file')
  local function u32(offset)
    local a, b, c, d = header:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

h.run_test('get_source_reads_text_latex_entries', function()
  local function out(output_type, value)
    return { output_type = output_type, data = { ['text/latex'] = value, ['text/plain'] = 'x' } }
  end
  h.assert_eq(latex.get_source(out('execute_result', '$x$\n')), '$x$')
  h.assert_eq(latex.get_source(out('display_data', { '$$a', ' + b$$' })), '$$a + b$$')
  h.assert_eq(latex.get_source(out('display_data', '  ')), nil, 'Blank LaTeX has nothing to render')
  h.assert_eq(latex.get_source({ output_type = 'execute_result', data = { ['text/plain'] = 'x' } }), nil)
  h.assert_eq(latex.get_source({ output_type = 'stream', name = 'stdout', text = '$x$' }), nil)
end)

h.run_test('renders_png_and_reuses_it', function()
  if not have_tools then
    return
  end
  local source = '$\\displaystyle \\sum_{n=1}^{\\infty} \\frac{1}{n^{2}}$'
  local path, failed = latex.lookup(source, function() end)
  h.assert_eq(path, nil, 'First lookup should start a render')
  h.assert_false(failed)

  local result = render_all({ source })[source]
  h.assert_true(result.path ~= nil, 'Render should produce a file')
  local width, height = png_size(result.path)
  h.assert_true(width > 0 and height > 0, 'PNG should have a size')

  local called = false
  local again = latex.lookup(source, function()
    called = true
  end)
  h.assert_eq(again, result.path, 'A rendered source should come from the cache')
  vim.wait(50)
  h.assert_false(called, 'A cached source should not render again')
end)

h.run_test('broken_formula_does_not_break_its_batch', function()
  if not have_tools then
    return
  end
  local good1, bad, good2 = '$a_{1}$', '$\\frac{1}{$', '$$\\int_0^1 f(x)\\,dx$$'
  local results = render_all({ good1, bad, good2 })
  h.assert_true(results[good1].path ~= nil, 'Formula before the broken one should render')
  h.assert_true(results[good2].path ~= nil, 'Formula after the broken one should render')
  h.assert_eq(results[bad].path, nil)
  h.assert_true(results[bad].failed, 'Broken formula should be reported as failed')
end)

h.run_test('color_and_scale_are_part_of_the_image', function()
  if not have_tools then
    return
  end
  local source = '$e^{i\\pi} + 1 = 0$'
  local base = render_all({ source })[source].path
  local _, base_height = png_size(base)

  local math_hl = vim.api.nvim_get_hl(0, { name = 'IpynbMath' })
  local ok, err = xpcall(function()
    vim.api.nvim_set_hl(0, 'IpynbMath', { fg = '#ff0000' })
    local red = render_all({ source })[source].path
    h.assert_true(red ~= nil and red ~= base, 'A new color should render a new image')
    vim.api.nvim_set_hl(0, 'IpynbMath', math_hl)

    config.get().latex.scale = 2
    local big = render_all({ source })[source].path
    local _, big_height = png_size(big)
    h.assert_true(big_height > base_height * 1.5, 'Scale should enlarge the image')
  end, debug.traceback)
  vim.api.nvim_set_hl(0, 'IpynbMath', math_hl)
  config.get().latex.scale = 1
  assert(ok, err)
end)

---Text of the output virtual lines of a cell
---@param state NotebookState
---@param cell_idx number
---@return string
local function output_lines(state, cell_idx)
  local cell = state.cells[cell_idx]
  if not cell.output_extmark then
    return ''
  end
  local ns = vim.api.nvim_create_namespace('notebook_outputs')
  local mark = vim.api.nvim_buf_get_extmark_by_id(state.facade_buf, ns, cell.output_extmark, { details = true })
  local lines = {}
  for _, line in ipairs(mark[3].virt_lines or {}) do
    local chunks = {}
    for _, chunk in ipairs(line) do
      table.insert(chunks, chunk[1])
    end
    table.insert(lines, table.concat(chunks))
  end
  return table.concat(lines, '\n')
end

---Open a notebook whose single code cell has a text/latex result
---@param source string
---@return NotebookState
local function open_with_latex_output(source)
  h.close_all_notebooks()
  local path = vim.fn.tempname() .. '.ipynb'
  vim.fn.writefile({ vim.json.encode({
    nbformat = 4,
    nbformat_minor = 5,
    metadata = vim.empty_dict(),
    cells = { {
      cell_type = 'code',
      id = 'c1',
      metadata = vim.empty_dict(),
      execution_count = 1,
      source = { 'x**2' },
      outputs = { {
        output_type = 'execute_result',
        execution_count = 1,
        metadata = vim.empty_dict(),
        data = { ['text/latex'] = { source }, ['text/plain'] = { 'x**2' } },
      } },
    } },
  }) }, path)
  return h.open_notebook_path(path)
end

-- The terminal image layer needs a real graphics terminal: stand it in with a
-- marker line so the test sees which representation the output chose.
local function with_fake_image_layer(fn)
  local supports, file_lines = images.supports_placeholders, images.get_file_virt_lines
  images.supports_placeholders = function()
    return true
  end
  images.get_file_virt_lines = function(_, _, path)
    return { { { '[image ' .. vim.fs.basename(path) .. ']', 'Normal' } } }, 1
  end
  local ok, err = xpcall(fn, debug.traceback)
  images.supports_placeholders, images.get_file_virt_lines = supports, file_lines
  assert(ok, err)
end

h.run_test('output_shows_text_until_its_latex_image_is_ready', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    local state = open_with_latex_output('$\\displaystyle x^{2}$')
    h.assert_true(output_lines(state, 1):find('Out: x**2', 1, true) ~= nil, 'text/plain should show while rendering')

    h.assert_true(vim.wait(20000, function()
      return output_lines(state, 1):find('[image ', 1, true) ~= nil
    end, 10), 'The rendered image should replace the text')
    h.assert_true(output_lines(state, 1):find('Out: x**2', 1, true) == nil, 'The image replaces text/plain')
  end)
end)

h.run_test('output_keeps_text_when_latex_fails', function()
  if not have_tools then
    return
  end
  with_fake_image_layer(function()
    local source = '$\\undefinedcommand{x}$'
    local state = open_with_latex_output(source)
    h.assert_true(vim.wait(20000, function()
      local _, failed = latex.lookup(source, function() end)
      return failed
    end, 10), 'The render should fail')
    vim.wait(50)
    h.assert_true(output_lines(state, 1):find('Out: x**2', 1, true) ~= nil, 'text/plain should remain')
  end)
end)

if h.summary() then
  vim.cmd('qa!')
else
  vim.cmd('cquit 1')
end
