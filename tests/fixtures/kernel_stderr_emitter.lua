-- A real subprocess standing in for the Python bridge's stderr. No Jupyter dependency.
local warning = '[IPKernelApp] WARNING | Kernel is running over TCP without encryption.'
  .. ' All communication (including code and outputs) is sent in plain text'
  .. ' and is susceptible to eavesdropping.\n'

-- ipykernel's TCP warning, split mid-line across two writes so the reads see
-- it in pieces; neither piece should reach the user.
local split = 40
io.stderr:write(warning:sub(1, split))
io.stderr:flush()
vim.uv.sleep(100)
io.stderr:write(warning:sub(split + 1))
io.stderr:flush()

-- A real problem is still reported, and so is a last line without a newline.
io.stderr:write('Traceback: something broke\n')
io.stderr:write('trailing line without newline')
io.stderr:flush()
