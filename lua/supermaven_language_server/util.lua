local M = {}

function M.trim(s) return (s:gsub('^%s*(.-)%s*$', '%1')) end

function M.trim_start(s) return (s:gsub('^%s*', '')) end

function M.trim_end(s) return (s:gsub('%s*$', '')) end

function M.ends_with(str, suffix) return suffix == '' or str:sub(-#suffix) == suffix end

function M.starts_with(str, prefix) return prefix == '' or str:sub(1, #prefix) == prefix end

function M.is_whitespace(char)
  return char == ' ' or char == '\t' or char == '\n' or char == '\r' or char == '\v' or char == '\f'
end

function M.split_lines(text) return vim.split(text, '\n', { plain = true }) end

function M.line_count(str)
  local count = 0
  for _ in str:gmatch('\n') do
    count = count + 1
  end
  return count
end

function M.get_last_line(str)
  local index = str:match('.*()\n')
  if not index then return str end
  return str:sub(index + 1)
end

function M.safe_get_line(lines, index) return lines[index] end

function M.get_full_change_text(params)
  local changes = params.contentChanges or {}
  local change = changes[#changes]
  return change and change.text or nil
end

function M.extract_position_context(lines, position)
  local line = lines[position.line + 1]
  if line == nil then return nil end

  local col = math.min(position.character, #line)
  local prefix = {}
  for i = 1, position.line do
    prefix[i] = lines[i]
  end
  prefix[#prefix + 1] = line:sub(1, col)

  return {
    col = col,
    line = line,
    prefix = table.concat(prefix, '\n'),
    line_before_cursor = line:sub(1, col),
    line_after_cursor = line:sub(col + 1),
  }
end

function M.uri_to_path(uri)
  if type(uri) ~= 'string' or not vim.startswith(uri, 'file:') then return nil end

  local ok, path = pcall(vim.uri_to_fname, uri)
  return ok and path or nil
end

function M.filetype_for_uri(uri, fallback)
  local ok, bufnr = pcall(vim.uri_to_bufnr, uri)
  if not ok or not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then return fallback end
  return vim.bo[bufnr].filetype ~= '' and vim.bo[bufnr].filetype or fallback
end

function M.is_ignored_filetype(ignore_filetypes, filetype)
  if type(ignore_filetypes) ~= 'table' or filetype == nil or filetype == '' then return false end
  return ignore_filetypes[filetype] == true or vim.tbl_contains(ignore_filetypes, filetype)
end

return M
