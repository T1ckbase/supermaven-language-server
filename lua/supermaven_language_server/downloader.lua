local log = require('supermaven_language_server.logger')

local uv = vim.uv

local M = {
  cached_path = nil,
  pending = false,
  waiters = {},
}

local function platform_name()
  local sysname = uv.os_uname().sysname
  if sysname == 'Darwin' then return 'macosx' end
  if sysname == 'Linux' then return 'linux' end
  if sysname == 'Windows_NT' then return 'windows' end
  return nil
end

local function arch_name()
  local machine = uv.os_uname().machine
  if machine == 'arm64' or machine == 'aarch64' then return 'aarch64' end
  if machine == 'x86_64' or machine == 'AMD64' then return 'x86_64' end
  return nil
end

local function binary_dir(platform, arch)
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'supermaven-language-server', 'binary', 'v20', platform .. '-' .. arch)
end

local function binary_path(platform, arch)
  local name = platform == 'windows' and 'sm-agent.exe' or 'sm-agent'
  return vim.fs.joinpath(binary_dir(platform, arch), name)
end

local function resolve_path(settings)
  local binary_settings = settings.binary or {}
  if binary_settings.path and binary_settings.path ~= '' then
    if uv.fs_stat(binary_settings.path) then
      M.cached_path = binary_settings.path
      return binary_settings.path
    end
    return nil, ('Configured Supermaven binary does not exist: %s'):format(binary_settings.path)
  end

  if M.cached_path and uv.fs_stat(M.cached_path) then return M.cached_path end

  local platform = platform_name()
  local arch = arch_name()
  if not platform or not arch then return nil, 'Unsupported platform for Supermaven binary download.' end

  local path = binary_path(platform, arch)
  if uv.fs_stat(path) then
    M.cached_path = path
    return path
  end

  if binary_settings.download == false then
    return nil, 'Supermaven binary download is disabled and no binary path was configured.'
  end

  return nil
end

local function rename_file(from, to)
  if uv.fs_stat(to) then uv.fs_unlink(to) end

  local ok, err = uv.fs_rename(from, to)
  if ok then return true end
  return nil, err or ('Could not rename %s to %s'):format(from, to)
end

local function dispatch_waiters(path, err)
  local waiters = M.waiters
  M.waiters = {}
  M.pending = false

  for _, callback in ipairs(waiters) do
    vim.schedule(function() callback(path, err) end)
  end
end

local function request_async(url, opts, timeout_ms, callback)
  local done = false
  local timer

  local function finish(err, response)
    if done then return end

    done = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    callback(err, response)
  end

  local request = vim.net.request(url, opts or {}, function(request_err, res) finish(request_err, res) end)

  if timeout_ms and timeout_ms > 0 then
    timer = uv.new_timer()
    timer:start(
      timeout_ms,
      0,
      vim.schedule_wrap(function()
        request:close()
        finish(('Timed out fetching %s'):format(url), nil)
      end)
    )
  end
end

function M.ready(settings) return resolve_path(settings) end

function M.prefetch(settings, callback)
  local path, err = resolve_path(settings)
  if path or err then
    if callback then vim.schedule(function() callback(path, err) end) end
    return
  end

  if callback then M.waiters[#M.waiters + 1] = callback end

  if M.pending then return end

  M.pending = true

  local platform = assert(platform_name())
  local arch = assert(arch_name())
  local path_to_download = binary_path(platform, arch)
  local binary_settings = settings.binary or {}
  local timeout_ms = binary_settings.download_timeout_ms or 30000
  local discovery_url = ('https://supermaven.com/api/download-path-v2?platform=%s&arch=%s&editor=neovim'):format(
    platform,
    arch
  )

  vim.fn.mkdir(binary_dir(platform, arch), 'p')
  log.info(('Downloading Supermaven binary to %s'):format(path_to_download))

  request_async(discovery_url, { retry = 3 }, timeout_ms, function(discovery_err, discovery_res)
    if discovery_err then
      dispatch_waiters(nil, ('Could not resolve Supermaven download URL: %s'):format(discovery_err))
      return
    end

    local ok, decoded = pcall(vim.json.decode, discovery_res.body)
    local download_url = ok and decoded and decoded.downloadUrl or nil
    if not download_url then
      dispatch_waiters(nil, 'Supermaven download discovery returned an invalid payload.')
      return
    end

    local temp_path = path_to_download .. '.tmp'
    request_async(download_url, { retry = 3, outpath = temp_path }, timeout_ms, function(download_err)
      if download_err then
        uv.fs_unlink(temp_path)
        dispatch_waiters(nil, ('Could not download Supermaven binary: %s'):format(download_err))
        return
      end

      if not uv.fs_stat(temp_path) then
        dispatch_waiters(nil, 'Supermaven binary download did not produce an output file.')
        return
      end

      local renamed, rename_err = rename_file(temp_path, path_to_download)
      if not renamed then
        uv.fs_unlink(temp_path)
        dispatch_waiters(nil, ('Could not finalize Supermaven binary download: %s'):format(rename_err))
        return
      end

      if platform ~= 'windows' then uv.fs_chmod(path_to_download, 493) end

      M.cached_path = path_to_download
      dispatch_waiters(path_to_download, nil)
    end)
  end)
end

return M
