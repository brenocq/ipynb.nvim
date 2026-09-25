-- ipynb/markdown_math.lua - Render math in markdown cells
-- A $$ block on its own lines is replaced by its image in Notebook mode: each
-- source line is concealed and carries one row of the image, and rows beyond
-- the source lines hang below as virtual lines. Inline math ($...$, or $$...$$
-- inside a line) is replaced by a one-row image within its line. The source
-- stays in the buffer and shows again while the cell is open in the edit float.

local M = {}

local ns = vim.api.nvim_create_namespace('ipynb_markdown_math')
M.ns = ns

local query = nil ---@type vim.treesitter.Query|nil

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

---Show an image in place of the source lines [first_row, last_row]
---@param buf number
---@param cell Cell
---@param first_row number
---@param last_row number
---@param image_rows table[] Placeholder rows, one virt_line entry each
local function place(buf, cell, first_row, last_row, image_rows)
  local lines = vim.api.nvim_buf_get_lines(buf, first_row, last_row + 1, false)
  local indent = { string.rep(' ', vim.fn.strdisplaywidth(lines[1]:match('^%s*'))) }
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
    local entry = {
      id = vim.api.nvim_buf_set_extmark(buf, ns, last_row, 0, {}),
      indent = indent,
      rows = vim.list_slice(image_rows, #lines + 1),
    }
    hanging[cell] = hanging[cell] or {}
    table.insert(hanging[cell], entry)
    draw_hanging(buf, entry, border_hls[cell] or 'IpynbBorder')
  end
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
  local first, last = require('ipynb.cells').get_content_range(state, cell_idx)
  if first and last and last >= first then
    vim.api.nvim_buf_clear_namespace(state.facade_buf, ns, first, last + 1)
  end
  if cell then
    hanging[cell] = nil
    if cell.id then
      require('ipynb.images').clear_images(state, image_owner(cell))
    end
  end
end

---Render the math of one markdown cell
---@param state NotebookState
---@param cell_idx number
function M.render_cell(state, cell_idx)
  local cell = state.cells[cell_idx]
  if not cell or not cell.id or not vim.api.nvim_buf_is_valid(state.facade_buf) then
    return
  end
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
  for _, block in ipairs(M.find_math(cell.source)) do
    local first_row = content_start + block.first
    local path, err = latex.lookup(block.text, rerender, { hl = 'IpynbMarkdownMath', inline = not block.display })
    if path then
      local image_rows = images.get_file_virt_lines(state, image_owner(cell), path)
      if image_rows and block.display then
        place(buf, cell, first_row, content_start + block.last, image_rows)
      elseif image_rows then
        place_inline(buf, first_row, block.first_col, block.last_col, image_rows[1])
      end
    elseif err then
      vim.api.nvim_buf_set_extmark(buf, ns, first_row, 0, {
        virt_text = { { 'LaTeX error: ' .. err, 'IpynbOutputError' } },
        virt_text_pos = 'eol',
      })
    end
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
