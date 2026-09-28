-- A real subprocess standing in for the Python bridge. No Jupyter dependency.
-- Reports a started kernel, then answers every execute with one stdout line
-- routed to the requesting cell, after an optional delay in ms (first script
-- argument) so a test can act while the output is still in flight.
local delay = tonumber(_G.arg and _G.arg[1]) or 0
local function send(msg)
  io.write(vim.json.encode(msg) .. '\n')
  io.flush()
end

send({ type = 'kernel_started', kernel_name = 'python3' })

for line in io.lines() do
  local ok, cmd = pcall(vim.json.decode, line)
  if ok and type(cmd) == 'table' and cmd.action == 'execute' then
    if delay > 0 then
      vim.uv.sleep(delay)
    end
    send({
      type = 'output',
      cell_id = cmd.cell_id,
      output = { output_type = 'stream', name = 'stdout', text = 'ran ' .. cmd.code .. '\n' },
    })
  end
end
