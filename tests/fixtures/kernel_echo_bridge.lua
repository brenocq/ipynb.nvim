-- A real subprocess standing in for the Python bridge. No Jupyter dependency.
-- Reports a started kernel, then answers every execute with one stdout line
-- routed to the requesting cell.
local function send(msg)
  io.write(vim.json.encode(msg) .. '\n')
  io.flush()
end

send({ type = 'kernel_started', kernel_name = 'python3' })

for line in io.lines() do
  local ok, cmd = pcall(vim.json.decode, line)
  if ok and type(cmd) == 'table' and cmd.action == 'execute' then
    send({
      type = 'output',
      cell_id = cmd.cell_id,
      output = { output_type = 'stream', name = 'stdout', text = 'ran ' .. cmd.code .. '\n' },
    })
  end
end
