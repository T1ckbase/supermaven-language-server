local util = require('supermaven_language_server.util')

local M = {}

local function find_first_non_empty_newline(s)
  local seen_non_whitespace = false
  for i = 1, #s do
    local char = s:sub(i, i)
    if char == '\n' and seen_non_whitespace then
      return i
    elseif not util.is_whitespace(char) then
      seen_non_whitespace = true
    end
  end
  return nil
end

local function is_all_dust(line, dust_strings)
  local line_holding = line
  while #line_holding > 0 do
    local original_length = #line_holding
    line_holding = util.trim_start(line_holding)
    for _, dust_string in ipairs(dust_strings) do
      if line_holding:sub(1, #dust_string) == dust_string then line_holding = line_holding:sub(#dust_string + 1) end
    end

    if #line_holding == original_length then return false end
  end

  return true
end

local function has_leading_newline(s)
  for i = 1, #s do
    local char = s:sub(i, i)
    if char == '\n' then
      return true
    elseif not util.is_whitespace(char) then
      return false
    end
  end
  return false
end

local function find_last_newline(s)
  for i = #s, 1, -1 do
    local char = s:sub(i, i)
    if char == '\n' then return i end
  end
  return nil
end

local function can_delete(params)
  local trimmed = util.trim(params.line_before_cursor)
  if trimmed == '' and not is_all_dust(params.line_after_cursor, params.dust_strings) then return false end
  return true
end

local function finish_completion(output, dedent, params, full_completion_index)
  if not can_delete(params) then return nil end

  local has_trailing_characters = #util.trim(params.line_after_cursor) > 0
  local output_trimmed = util.trim(output)
  if output_trimmed == '' then return nil end

  if has_leading_newline(output) then
    local first_non_empty_line = find_first_non_empty_newline(output)
    local last_new_line = find_last_newline(output)
    if first_non_empty_line ~= nil and last_new_line ~= nil then
      local text = output:sub(1, last_new_line)
      return {
        kind = 'text',
        text = text,
        dedent = dedent,
        should_retry = nil,
        is_incomplete = false,
        source_state_id = params.source_state_id,
        completion_index = full_completion_index,
      }
    end
    return nil
  end

  local index = find_first_non_empty_newline(output)
  if index ~= nil then
    local text = output:sub(1, index)
    return {
      kind = 'text',
      text = text,
      dedent = dedent,
      should_retry = true,
      is_incomplete = false,
      source_state_id = params.source_state_id,
      completion_index = nil,
    }
  end

  if params.can_retry then
    return {
      kind = 'text',
      text = output,
      dedent = dedent,
      should_retry = true,
      is_incomplete = true,
      source_state_id = params.source_state_id,
      completion_index = nil,
    }
  end

  if has_trailing_characters then return nil end

  if util.trim(params.line_before_cursor) == '' then return nil end

  if params.can_show_partial_line then
    return {
      kind = 'text',
      text = output,
      dedent = dedent,
      should_retry = true,
      is_incomplete = true,
      source_state_id = params.source_state_id,
      completion_index = nil,
    }
  end

  return nil
end

local function force_complete(output, dedent, params, completion_index)
  local result = finish_completion(output .. '\n', dedent, params, completion_index)
  if result == nil then return { kind = 'text', text = '', dedent = '', is_incomplete = false } end
  return result
end

function M.derive_completion(completion, params)
  local output = ''
  local delete_lines = {}
  local dedent = ''

  for completion_index, response_item in ipairs(completion) do
    if response_item.kind == 'end' then
      if string.find(output, '\n') then return force_complete(output, dedent, params, completion_index) end
      return nil
    end

    if #delete_lines > 0 and response_item.kind ~= 'delete' then
      return {
        kind = 'delete',
        lines = delete_lines,
        completion_index = completion_index,
        source_state_id = params.source_state_id,
      }
    end

    if response_item.kind == 'text' then
      output = output .. response_item.text
    elseif response_item.kind == 'barrier' or response_item.kind == 'finish_edit' then
      if util.trim(output) ~= '' then return force_complete(output, dedent, params, completion_index) end
    elseif response_item.kind == 'dedent' then
      dedent = dedent .. response_item.text
    elseif response_item.kind == 'jump' then
      if util.trim(output) ~= '' then
        return {
          kind = 'jump',
          completion_index = completion_index + 1,
          source_state_id = params.source_state_id,
        }
      end
      break
    elseif response_item.kind == 'delete' then
      if util.trim(output) ~= '' then return force_complete(output, dedent, params, completion_index) end
      local following_line = params.get_following_line(#delete_lines)
      if util.trim_end(response_item.verify) == util.trim_end(following_line) then
        delete_lines[#delete_lines + 1] = following_line
      end
    elseif response_item.kind == 'skip' then
      if util.trim(output) ~= '' then return force_complete(output, dedent, params, completion_index) end
      return {
        kind = 'skip',
        completion_index = completion_index + 1,
        source_state_id = params.source_state_id,
      }
    end
  end

  output = util.trim_end(output)
  local index = find_first_non_empty_newline(output)
  if index ~= nil then output = output:sub(1, index) end

  return finish_completion(output, dedent, params, nil)
end

return M
