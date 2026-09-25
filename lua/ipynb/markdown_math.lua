-- ipynb/markdown_math.lua - Render math in markdown cells
-- A $$ block on its own lines is replaced by its image in Notebook mode: its
-- source lines are hidden and the image rows take their place as virtual
-- lines, which the cursor steps over like a fold. Inline math ($...$, or
-- $$...$$ inside a line) is replaced by a one-row image within its line. The
-- source stays in the buffer and shows again while the cell is open in the
-- edit float.

local M = {}

local ns = vim.api.nvim_create_namespace('ipynb_markdown_math')
M.ns = ns

local query = nil ---@type vim.treesitter.Query|nil

-- Hiding whole lines needs Neovim 0.11. Before that, a block's source lines
-- are concealed and carry the image rows inline instead.
local hide_lines = vim.fn.has('nvim-0.11') == 1

---@class MathBlock
---@field display boolean A $$ block on its own lines (else inline math)
---@field first number First source line (0-based)
---@field last number Last source line (0-based)
---@field first_col number Byte column where the math starts on its first line
---@field last_col number Byte column where the math ends on its last line (exclusive)
---@field text string LaTeX to render, with its dollar delimiters

---Whether $...$ counts as math, by the rules of Jupyter's markdown (pandoc's
---tex_math_dollars): no space just inside the dollars, and no digit right
---after the closing one, so prices like "$5 and $10" stay text.
---@param text string
---@param after string Character following the closing dollar
---@return boolean
local function is_inline_math(text, after)
  return text:match('^%$[^%s$]') ~= nil and text:match('[^%s]%$$') ~= nil and not after:match('%d')
end

---Jupyter hands math to MathJax before markdown runs, so authors escape `*`
---as `\*` to keep it from starting emphasis. LaTeX has no such escape (`x^\*`
---fails), so drop the backslash; an escaped backslash (`\\*`) stays.
---@param text string
---@return string
local function unescape_markdown(text)
  return (text:gsub('(\\+)%*', function(backslashes)
    if #backslashes % 2 == 1 then
      return backslashes:sub(2) .. '*'
    end
  end))
end

---Find the math of a markdown source: $$ blocks on their own lines, and
---single-line inline math. Math in code spans and fences is not math.
---@param source string
---@return MathBlock[] blocks In source order
function M.find_math(source)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, 'markdown')
  if not ok then
    return {}
  end
  parser:parse(true)
  query = query or vim.treesitter.query.parse('markdown_inline', '(latex_block) @math')

  local lines = vim.split(source, '\n', { plain = true })
  local blocks = {}
  parser:for_each_tree(function(tree, ltree)
    if ltree:lang() ~= 'markdown_inline' then
      return
    end
    for _, node in query:iter_captures(tree:root(), source) do
      local first, first_col, last, last_col = node:range()
      local text = vim.treesitter.get_node_text(node, source)
      local block = { first = first, last = last, first_col = first_col, last_col = last_col, text = text }
      local double = #text > 4 and text:match('^%$%$') and text:match('%$%$$')
      local own_lines = lines[first + 1]:sub(1, first_col):match('^%s*$')
        and lines[last + 1]:sub(last_col + 1):match('^%s*$')
      if double and own_lines then
        block.display = true
        table.insert(blocks, block)
      elseif first == last then
        block.display = false
        if double then
          -- Inline in a line of text: typeset it inline too
          block.text = '$' .. text:sub(3, -3) .. '$'
          table.insert(blocks, block)
        elseif is_inline_math(text, lines[last + 1]:sub(last_col + 1, last_col + 1)) then
          table.insert(blocks, block)
        end
      end
    end
  end)
  table.sort(blocks, function(a, b)
    return a.first < b.first or (a.first == b.first and a.first_col < b.first_col)
  end)
  for _, block in ipairs(blocks) do
    block.text = unescape_markdown(block.text)
  end
  return blocks
end

---Key a cell's math images are tracked under, apart from its output images
---@param cell Cell
---@return string
local function image_owner(cell)
  return cell.id .. ':math'
end

-- Border highlight visuals last drew each cell with, and the image rows that
-- hang below each cell's source lines, by cell.
local border_hls = setmetatable({}, { __mode = 'k' }) ---@type table<Cell, string>
local hanging = setmetatable({}, { __mode = 'k' }) ---@type table<Cell, table[]>

---Gutter chunks continuing a cell's left border on a virtual line. The border
---is a sign, and virtual lines have no signs, so it is drawn into their left
---columns. Returns nil when the gutter layout is not the default one.
---@param buf number
---@param border_hl string
---@return table[]|nil chunks
local function border_gutter(buf, border_hl)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return nil
  end
  local wo = vim.wo[win]
  local fold_width = tonumber(wo.foldcolumn)
  if wo.statuscolumn ~= '' or not fold_width or wo.signcolumn == 'no' or wo.signcolumn:match('^number') then
    return nil
  end
  -- Widths come from the options: the window's textoff lags until its next
  -- redraw. Every content line has a border sign, so the sign column shows.
  local sign_width = 2 * (tonumber(wo.signcolumn:match('^yes:(%d)')) or 1)
  local number_width = 0
  if wo.number or wo.relativenumber then
    local largest = wo.number and vim.api.nvim_buf_line_count(buf) or vim.api.nvim_win_get_height(win)
    number_width = math.max(wo.numberwidth, #tostring(largest) + 1)
  end
  -- Fold column, then the sign column holding the border, then line numbers
  return {
    { string.rep(' ', fold_width), 'FoldColumn' },
    { require('ipynb.visuals').borders.vertical, { 'SignColumn', border_hl } },
    { string.rep(' ', sign_width - 1), 'SignColumn' },
    { string.rep(' ', number_width), 'LineNr' },
  }
end

---Draw (or redraw) image rows hanging below a block, with the cell's border
---@param buf number
---@param entry { id: number, indent: table, rows: table[], applied: string|nil }
---@param border_hl string
local function draw_hanging(buf, entry, border_hl)
  local gutter = border_gutter(buf, border_hl)
  local key = vim.inspect(gutter)
  local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, entry.id, {})
  if entry.applied == key or not pos[1] then
    return
  end
  local lines = {}
  for _, row in ipairs(entry.rows) do
    local line = vim.list_extend(vim.deepcopy(gutter or {}), { entry.indent, row[1] })
    table.insert(lines, line)
  end
  vim.api.nvim_buf_set_extmark(buf, ns, pos[1], 0, {
    id = entry.id,
    virt_lines = lines,
    virt_lines_leftcol = gutter ~= nil,
  })
  entry.applied = key
end

---Match the border drawn on a cell's hanging image rows to its left border.
---Called by visuals whenever it draws a cell's border.
---@param state NotebookState
---@param cell_idx number
---@param border_hl string
function M.set_border_hl(state, cell_idx, border_hl)
  local cell = state.cells[cell_idx]
  if not cell then
    return
  end
  border_hls[cell] = border_hl
  for _, entry in ipairs(hanging[cell] or {}) do
    draw_hanging(state.facade_buf, entry, border_hl)
  end
end

---Hang image rows below a line, drawn with the cell's border
---@param buf number
---@param cell Cell
---@param row number
---@param indent table Chunk indenting the image
---@param image_rows table[] Placeholder rows, one virt_line entry each
local function hang(buf, cell, row, indent, image_rows)
  local entry = {
    id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {}),
    indent = indent,
    rows = image_rows,
  }
  hanging[cell] = hanging[cell] or {}
  table.insert(hanging[cell], entry)
  draw_hanging(buf, entry, border_hls[cell] or 'IpynbBorder')
end

---Show an image in place of the source lines [first_row, last_row]
---@param buf number
---@param cell Cell
---@param first_row number
---@param last_row number
---@param image_rows table[] Placeholder rows, one virt_line entry each
---@param anchor_row number Nearest line above the block that stays visible
local function place(buf, cell, first_row, last_row, image_rows, anchor_row)
  local lines = vim.api.nvim_buf_get_lines(buf, first_row, last_row + 1, false)
  local indent = { string.rep(' ', vim.fn.strdisplaywidth(lines[1]:match('^%s*'))) }

  if hide_lines then
    -- Concealed text still counts when a line wraps, so an image drawn on a
    -- long source line would be split across screen rows. Hide the lines
    -- instead, and hang every image row from the line above; virtual lines on
    -- a hidden line would be hidden too.
    vim.api.nvim_buf_set_extmark(buf, ns, first_row, 0, {
      end_row = last_row,
      end_col = #lines[#lines],
      conceal_lines = '',
    })
    hang(buf, cell, anchor_row, indent, image_rows)
    return
  end

  -- A short image sits in the middle of a tall block.
  local offset = math.max(0, math.floor((#lines - #image_rows) / 2))

  for i, line in ipairs(lines) do
    local image_row = image_rows[i - offset]
    vim.api.nvim_buf_set_extmark(buf, ns, first_row + i - 1, 0, {
      end_col = #line,
      conceal = '',
      virt_text = image_row and { indent, image_row[1] } or nil,
      virt_text_pos = image_row and 'inline' or nil,
    })
  end

  if #image_rows > #lines then
    hang(buf, cell, last_row, indent, vim.list_slice(image_rows, #lines + 1))
  end
end

---The hidden $$ block covering a row, if any
---@param buf number
---@param row number
---@return number|nil first, number|nil last
local function hidden_block_at(buf, row)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true, overlap = true })
  for _, mark in ipairs(marks) do
    if mark[4].conceal_lines then
      return mark[2], mark[4].end_row
    end
  end
  return nil, nil
end

-- Buffers whose cursor already steps over hidden blocks
local stepping = {} ---@type table<number, boolean>

---Keep the cursor off hidden block lines, where it would be invisible: step
---over a block in the direction the cursor was moving, like over a fold.
---@param buf number
local function step_over_hidden_blocks(buf)
  if not hide_lines or stepping[buf] then
    return
  end
  stepping[buf] = true
  local last_row = nil
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = vim.api.nvim_create_augroup('IpynbMarkdownMath' .. buf, { clear = true }),
    buffer = buf,
    callback = function()
      local cursor = vim.api.nvim_win_get_cursor(0)
      local row, target = cursor[1] - 1, cursor[1] - 1
      local down = last_row == nil or row >= last_row
      -- Blocks sit inside cells, so a visible marker line always bounds them.
      for _ = 1, 100 do
        local first, last = hidden_block_at(buf, target)
        if not first then
          break
        end
        target = down and last + 1 or first - 1
      end
      if target ~= row then
        vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
      end
      last_row = target
    end,
  })
end

---Show a one-row image in place of inline math
---@param buf number
---@param row number
---@param col number
---@param end_col number
---@param image_row table Placeholder row, as a virt_line entry
local function place_inline(buf, row, col, end_col, image_row)
  vim.api.nvim_buf_set_extmark(buf, ns, row, col, {
    end_col = end_col,
    conceal = '',
    virt_text = { image_row[1] },
    virt_text_pos = 'inline',
  })
end

---Remove a cell's rendered math, showing its source again
---@param state NotebookState
---@param cell_idx number
function M.clear_cell(state, cell_idx)
  local cell = state.cells[cell_idx]
  -- From the start marker: a block on the first content line hangs from it.
  local first, last = require('ipynb.cells').get_cell_range(state, cell_idx)
  if first and last then
    vim.api.nvim_buf_clear_namespace(state.facade_buf, ns, first, last)
  end
  if cell then
    hanging[cell] = nil
    if cell.id then
      require('ipynb.images').clear_images(state, image_owner(cell))
    end
  end
end

---Render the math of one markdown cell (see M.render_cell)
---@param state NotebookState
---@param cell_idx number
local function render_cell(state, cell_idx)
  local cell = state.cells[cell_idx]
  M.clear_cell(state, cell_idx)
  -- The source shows while the cell is being edited.
  if cell.type ~= 'markdown' or (state.edit_state and state.edit_state.cell_id == cell.id) then
    return
  end

  local latex = require('ipynb.latex')
  local images = require('ipynb.images')
  if not latex.is_available() or not images.supports_placeholders() then
    return
  end
  local content_start = require('ipynb.cells').get_content_range(state, cell_idx)
  if not content_start then
    return
  end

  -- Images render in the background: render the cell again once they are
  -- ready, once however many were pending.
  local rerender_scheduled = false
  local function rerender()
    if rerender_scheduled then
      return
    end
    rerender_scheduled = true
    vim.schedule(function()
      for idx, other in ipairs(state.cells) do
        if other.id == cell.id then
          M.render_cell(state, idx)
          return
        end
      end
    end)
  end

  local buf = state.facade_buf
  step_over_hidden_blocks(buf)
  local errors = {} ---@type table<number, string[]> Errors by row
  local hidden = nil ---@type { last: number, anchor: number }|nil Last block hidden so far
  for _, block in ipairs(M.find_math(cell.source)) do
    local first_row, last_row = content_start + block.first, content_start + block.last
    local path, err = latex.lookup(block.text, rerender, { hl = 'IpynbMarkdownMath', inline = not block.display })
    if path then
      local image_rows = images.get_file_virt_lines(state, image_owner(cell), path)
      if image_rows and block.display then
        -- A block right below another hidden one hangs from the same line.
        local anchor = (hidden and hidden.last == first_row - 1) and hidden.anchor or first_row - 1
        place(buf, cell, first_row, last_row, image_rows, anchor)
        hidden = { last = last_row, anchor = anchor }
      elseif image_rows then
        place_inline(buf, first_row, block.first_col, block.last_col, image_rows[1])
      end
    elseif err then
      errors[first_row] = errors[first_row] or {}
      table.insert(errors[first_row], err)
    end
  end

  -- One message per line: the first error, and how many others there are.
  for row, messages in pairs(errors) do
    local text = 'LaTeX error: ' .. messages[1]
    if #messages > 1 then
      text = ('%s (+%d more)'):format(text, #messages - 1)
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text = { { text, 'IpynbOutputError' } },
      virt_text_pos = 'eol',
    })
  end
end

-- Cells being rendered. Showing an image waits for it with vim.wait, which
-- runs scheduled callbacks, so a cell can be asked to render again while it
-- renders: note that, and render once more afterwards instead of interleaving.
local rendering = setmetatable({}, { __mode = 'k' }) ---@type table<Cell, 'busy'|'again'>

---Render the math of one markdown cell
---@param state NotebookState
---@param cell_idx number
function M.render_cell(state, cell_idx)
  local cell = state.cells[cell_idx]
  if not cell or not cell.id or not vim.api.nvim_buf_is_valid(state.facade_buf) then
    return
  end
  if rendering[cell] then
    rendering[cell] = 'again'
    return
  end
  rendering[cell] = 'busy'
  local ok, err = pcall(render_cell, state, cell_idx)
  local again = rendering[cell] == 'again'
  rendering[cell] = nil
  if again then
    vim.schedule(function()
      for idx, other in ipairs(state.cells) do
        if other == cell then
          return M.render_cell(state, idx)
        end
      end
    end)
  end
  if not ok then
    error(err, 0)
  end
end

---Render the math of every markdown cell
---@param state NotebookState
function M.render_all(state)
  if not vim.api.nvim_buf_is_valid(state.facade_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.facade_buf, ns, 0, -1)
  -- Including cells that were deleted or are no longer markdown
  local images = require('ipynb.images')
  for owner in pairs(state.images or {}) do
    if owner:match(':math$') then
      images.clear_images(state, owner)
    end
  end
  for idx, cell in ipairs(state.cells) do
    if cell.type == 'markdown' then
      M.render_cell(state, idx)
    end
  end
end

return M
