local downloader = require('supermaven_language_server.downloader')
local log = require('supermaven_language_server.logger')
local textual = require('supermaven_language_server.textual')
local util = require('supermaven_language_server.util')

local uv = vim.uv

local Agent = {}
Agent.__index = Agent

Agent.HARD_SIZE_LIMIT = 10e6

function Agent.new(settings)
  return setmetatable({
    settings = settings,
    state_map = {},
    current_state_id = 0,
    max_state_id_retention = 50,
    changed_documents = {},
    last_state = nil,
    dust_strings = {},
    pending = {},
    pending_request_id = 0,
    timer = nil,
    handle = nil,
    stdin = nil,
    stdout = nil,
    stderr = nil,
    activate_url = nil,
    activation_notified = false,
    start_error = nil,
  }, Agent)
end

function Agent:update_settings(settings) self.settings = settings end

function Agent:is_running() return self.handle ~= nil and self.handle:is_active() end

function Agent:close_handle(handle)
  if handle and not handle:is_closing() then handle:close() end
end

function Agent:stop_timer()
  if self.timer and not self.timer:is_closing() then
    self.timer:stop()
    self.timer:close()
  end
  self.timer = nil
end

function Agent:resolve_all_pending(items)
  local pending = self.pending
  self.pending = {}
  for _, request in pairs(pending) do
    vim.schedule(function() request.callback(nil, { items = items or {} }) end)
  end
  self:stop_timer()
end

function Agent:stop()
  self:stop_timer()
  self:resolve_all_pending({})

  if self.handle and self.handle:is_active() then self.handle:kill(uv.constants.SIGTERM) end

  self:close_handle(self.stdin)
  self:close_handle(self.stdout)
  self:close_handle(self.stderr)
  self:close_handle(self.handle)

  self.stdin = nil
  self.stdout = nil
  self.stderr = nil
  self.handle = nil
end

function Agent:send_json(message)
  if not self.stdin or not self:is_running() then return end

  self.stdin:write(vim.json.encode(message) .. '\n')
end

function Agent:send_message(updates)
  self:send_json({
    kind = 'state_update',
    newId = tostring(self.current_state_id),
    updates = updates,
  })
end

function Agent:report_start_error(err)
  if err and err ~= self.start_error then log.error(err) end
  self.start_error = err
end

function Agent:prepare()
  downloader.prefetch(self.settings, function(_, err)
    if err then self:report_start_error(err) end
  end)
end

function Agent:start_binary(binary_path)
  if self:is_running() then
    self.start_error = nil
    return true
  end

  self.stdin = uv.new_pipe(false)
  self.stdout = uv.new_pipe(false)
  self.stderr = uv.new_pipe(false)

  local handle, spawn_err = uv.spawn(
    binary_path,
    {
      args = { 'stdio' },
      stdio = { self.stdin, self.stdout, self.stderr },
    },
    vim.schedule_wrap(function(code, signal)
      log.debug(('sm-agent exited with code %d signal %d'):format(code, signal))
      self:close_handle(self.stdin)
      self:close_handle(self.stdout)
      self:close_handle(self.stderr)
      self:close_handle(self.handle)
      self.stdin = nil
      self.stdout = nil
      self.stderr = nil
      self.handle = nil
      self:resolve_all_pending({})
    end)
  )

  if not handle then
    self:close_handle(self.stdin)
    self:close_handle(self.stdout)
    self:close_handle(self.stderr)
    self.stdin = nil
    self.stdout = nil
    self.stderr = nil
    local message = ('Could not start Supermaven binary: %s'):format(spawn_err or 'unknown error')
    log.error(message)
    return nil, message
  end

  self.handle = handle
  self.start_error = nil
  self:read_stdout()
  self:read_stderr()
  self:send_json({ kind = 'greeting', allowGitignore = false })

  return true
end

function Agent:ensure_started()
  if self:is_running() then
    self.start_error = nil
    return true
  end

  local binary_path, err = downloader.ready(self.settings)
  if not binary_path then
    downloader.prefetch(self.settings, function(_, prefetch_err)
      if prefetch_err then self:report_start_error(prefetch_err) end
    end)

    if err then self:report_start_error(err) end
    return nil, err or 'Supermaven binary is still downloading.'
  end

  return self:start_binary(binary_path)
end

function Agent:read_stdout()
  local buffer = ''
  self.stdout:read_start(function(err, data)
    if err then
      log.error(('Error reading Supermaven stdout: %s'):format(err))
      self:resolve_all_pending({})
      return
    end

    if data == nil then return end

    buffer = buffer .. data
    while true do
      local line_end = buffer:find('\n', 1, true)
      if not line_end then break end

      local line = buffer:sub(1, line_end - 1)
      buffer = buffer:sub(line_end + 1)
      self:process_line(line)
    end
  end)
end

function Agent:read_stderr()
  local buffer = ''
  self.stderr:read_start(function(err, data)
    if err then
      log.error(('Error reading Supermaven stderr: %s'):format(err))
      return
    end

    if data == nil then return end

    buffer = buffer .. data
    while true do
      local line_end = buffer:find('\n', 1, true)
      if not line_end then break end

      local line = buffer:sub(1, line_end - 1)
      buffer = buffer:sub(line_end + 1)
      if line ~= '' then log.debug(('sm-agent stderr: %s'):format(line)) end
    end
  end)
end

function Agent:process_line(line)
  if not util.starts_with(line, 'SM-MESSAGE ') then
    log.debug(('Unknown Supermaven message: %s'):format(line))
    return
  end

  local ok, message = pcall(vim.json.decode, line:sub(12))
  if not ok then
    log.debug(('Could not decode Supermaven message: %s'):format(line))
    return
  end

  self:process_message(message)
end

function Agent:process_message(message)
  if message.kind == 'response' then
    self:update_state_id(message)
    self:flush_pending()
    return
  end

  if message.kind == 'metadata' then
    if message.dustStrings ~= nil then self.dust_strings = message.dustStrings end
    return
  end

  if message.kind == 'activation_request' then
    self.activate_url = message.activateUrl
    self:handle_activation_request()
    return
  end

  if message.kind == 'activation_success' then
    self.activate_url = nil
    self.activation_notified = false
    log.info('Supermaven activation succeeded.')
    return
  end

  if message.kind == 'service_tier' and message.display then
    log.info(('Supermaven %s is running.'):format(message.display))
    return
  end

  if message.kind == 'passthrough' and message.passthrough then self:process_message(message.passthrough) end
end

function Agent:handle_activation_request()
  local tier = self.settings.tier or 'auto'
  if tier == 'free' then
    self:send_json({ kind = 'use_free_version' })
    return
  end

  if not self.activate_url or self.activation_notified then return end

  self.activation_notified = true
  local message = tier == 'pro' and ('Complete Supermaven Pro activation: %s'):format(self.activate_url)
    or ('Supermaven is awaiting activation. Set `settings.supermaven.tier = "free"` to auto-select the free tier, or open %s for Pro.'):format(
      self.activate_url
    )

  log.warn(message)

  if tier == 'pro' and self.settings.open_pro_url and vim.ui and vim.ui.open then
    vim.schedule(function() pcall(vim.ui.open, self.activate_url) end)
  end
end

function Agent:document_changed(path, text)
  if not path or path == '' then return end

  self.changed_documents[path] = {
    path = path,
    content = text,
  }

  if self:is_running() then self:send_json({
    kind = 'inform_file_changed',
    path = path,
  }) end
end

function Agent:purge_old_states()
  for state_id in pairs(self.state_map) do
    if state_id < self.current_state_id - self.max_state_id_retention then self.state_map[state_id] = nil end
  end
end

function Agent:submit_query(path, text, prefix)
  self:purge_old_states()

  local document_state = {
    kind = 'file_update',
    path = path,
    content = text,
  }

  local cursor_state = {
    kind = 'cursor_update',
    path = path,
    offset = #prefix,
  }

  if self.last_state and next(self.changed_documents) == nil then
    if self.last_state.cursor.path == cursor_state.path and self.last_state.cursor.offset == cursor_state.offset then
      if
        self.last_state.document.path == document_state.path
        and self.last_state.document.content == document_state.content
      then
        return self.current_state_id
      end
    end
  end

  self.changed_documents[path] = document_state

  local updates = { cursor_state }
  for _, changed in pairs(self.changed_documents) do
    updates[#updates + 1] = {
      kind = 'file_update',
      path = changed.path,
      content = changed.content,
    }
  end
  self.changed_documents = {}

  self.current_state_id = self.current_state_id + 1
  self:send_message(updates)
  self.state_map[self.current_state_id] = {
    prefix = prefix,
    completion = {},
    has_ended = false,
  }
  self.last_state = {
    cursor = cursor_state,
    document = document_state,
  }

  return self.current_state_id
end

function Agent:update_state_id(message)
  local completion_state_id = tonumber(message.stateId)
  local current_state = self.state_map[completion_state_id]
  if current_state == nil then return end

  for _, completion in ipairs(message.items) do
    current_state.completion[#current_state.completion + 1] = completion
    if completion.kind == 'end' then current_state.has_ended = true end
  end
end

function Agent:completion_text_length(completion)
  local length = 0
  for _, response_item in ipairs(completion) do
    if response_item.kind == 'text' then length = length + #response_item.text end
  end
  return length
end

function Agent:shares_common_prefix(str1, str2)
  local min_length = math.min(#str1, #str2)
  return str1:sub(1, min_length) == str2:sub(1, min_length)
end

function Agent:strip_prefix(completion, original_prefix)
  local prefix = original_prefix
  local remaining_response_items = {}

  for _, response_item in ipairs(completion) do
    if response_item.kind == 'text' then
      local text = response_item.text
      if not self:shares_common_prefix(text, prefix) then return nil end

      local trim_length = math.min(#text, #prefix)
      text = text:sub(trim_length + 1)
      prefix = prefix:sub(trim_length + 1)

      if #text > 0 then
        remaining_response_items[#remaining_response_items + 1] = {
          kind = 'text',
          text = text,
        }
      end
    elseif response_item.kind == 'delete' then
      remaining_response_items[#remaining_response_items + 1] = response_item
    elseif response_item.kind == 'dedent' then
      if #prefix > 0 then return nil end
      remaining_response_items[#remaining_response_items + 1] = response_item
    elseif #prefix == 0 then
      remaining_response_items[#remaining_response_items + 1] = response_item
    end
  end

  return remaining_response_items
end

function Agent:check_state(prefix, line_before_cursor, line_after_cursor, get_following_line, query_state_id)
  local params = {
    line_before_cursor = line_before_cursor,
    line_after_cursor = line_after_cursor,
    get_following_line = get_following_line,
    dust_strings = self.dust_strings,
    can_show_partial_line = true,
    can_retry = false,
    source_state_id = query_state_id,
  }

  local best_completion = {}
  local best_length = 0
  local best_state_id = -1

  for state_id, state in pairs(self.state_map) do
    local state_prefix = state.prefix
    if state_prefix ~= nil and #prefix >= #state_prefix and prefix:sub(1, #state_prefix) == state_prefix then
      local user_input = prefix:sub(#state_prefix + 1)
      local remaining_completion = self:strip_prefix(state.completion, user_input)
      if remaining_completion ~= nil then
        local total_length = self:completion_text_length(remaining_completion)
        if total_length > best_length or (total_length == best_length and state_id > best_state_id) then
          best_completion = remaining_completion
          best_length = total_length
          best_state_id = state_id
        end
      end
    end
  end

  return textual.derive_completion(best_completion, params)
end

function Agent:start_timer()
  if self.timer or next(self.pending) == nil then return end

  self.timer = uv.new_timer()
  self.timer:start(0, self.settings.poll_interval_ms or 25, vim.schedule_wrap(function() self:flush_pending() end))
end

function Agent:make_inline_completion(request, completion)
  if completion.kind ~= 'text' then return nil end

  local dedent = completion.dedent or ''
  if #dedent > 0 and not util.ends_with(request.line_before_cursor, dedent) then return nil end

  local text = completion.text
  while #dedent > 0 and #text > 0 and dedent:sub(1, 1) == text:sub(1, 1) do
    text = text:sub(2)
    dedent = dedent:sub(2)
  end

  text = util.trim_end(text)
  if text == '' then return nil end

  return {
    insertText = text,
    range = {
      start = {
        line = request.position.line,
        character = math.max(request.position.character - #dedent, 0),
      },
      ['end'] = {
        line = request.position.line,
        character = #request.line,
      },
    },
  }
end

function Agent:flush_pending()
  local now = uv.now()

  for request_id, pending in pairs(self.pending) do
    local state = self.state_map[pending.state_id]
    local completion = self:check_state(
      pending.prefix,
      pending.line_before_cursor,
      pending.line_after_cursor,
      pending.get_following_line,
      pending.state_id
    )

    local should_resolve = false
    local items = {}

    if completion and completion.kind == 'text' then
      local item = self:make_inline_completion(pending, completion)
      if item ~= nil and ((not completion.is_incomplete) or state and state.has_ended or now >= pending.deadline) then
        items = { item }
        should_resolve = true
      elseif item == nil and ((state and state.has_ended) or now >= pending.deadline) then
        should_resolve = true
      end
    elseif completion and completion.kind ~= 'text' then
      should_resolve = true
    elseif (state and state.has_ended) or now >= pending.deadline then
      should_resolve = true
    end

    if should_resolve then
      self.pending[request_id] = nil
      vim.schedule(function() pending.callback(nil, { items = items }) end)
    end
  end

  if next(self.pending) == nil then self:stop_timer() end
end

function Agent:request_inline_completion(document, params, callback)
  if #document.text > self.HARD_SIZE_LIMIT then
    callback(nil, { items = {} })
    return
  end

  local ok = self:ensure_started()
  if not ok then
    callback(nil, { items = {} })
    return
  end

  local context = util.extract_position_context(document.lines, params.position)
  if context == nil then
    callback(nil, { items = {} })
    return
  end

  self:document_changed(document.path, document.text)
  local state_id = self:submit_query(document.path, document.text, context.prefix)
  if state_id == nil then
    callback(nil, { items = {} })
    return
  end

  self.pending_request_id = self.pending_request_id + 1
  self.pending[self.pending_request_id] = {
    callback = callback,
    deadline = uv.now() + (self.settings.response_timeout_ms or 400),
    get_following_line = function(index)
      return util.safe_get_line(document.lines, params.position.line + 1 + index) or ''
    end,
    line = context.line,
    line_after_cursor = context.line_after_cursor,
    line_before_cursor = context.line_before_cursor,
    position = params.position,
    prefix = context.prefix,
    state_id = state_id,
  }

  self:flush_pending()
  self:start_timer()
end

return Agent
