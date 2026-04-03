local Agent = require('supermaven_language_server.agent')
local log = require('supermaven_language_server.logger')
local util = require('supermaven_language_server.util')

local protocol = vim.lsp.protocol

local M = {}

M.defaults = {
  tier = 'auto',
  ignore_filetypes = {},
  log_level = 'warn',
  poll_interval_ms = 25,
  response_timeout_ms = 400,
  open_pro_url = false,
  binary = {
    path = nil,
    download = true,
    download_timeout_ms = 30000,
  },
}

local Transport = {}
Transport.__index = Transport

local function merge_settings(config, initialize_params)
  local settings = vim.deepcopy(M.defaults)

  local config_settings = config and config.settings and config.settings.supermaven
  if type(config_settings) == 'table' then settings = vim.tbl_deep_extend('force', settings, config_settings) end

  local init_settings = initialize_params and initialize_params.initializationOptions
  if type(init_settings) == 'table' and type(init_settings.supermaven) == 'table' then
    settings = vim.tbl_deep_extend('force', settings, init_settings.supermaven)
  end

  return settings
end

function Transport.new(dispatchers, config)
  local settings = merge_settings(config)
  log.configure(settings)

  return setmetatable({
    agent = Agent.new(settings),
    closing = false,
    config = config or {},
    dispatchers = dispatchers,
    documents = {},
    request_id = 0,
    settings = settings,
  }, Transport)
end

function Transport:next_request_id()
  self.request_id = self.request_id + 1
  return self.request_id
end

function Transport:finish_request(request_id, notify_reply_callback)
  if notify_reply_callback then vim.schedule(function() pcall(notify_reply_callback, request_id) end) end
end

function Transport:get_document(uri)
  local existing = self.documents[uri]
  if existing then return existing end

  local ok, bufnr = pcall(vim.uri_to_bufnr, uri)
  if not ok or not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then return nil end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, '\n')
  local filetype = vim.bo[bufnr].filetype
  local document = {
    filetype = filetype,
    lines = lines,
    path = util.uri_to_path(uri),
    text = text,
    uri = uri,
  }
  self.documents[uri] = document
  return document
end

function Transport:update_document(text_document, text)
  local uri = text_document.uri
  local lines = util.split_lines(text)
  local filetype = util.filetype_for_uri(uri, text_document.languageId)
  local document = {
    filetype = filetype,
    lines = lines,
    path = util.uri_to_path(uri),
    text = text,
    uri = uri,
    version = text_document.version,
  }

  self.documents[uri] = document
  return document
end

function Transport:apply_settings(settings)
  self.settings = vim.tbl_deep_extend('force', self.settings, settings)
  log.configure(self.settings)
  self.agent:update_settings(self.settings)
end

function Transport:on_initialize(params, callback)
  self:apply_settings(merge_settings(self.config, params))

  callback(nil, {
    capabilities = {
      positionEncoding = 'utf-8',
      textDocumentSync = {
        openClose = true,
        change = protocol.TextDocumentSyncKind.Full,
      },
      inlineCompletionProvider = true,
    },
    serverInfo = {
      name = 'supermaven-language-server',
    },
  })
end

function Transport:on_inline_completion(params, callback)
  local document = self:get_document(params.textDocument.uri)
  if not document or not document.path or document.path == '' then
    callback(nil, { items = {} })
    return
  end

  if util.is_ignored_filetype(self.settings.ignore_filetypes, document.filetype) then
    callback(nil, { items = {} })
    return
  end

  self.agent:request_inline_completion(document, params, callback)
end

function Transport:on_shutdown(callback)
  self.agent:stop()
  self.closing = true
  callback(nil, nil)
end

function Transport:request(method, params, callback, notify_reply_callback)
  local request_id = self:next_request_id()
  callback = callback or function() end

  local ok, err = pcall(function()
    if method == 'initialize' then
      self:on_initialize(params, callback)
    elseif method == 'textDocument/inlineCompletion' then
      self:on_inline_completion(params, callback)
    elseif method == 'shutdown' then
      self:on_shutdown(callback)
    else
      callback(nil, nil)
    end
  end)

  self:finish_request(request_id, notify_reply_callback)

  if not ok then
    log.error(('LSP request failed for %s: %s'):format(method, err))
    callback({ code = -32603, message = err }, nil)
  end

  return true, request_id
end

function Transport:notify(method, params)
  local ok, err = pcall(function()
    if method == 'textDocument/didOpen' then
      local document = self:update_document(params.textDocument, params.textDocument.text)
      if
        document.path
        and document.path ~= ''
        and not util.is_ignored_filetype(self.settings.ignore_filetypes, document.filetype)
      then
        self.agent:document_changed(document.path, document.text)
      end
      return
    end

    if method == 'textDocument/didChange' then
      local text = util.get_full_change_text(params)
      local existing = self.documents[params.textDocument.uri]
      if text ~= nil then
        local document = self:update_document(params.textDocument, text)
        if
          document.path
          and document.path ~= ''
          and not util.is_ignored_filetype(self.settings.ignore_filetypes, document.filetype)
        then
          self.agent:document_changed(document.path, document.text)
        end
      elseif existing and existing.path and existing.path ~= '' then
        self.agent:document_changed(existing.path, existing.text)
      end
      return
    end

    if method == 'textDocument/didClose' then
      self.documents[params.textDocument.uri] = nil
      return
    end

    if method == 'workspace/didChangeConfiguration' and type(params.settings) == 'table' then
      local settings = params.settings.supermaven or params.settings
      if type(settings) == 'table' then self:apply_settings(settings) end
      return
    end

    if method == 'exit' then
      self.agent:stop()
      self.closing = true
      self.dispatchers.on_exit(0, 15)
    end
  end)

  if not ok then log.error(('LSP notification failed for %s: %s'):format(method, err)) end

  return false
end

function Transport:is_closing() return self.closing end

function Transport:terminate()
  self.agent:stop()
  self.closing = true
end

function M.cmd(dispatchers, config)
  local transport = Transport.new(dispatchers, config)

  return {
    request = function(method, params, callback, notify_reply_callback)
      return transport:request(method, params, callback, notify_reply_callback)
    end,
    notify = function(method, params) return transport:notify(method, params) end,
    is_closing = function() return transport:is_closing() end,
    terminate = function() transport:terminate() end,
  }
end

return M
