-- ipynb/io.lua - File I/O (ipynb ↔ jupytext conversion)

local M = {}

local state_mod = require('ipynb.state')

---Create default metadata for a new notebook
---@param kernel_name string|nil Kernel name (default: "python3")
---@return table metadata
function M.default_metadata(kernel_name)
  kernel_name = kernel_name or 'python3'
  return {
    kernelspec = {
      display_name = 'Python 3',
      language = 'python',
      name = kernel_name,
    },
    language_info = {
      name = 'python',
    },
    nbformat = 4,
    nbformat_minor = 5,
  }
end

---Create a default empty notebook structure
---@param kernel_name string|nil Kernel name (default: "python3")
---@return Cell[], table metadata, table<string, boolean> cell_ids
function M.create_empty_notebook(kernel_name)
  local id = state_mod.generate_cell_id()
  local cell_ids = { [id] = true }
  local cells = {
    {
      id = id,
      type = 'code',
      source = '',
      metadata = {},
      outputs = {},
    },
  }
  return cells, M.default_metadata(kernel_name), cell_ids
end

---Parse a .ipynb JSON file into cells
---Auto-upgrades to nbformat 4.5 and ensures all loaded cells have unique IDs
---(per JEP 62), repairing missing or duplicate IDs on read.
---@param path string Path to .ipynb file
---@return Cell[], table metadata, table<string, boolean> cell_ids
function M.read_ipynb(path)
  local content = vim.fn.readfile(path)
  local json_str = table.concat(content, '\n')

  local ok, notebook = pcall(vim.json.decode, json_str)
  if not ok then
    error('Failed to parse notebook JSON: ' .. tostring(notebook))
  end

  -- Assign IDs against a live "already used" set so malformed notebooks with
  -- duplicate IDs are repaired during load. The first valid occurrence wins.
  local existing_ids = {}
  local cells = {}
  for _, nb_cell in ipairs(notebook.cells or {}) do
    -- Source can be string or array of strings
    -- Trailing \n on last element means trailing blank line - preserve it
    local source = nb_cell.source
    if type(source) == 'table' then
      source = table.concat(source, '')
    end

    -- Preserve the first valid cell ID, otherwise repair by generating a new one.
    local id = nb_cell.id
    if type(id) ~= 'string' or id == '' or existing_ids[id] then
      id = state_mod.generate_cell_id(existing_ids)
    end
    existing_ids[id] = true

    local cell = {
      id = id,
      type = nb_cell.cell_type or 'code',
      source = source,
      metadata = nb_cell.metadata or {},
      outputs = nb_cell.outputs,
      execution_count = nb_cell.execution_count,
    }
    table.insert(cells, cell)
  end

  -- Extract notebook metadata, preserving ALL fields (Colab, Kaggle, widgets, etc.)
  local default = M.default_metadata()
  local nb_meta = notebook.metadata or {}

  -- Start with all original metadata, then ensure required fields have defaults
  local metadata = vim.tbl_deep_extend('keep', nb_meta, {
    kernelspec = default.kernelspec,
    language_info = default.language_info,
  })

  -- Auto-upgrade to nbformat 4.5 (cell IDs required per JEP 62)
  metadata.nbformat = notebook.nbformat or default.nbformat
  metadata.nbformat_minor = math.max(notebook.nbformat_minor or 0, 5)

  return cells, metadata, existing_ids
end

---Split source string into array of lines (matches nbformat/splitlines behavior)
---@param source string
---@return string[]
local function split_source(source)
  if source == '' then
    return {}
  end

  local source_lines = {}
  local lines = vim.split(source, '\n', { plain = true })

  for i, line in ipairs(lines) do
    if i < #lines then
      -- Not the last element - add newline back
      table.insert(source_lines, line .. '\n')
    elseif line ~= '' then
      -- Last element: only include if non-empty
      -- (empty last element means source ended with \n, already captured above)
      table.insert(source_lines, line)
    end
  end

  return source_lines
end

---Write cells back to .ipynb format
---@param path string Path to write to
---@param cells Cell[]
---@param metadata table|nil Notebook metadata
function M.write_ipynb(path, cells, metadata)
  -- Collect existing IDs for collision avoidance (safety net for missing IDs)
  local existing_ids = {}
  for _, cell in ipairs(cells) do
    if cell.id then
      existing_ids[cell.id] = true
    end
  end

  local nb_cells = {}
  for _, cell in ipairs(cells) do
    local source_lines = split_source(cell.source)

    -- Use existing ID, or generate if missing (safety net)
    local id = cell.id
    if not id then
      id = state_mod.generate_cell_id(existing_ids)
      existing_ids[id] = true
    end

    local nb_cell = {
      id = id,
      cell_type = cell.type,
      source = source_lines,
      metadata = cell.metadata or {},
    }

    if cell.type == 'code' then
      nb_cell.outputs = cell.outputs or {}
      nb_cell.execution_count = cell.execution_count
    end

    table.insert(nb_cells, nb_cell)
  end

  local default = M.default_metadata()

  -- Preserve ALL metadata fields (Colab, Kaggle, widgets, custom fields, etc.)
  -- Only nbformat/nbformat_minor are top-level; everything else goes in metadata
  local nb_metadata = {}
  if metadata then
    for k, v in pairs(metadata) do
      if k ~= 'nbformat' and k ~= 'nbformat_minor' then
        nb_metadata[k] = v
      end
    end
  end

  -- Ensure required fields have defaults
  nb_metadata.kernelspec = nb_metadata.kernelspec or default.kernelspec
  nb_metadata.language_info = nb_metadata.language_info or default.language_info

  local notebook = {
    cells = nb_cells,
    metadata = nb_metadata,
    nbformat = metadata and metadata.nbformat or default.nbformat,
    nbformat_minor = metadata and metadata.nbformat_minor or default.nbformat_minor,
  }

  local json_str = vim.json.encode(notebook)
  -- Pretty format JSON for readability
  json_str = M.pretty_json(json_str)

  vim.fn.writefile(vim.split(json_str, '\n'), path)
end

---Convert cells to facade format with explicit start/end delimiters
---Uses custom format: # <<ipynb_nvim:code>>, # <<ipynb_nvim:markdown>>, # <<ipynb_nvim:raw>>
---End marker: # <</ipynb_nvim>>
---@param cells Cell[]
---@return string[]
function M.cells_to_jupytext(cells)
  local lines = {}

  for i, cell in ipairs(cells) do
    -- Add blank line between cells (except before first)
    if i > 1 then
      table.insert(lines, '')
    end

    -- Cell start marker
    table.insert(lines, '# <<ipynb_nvim:' .. cell.type .. '>>')

    -- Cell content (no prefix needed - we have explicit end markers)
    local source_lines = vim.split(cell.source, '\n', { plain = true })
    for _, line in ipairs(source_lines) do
      table.insert(lines, line)
    end

    -- Cell end marker
    table.insert(lines, '# <</ipynb_nvim>>')
  end

  -- Add trailing blank line so last cell output can be scrolled into view
  table.insert(lines, '')

  return lines
end

---Parse facade format back into cells
---Custom format: # <<ipynb_nvim:code>>, # <<ipynb_nvim:markdown>>, # <<ipynb_nvim:raw>>
---End marker: # <</ipynb_nvim>>
---@param lines string[]
---@return Cell[]
function M.jupytext_to_cells(lines)
  local cells = {}
  local current_cell = nil
  local content_lines = {}

  local function save_current_cell()
    if current_cell then
      -- Join content lines - trailing newline represents a blank last line
      current_cell.source = table.concat(content_lines, '\n')
      table.insert(cells, current_cell)
    end
  end

  for _, line in ipairs(lines) do
    -- Check for cell start marker: # <<ipynb_nvim:type>>
    local cell_type = line:match('^# <<ipynb_nvim:(%w+)>>$')

    -- Check for cell end marker: # <</ipynb_nvim>>
    local is_end = line:match('^# <</ipynb_nvim>>$')

    if cell_type then
      -- Save previous cell if any
      save_current_cell()

      -- Start new cell
      current_cell = {
        type = cell_type,
        source = '',
        metadata = {},
        outputs = cell_type == 'code' and {} or nil,
      }
      content_lines = {}
    elseif is_end then
      -- End current cell
      save_current_cell()
      current_cell = nil
      content_lines = {}
    elseif current_cell then
      table.insert(content_lines, line)
    end
  end

  -- Save last cell if not properly closed
  save_current_cell()

  return cells
end

---Open a notebook file (or create new if doesn't exist)
---@param buf number Buffer to populate
---@param path string Path to .ipynb file
function M.open_notebook(buf, path)
  -- External reload (an agent/git edited the file; :e!): BufReadCmd re-fires on
  -- the same facade buffer. Reuse the existing state so the running kernel and
  -- its stream callbacks (which capture the state object) stay attached; only
  -- the document refreshes. Cells whose id AND source are unchanged keep their
  -- in-memory outputs and execution counts.
  local existing = state_mod.notebooks[buf]
  if existing and vim.fn.filereadable(path) == 1 then
    -- If the in-memory notebook has unsaved changes, stash it before the disk
    -- version replaces it — reloads must never be able to destroy work. The
    -- state flag, not the buffer flag: :edit! clears 'modified' before
    -- BufReadCmd fires.
    if existing.dirty then
      -- Timestamped so consecutive dirty reloads never clobber an earlier
      -- backup; cleanup is manual and deliberate.
      local backup = path .. '.reload-backup-' .. os.date('%Y%m%d-%H%M%S') .. '.ipynb'
      local ok = pcall(M.write_ipynb, backup, existing.cells, existing.metadata)
      vim.notify(ok and ('Unsaved notebook state backed up to ' .. backup)
                 or 'WARNING: failed to back up unsaved notebook state',
                 ok and vim.log.levels.WARN or vim.log.levels.ERROR)
    end
    local cells, metadata, cell_ids = M.read_ipynb(path)
    local old_by_id = {}
    for _, cell in ipairs(existing.cells or {}) do
      if cell.id then
        old_by_id[cell.id] = cell
      end
    end
    for _, cell in ipairs(cells) do
      local old = cell.id and old_by_id[cell.id]
      if old and old.source == cell.source then
        cell.outputs = old.outputs
        cell.execution_count = old.execution_count
      end
      -- Execution indicators reflect the KERNEL's reality, which the reload
      -- does not touch: a running/queued cell is still running/queued.
      if old then
        cell.execution_state = old.execution_state
      end
    end
    existing.cells = cells
    existing.metadata = metadata
    existing.cell_ids = cell_ids
    existing.dirty = false
    local kernel_ok, kernel_mod = pcall(require, 'ipynb.kernel')
    if kernel_ok and kernel_mod.rebuild_cell_index_map then
      kernel_mod.rebuild_cell_index_map(existing)
    end
    require('ipynb.facade').refresh(existing)
    vim.notify('Notebook reloaded from disk (kernel preserved)', vim.log.levels.INFO)
    return
  end

  local cells, metadata, cell_ids

  -- Check if file exists
  if vim.fn.filereadable(path) == 1 then
    -- Read existing notebook
    cells, metadata, cell_ids = M.read_ipynb(path)
  else
    -- Create new empty notebook
    cells, metadata, cell_ids = M.create_empty_notebook()
    vim.notify('New notebook: ' .. vim.fn.fnamemodify(path, ':t'), vim.log.levels.INFO)
  end

  -- Create state
  local state = state_mod.create(path)
  state.cells = cells
  state.metadata = metadata
  state.cell_ids = cell_ids

  -- Create facade buffer
  local facade = require('ipynb.facade')
  facade.create(state, buf)

  -- Register state
  state_mod.register(state)

  -- Setup cells and visuals
  local cells_mod = require('ipynb.cells')
  cells_mod.place_markers(state)

  local visuals = require('ipynb.visuals')
  visuals.render_all(state)

  -- Setup active cell tracking (throttled, once per buffer)
  visuals.setup_active_tracking(state)

  -- Render existing outputs (including images)
  local output = require('ipynb.output')
  output.render_all(state)

  -- Setup keymaps
  local keymaps = require('ipynb.keymaps')
  keymaps.setup_facade_keymaps(state)

  -- Setup buffer-local commands
  local commands = require('ipynb.commands')
  commands.setup_buffer(state)
end

---Save a notebook file
---@param buf number Buffer number
---@param path string|nil Path to save to (defaults to source_path)
function M.save_notebook(buf, path)
  local state = state_mod.get(buf)
  if not state then
    vim.notify('No notebook state found for buffer', vim.log.levels.ERROR)
    return
  end

  path = path or state.source_path

  -- Sync cells from facade buffer
  local cells_mod = require('ipynb.cells')
  cells_mod.sync_cells_from_facade(state)
  cells_mod.place_markers(state)  -- Refresh extmarks after sync

  -- Write to file
  M.write_ipynb(path, state.cells, state.metadata)

  -- Mark buffer as saved
  vim.bo[buf].modified = false
  state.dirty = false

  vim.notify('Saved notebook: ' .. path, vim.log.levels.INFO)
end

---Simple JSON pretty printer
---@param json_str string
---@return string
function M.pretty_json(json_str)
  local indent = 0
  local result = {}
  local in_string = false
  local escape_next = false

  for i = 1, #json_str do
    local char = json_str:sub(i, i)

    if escape_next then
      table.insert(result, char)
      escape_next = false
    elseif char == '\\' and in_string then
      table.insert(result, char)
      escape_next = true
    elseif char == '"' then
      table.insert(result, char)
      in_string = not in_string
    elseif not in_string then
      if char == '{' or char == '[' then
        indent = indent + 1
        table.insert(result, char)
        table.insert(result, '\n')
        table.insert(result, string.rep(' ', indent * 2))
      elseif char == '}' or char == ']' then
        indent = indent - 1
        table.insert(result, '\n')
        table.insert(result, string.rep(' ', indent * 2))
        table.insert(result, char)
      elseif char == ',' then
        table.insert(result, char)
        table.insert(result, '\n')
        table.insert(result, string.rep(' ', indent * 2))
      elseif char == ':' then
        table.insert(result, char)
        table.insert(result, ' ')
      elseif char ~= ' ' and char ~= '\n' and char ~= '\t' then
        table.insert(result, char)
      end
    else
      table.insert(result, char)
    end
  end

  return table.concat(result)
end

return M
