local M = {}

local levels = {
  off = 0,
  error = 1,
  warn = 2,
  info = 3,
  debug = 4,
}

local notify_levels = {
  error = vim.log.levels.ERROR,
  warn = vim.log.levels.WARN,
  info = vim.log.levels.INFO,
  debug = vim.log.levels.DEBUG,
}

local state = {
  level = 'warn',
}

local function should_log(level)
  local current = levels[state.level] or levels.warn
  local target = levels[level] or levels.info
  return current >= target and current > 0
end

local function log_path() return vim.fs.joinpath(vim.fn.stdpath('cache'), 'supermaven-language-server.log') end

local function append(level, message)
  if vim.fn.isdirectory(vim.fn.stdpath('cache')) == 0 then vim.fn.mkdir(vim.fn.stdpath('cache'), 'p') end

  local file = io.open(log_path(), 'a')
  if not file then return end
  file:write(string.format('[%-5s %s] %s\n', level:upper(), os.date('%Y-%m-%d %H:%M:%S'), message))
  file:close()
end

function M.configure(settings)
  local level = settings and settings.log_level
  if level ~= nil and levels[level] ~= nil then state.level = level end
end

function M.debug(message)
  if not should_log('debug') then return end
  append('debug', message)
end

function M.info(message)
  if not should_log('info') then return end
  append('info', message)
end

function M.warn(message)
  if not should_log('warn') then return end
  append('warn', message)
  vim.schedule(function() vim.notify(message, notify_levels.warn, { title = 'Supermaven' }) end)
end

function M.error(message)
  if not should_log('error') then return end
  append('error', message)
  vim.schedule(function() vim.notify(message, notify_levels.error, { title = 'Supermaven' }) end)
end

return M
