-- ipynb/latex.lua - Render LaTeX to PNG images with latex + dvipng
-- The same pipeline IPython and euporie use. Every source requested during one
-- event loop tick goes into a single document, one page each, so rendering a
-- notebook full of formulas costs one latex run instead of one per formula.

local M = {}

-- Part of every cache key: bump it when the document changes.
local TEMPLATE_VERSION = '1'

-- showonlyrefs keeps amsmath from numbering every align/equation line, which
-- Jupyter's MathJax does not do either.
local PREAMBLE = [[
\documentclass{article}
\usepackage{amsmath,amssymb,mathtools,xcolor}
\mathtoolsset{showonlyrefs}
\pagestyle{empty}
\setlength{\parindent}{0pt}
\begin{document}]]

local tools_found = nil ---@type boolean|nil
local failed = {} ---@type table<string, boolean> Sources that failed to render, by key
local waiting = {} ---@type table<string, fun()[]> Callbacks of renders in flight, by key
local queue = {} ---@type table[] Renders requested since the last flush
local flush_scheduled = false

---Whether LaTeX rendering is enabled and its tools are installed
---@return boolean
function M.is_available()
  local config = require('ipynb.config').get()
  if config.latex and config.latex.enabled == false then
    return false
  end
  if tools_found == nil then
    tools_found = vim.fn.executable('latex') == 1 and vim.fn.executable('dvipng') == 1
  end
  return tools_found
end

---Get the LaTeX source of an output's text/latex entry
---@param output table Output object
---@return string|nil source
function M.get_source(output)
  if output.output_type ~= 'execute_result' and output.output_type ~= 'display_data' then
    return nil
  end
  local data = output.data and output.data['text/latex']
  if not data then
    return nil
  end
  local source = vim.trim(type(data) == 'table' and table.concat(data) or data)
  return source ~= '' and source or nil
end

---Text color for rendered math, as RRGGBB
---@return string
local function foreground()
  for _, name in ipairs({ 'IpynbMath', 'Normal' }) do
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    if hl.fg then
      return string.format('%06X', hl.fg)
    end
  end
  return vim.o.background == 'light' and '000000' or 'FFFFFF'
end

---Resolution that makes one line of math as tall as one terminal row: the
---document is set in 10pt, whose lines are 12pt apart.
---@return number dpi
local function resolution()
  local _, cell_height = require('ipynb.images').cell_size()
  local scale = (require('ipynb.config').get().latex or {}).scale or 1
  return math.max(1, math.floor(cell_height * 72.27 / 12 * scale + 0.5))
end

---@return string
local function cache_dir()
  local dir = require('ipynb.images').get_cache_dir() .. '/latex'
  vim.fn.mkdir(dir, 'p')
  return dir
end

---Run a command in dir and report whether it succeeded
---@param cmd string[]
---@param dir string
---@param on_done fun(ok: boolean)
local function run(cmd, dir, on_done)
  local ok = pcall(vim.system, cmd, {
    cwd = dir,
    timeout = 10000,
    -- Keep \openout from writing outside the build directory.
    env = { openout_any = 'p' },
  }, vim.schedule_wrap(function(result)
    on_done(result.code == 0)
  end))
  if not ok then
    on_done(false)
  end
end

---Report the outcome of one render to everyone waiting on it
---@param item table
---@param ok boolean
local function finish(item, ok)
  if not ok then
    failed[item.key] = true
  end
  local callbacks = waiting[item.key] or {}
  waiting[item.key] = nil
  for _, callback in ipairs(callbacks) do
    callback()
  end
end

---Render items sharing a color and resolution as one document, one page each.
---A failing batch is split in half and retried, so one broken formula costs a
---few extra runs instead of taking every other formula down with it.
---@param items table[]
---@param on_done fun()
local function render(items, on_done)
  local dir = cache_dir() .. '/build-' .. vim.uv.hrtime()
  vim.fn.mkdir(dir, 'p')

  local doc = { PREAMBLE, ('\\color[HTML]{%s}'):format(items[1].fg) }
  for _, item in ipairs(items) do
    vim.list_extend(doc, { item.source, '\\clearpage' })
  end
  table.insert(doc, '\\end{document}')
  vim.fn.writefile(vim.split(table.concat(doc, '\n'), '\n'), dir .. '/doc.tex')

  local function done(ok)
    if ok then
      -- Each item must have produced exactly one page.
      ok = vim.uv.fs_stat(('%s/page%d.png'):format(dir, #items + 1)) == nil
      for i, item in ipairs(items) do
        ok = ok and vim.uv.fs_rename(('%s/page%d.png'):format(dir, i), item.path) ~= nil
      end
    end
    vim.fn.delete(dir, 'rf')

    if ok or #items == 1 then
      for _, item in ipairs(items) do
        finish(item, ok)
      end
      on_done()
      return
    end
    local half = math.floor(#items / 2)
    render(vim.list_slice(items, 1, half), function()
      render(vim.list_slice(items, half + 1), on_done)
    end)
  end

  run({ 'latex', '-no-shell-escape', '-halt-on-error', '-interaction=batchmode', 'doc.tex' }, dir, function(ok)
    if not ok then
      return done(false)
    end
    run({
      'dvipng', '-q', '-T', 'tight', '-D', tostring(items[1].dpi),
      '-bg', 'Transparent', '-z', '9', '-o', 'page%d.png', 'doc.dvi',
    }, dir, done)
  end)
end

---Render everything queued since the last flush, one batch per color and
---resolution
local function flush()
  flush_scheduled = false
  local batches = {}
  for _, item in ipairs(queue) do
    local id = item.fg .. item.dpi
    batches[id] = batches[id] or {}
    table.insert(batches[id], item)
  end
  queue = {}
  for _, items in pairs(batches) do
    render(items, function() end)
  end
end

---Get the rendered image for a LaTeX source, starting a render if needed.
---Sources requested in the same tick are rendered together.
---@param source string LaTeX source, as found in a text/latex output
---@param on_ready fun() Called when a render started for this source finishes
---@return string|nil path PNG file, when the source is already rendered
---@return boolean failed Whether rendering this source failed
function M.lookup(source, on_ready)
  local fg, dpi = foreground(), resolution()
  local key = vim.fn.sha256(table.concat({ TEMPLATE_VERSION, fg, dpi, source }, '\0'))
  if failed[key] then
    return nil, true
  end
  local path = ('%s/%s.png'):format(cache_dir(), key)
  if vim.uv.fs_stat(path) then
    return path, false
  end

  if waiting[key] then
    table.insert(waiting[key], on_ready)
    return nil, false
  end
  waiting[key] = { on_ready }
  table.insert(queue, { key = key, source = source, path = path, fg = fg, dpi = dpi })
  if not flush_scheduled then
    flush_scheduled = true
    vim.schedule(flush)
  end
  return nil, false
end

return M
