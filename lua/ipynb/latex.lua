-- ipynb/latex.lua - Render LaTeX to PNG images
-- latex typesets every source requested during one event loop tick as a single
-- document, one page each, so a notebook full of formulas costs one latex run.
-- dvisvgm turns the pages into SVGs, and rsvg-convert rasterizes each one onto
-- a canvas that is a whole number of terminal cells: kitty fits images to their
-- cells, and any rescaling there would blur the math. Inline math is rendered
-- exactly one row tall, its baseline where the text's is.

local M = {}

-- Executables the pipeline needs, in the order it runs them.
M.tools = { 'latex', 'dvisvgm', 'rsvg-convert' }

-- Part of every cache key: bump it when the document or rasterization changes.
local TEMPLATE_VERSION = '2'

-- showonlyrefs keeps amsmath from numbering every align/equation line, which
-- Jupyter's MathJax does not do either.
local PREAMBLE = [[
\documentclass{article}
\usepackage{amsmath,amssymb,mathtools,xcolor}
\mathtoolsset{showonlyrefs}
\pagestyle{empty}
\setlength{\parindent}{0pt}
\begin{document}]]

-- Inline math sits on a strut, 0.7 and 0.3 of a 12pt line above and below the
-- baseline, and the preview package makes each page exactly that box: one
-- terminal row, with the baseline about where the terminal font puts it.
local INLINE_PREAMBLE = [[
\documentclass{article}
\usepackage{amsmath,amssymb,mathtools,xcolor}
\usepackage[active,tightpage]{preview}
\setlength\PreviewBorder{0pt}
\begin{document}]]

-- rsvg-convert processes running at once for one batch
local MAX_RASTERIZERS = 8

local tools_found = nil ---@type boolean|nil
local failed = {} ---@type table<string, string> Why sources failed to render, by key
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
    tools_found = true
    for _, tool in ipairs(M.tools) do
      tools_found = tools_found and vim.fn.executable(tool) == 1
    end
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
---@param group string Highlight group to take the color from
---@return string
local function foreground(group)
  for _, name in ipairs({ group, 'Normal' }) do
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    if hl.fg then
      return string.format('%06X', hl.fg)
    end
  end
  return vim.o.background == 'light' and '000000' or 'FFFFFF'
end

---Rendering geometry: the resolution makes one line of math as tall as one
---terminal row (the document is set in 10pt, whose lines are 12pt apart), and
---images are padded to whole cells.
---@return number dpi
---@return number cell_width Pixels
---@return number cell_height Pixels
local function geometry()
  local cell_width, cell_height = require('ipynb.images').cell_size()
  local scale = (require('ipynb.config').get().latex or {}).scale or 1
  return cell_height * 72.27 / 12 * scale, cell_width, cell_height
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

---First error LaTeX reported in the build directory's log
---@param dir string
---@return string
local function latex_error(dir)
  local log = dir .. '/doc.log'
  if vim.fn.filereadable(log) == 0 then
    return 'latex failed'
  end
  for _, line in ipairs(vim.fn.readfile(log)) do
    local message = line:match('^! (.+)')
    if message then
      return (message:gsub('%s*%.$', ''))
    end
  end
  return 'latex failed'
end

---Report the outcome of one render to everyone waiting on it
---@param item table
---@param err string|nil Why the render failed
local function finish(item, err)
  failed[item.key] = err
  local callbacks = waiting[item.key] or {}
  waiting[item.key] = nil
  for _, callback in ipairs(callbacks) do
    callback()
  end
end

---Rasterize one page onto a canvas of whole cells, the math centered
---vertically, into the item's cache file. Inline math is one row tall.
---@param item table
---@param svg string Path to the page's SVG
---@param on_done fun(err: string|nil)
local function rasterize(item, svg, on_done)
  local head = table.concat(vim.fn.readfile(svg, '', 5), '\n')
  local width_pt = tonumber(head:match('width=["\']([%d.]+)pt["\']'))
  local height_pt = tonumber(head:match('height=["\']([%d.]+)pt["\']'))
  if not width_pt or not height_pt then
    return on_done('dvisvgm wrote an SVG without a size')
  end

  -- rsvg-convert reads SVG pt as 1/72 inch
  local resolution = item.dpi
  local height = height_pt * resolution / 72
  if item.inline and height > item.cell_height + 0.5 then
    -- Taller than its strut: shrink it to one row here rather than let kitty.
    resolution = resolution * item.cell_height / height
    height = item.cell_height
  end
  local width = width_pt * resolution / 72
  local canvas_width = math.max(1, math.ceil(width / item.cell_width - 1e-6)) * item.cell_width
  local canvas_height = item.inline and item.cell_height
    or math.max(1, math.ceil(height / item.cell_height - 1e-6)) * item.cell_height
  local dpi = ('%.3f'):format(resolution)
  local png = svg:gsub('%.svg$', '.png')
  -- Values joined with '=': a rounding-negative offset like -0.06px would
  -- otherwise be read as an option.
  run({
    'rsvg-convert', '--dpi-x=' .. dpi, '--dpi-y=' .. dpi,
    ('--page-width=%dpx'):format(canvas_width), ('--page-height=%dpx'):format(canvas_height),
    ('--top=%.3fpx'):format((canvas_height - height) / 2),
    '-o', png, svg,
  }, vim.fs.dirname(svg), function(ok)
    -- Only complete images reach the cache, where they are trusted as is.
    ok = ok and vim.uv.fs_rename(png, item.path) ~= nil
    on_done(not ok and 'rsvg-convert failed' or nil)
  end)
end

---Render items sharing a color and geometry as one document, one page each.
---A failing batch is split in half and retried, so one broken formula costs a
---few extra runs instead of taking every other formula down with it.
---@param items table[]
---@param on_done fun()
local function render(items, on_done)
  local dir = cache_dir() .. '/build-' .. vim.uv.hrtime()
  vim.fn.mkdir(dir, 'p')

  local color = ('\\color[HTML]{%s}'):format(items[1].fg)
  local doc
  if items[1].inline then
    doc = { INLINE_PREAMBLE }
    for _, item in ipairs(items) do
      table.insert(doc, ('\\begin{preview}%s\\strut %s\\end{preview}'):format(color, item.source))
    end
  else
    doc = { PREAMBLE, color }
    for _, item in ipairs(items) do
      vim.list_extend(doc, { item.source, '\\clearpage' })
    end
  end
  table.insert(doc, '\\end{document}')
  vim.fn.writefile(vim.split(table.concat(doc, '\n'), '\n'), dir .. '/doc.tex')

  ---The batch as a whole failed: report why for a single source, or retry halves
  ---@param err string
  local function fail(err)
    vim.fn.delete(dir, 'rf')
    if #items == 1 then
      finish(items[1], err)
      return on_done()
    end
    local half = math.floor(#items / 2)
    render(vim.list_slice(items, 1, half), function()
      render(vim.list_slice(items, half + 1), on_done)
    end)
  end

  run({ 'latex', '-no-shell-escape', '-halt-on-error', '-interaction=batchmode', 'doc.tex' }, dir, function(ok)
    if not ok then
      return fail(latex_error(dir))
    end
    -- Display math is cropped to its ink; inline math keeps its strut box.
    local bbox = items[1].inline and '--bbox=preview' or '--exact-bbox'
    run({ 'dvisvgm', '--verbosity=1', '--no-fonts', bbox, '-p1-', '-o', 'page-%p.svg', 'doc.dvi' }, dir, function(svg_ok)
      if not svg_ok then
        return fail('dvisvgm failed')
      end

      -- dvisvgm pads page numbers to the width of the page count
      local pages = {}
      for _, svg in ipairs(vim.fn.glob(dir .. '/page-*.svg', false, true)) do
        pages[tonumber(svg:match('page%-(%d+)%.svg$'))] = svg
      end
      if vim.tbl_count(pages) ~= #items then
        return fail('the LaTeX does not fit on one page')
      end

      -- Report the batch at once, so waiting cells render once with all of it.
      local started, pending, errors = 0, #items, {}
      local function rasterize_next()
        started = started + 1
        local i = started
        if i > #items then
          return
        end
        rasterize(items[i], pages[i], function(err)
          errors[i] = err
          pending = pending - 1
          if pending > 0 then
            return rasterize_next()
          end
          vim.fn.delete(dir, 'rf')
          for j, item in ipairs(items) do
            finish(item, errors[j])
          end
          on_done()
        end)
      end
      for _ = 1, math.min(MAX_RASTERIZERS, #items) do
        rasterize_next()
      end
    end)
  end)
end

---Render everything queued since the last flush, one batch per color,
---geometry and kind (display or inline)
local function flush()
  flush_scheduled = false
  local batches = {}
  for _, item in ipairs(queue) do
    local id = table.concat({ item.fg, item.dpi, item.cell_width, item.cell_height, tostring(item.inline) }, ':')
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
---@param opts { hl: string|nil, inline: boolean|nil }|nil hl: highlight group for
---  the color (default: IpynbMath); inline: render one row tall, e.g. for `$x$`
---@return string|nil path PNG file, when the source is already rendered
---@return string|nil error Why rendering this source failed
function M.lookup(source, on_ready, opts)
  opts = opts or {}
  local fg = foreground(opts.hl or 'IpynbMath')
  local dpi, cell_width, cell_height = geometry()
  local parts = { TEMPLATE_VERSION, fg, dpi, cell_width, cell_height, source }
  if opts.inline then
    table.insert(parts, 1, 'inline')
  end
  local key = vim.fn.sha256(table.concat(parts, '\0'))
  if failed[key] then
    return nil, failed[key]
  end
  local path = ('%s/%s.png'):format(cache_dir(), key)
  if vim.uv.fs_stat(path) then
    return path, nil
  end

  if waiting[key] then
    table.insert(waiting[key], on_ready)
    return nil, nil
  end
  waiting[key] = { on_ready }
  table.insert(queue, {
    key = key,
    source = source,
    path = path,
    fg = fg,
    dpi = dpi,
    cell_width = cell_width,
    cell_height = cell_height,
    inline = opts.inline == true,
  })
  if not flush_scheduled then
    flush_scheduled = true
    vim.schedule(flush)
  end
  return nil, nil
end

return M
