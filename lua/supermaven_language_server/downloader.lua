local log = require('supermaven_language_server.logger')

local uv = vim.uv

local M = {
  cached_path = nil,
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

local function request_sync(url, opts, timeout_ms)
  local done, err, response = false, nil, nil
  local request = vim.net.request(url, opts or {}, function(request_err, res)
    err = request_err
    response = res
    done = true
  end)

  local ok = vim.wait(timeout_ms, function() return done end, 50, false)

  if not ok then
    request:close()
    return nil, ('Timed out fetching %s'):format(url)
  end

  if err then return nil, err end

  return response, nil
end

local function rename_file(from, to)
  if uv.fs_stat(to) then uv.fs_unlink(to) end

  local ok, err = uv.fs_rename(from, to)
  if ok then return true end
  return nil, err or ('Could not rename %s to %s'):format(from, to)
end

function M.fetch(settings)
  local binary_settings = settings.binary or {}
  if binary_settings.path and binary_settings.path ~= '' then return binary_settings.path end

  if M.cached_path and uv.fs_stat(M.cached_path) then return M.cached_path end

  if binary_settings.download == false then
    return nil, 'Supermaven binary download is disabled and no binary path was configured.'
  end

  local platform = platform_name()
  local arch = arch_name()
  if not platform or not arch then return nil, 'Unsupported platform for Supermaven binary download.' end

  local path = binary_path(platform, arch)
  if uv.fs_stat(path) then
    M.cached_path = path
    return path
  end

  vim.fn.mkdir(binary_dir(platform, arch), 'p')

  local timeout_ms = binary_settings.download_timeout_ms or 30000
  local discovery_url = ('https://supermaven.com/api/download-path-v2?platform=%s&arch=%s&editor=neovim'):format(
    platform,
    arch
  )
  local discovery_res, discovery_err = request_sync(discovery_url, { retry = 3 }, timeout_ms)
  if not discovery_res then return nil, ('Could not resolve Supermaven download URL: %s'):format(discovery_err) end

  local ok, decoded = pcall(vim.json.decode, discovery_res.body)
  local download_url = ok and decoded and decoded.downloadUrl or nil
  if not download_url then return nil, 'Supermaven download discovery returned an invalid payload.' end

  local temp_path = path .. '.tmp'
  log.info(('Downloading Supermaven binary to %s'):format(path))

  local _, download_err = request_sync(download_url, { retry = 3, outpath = temp_path }, timeout_ms)
  if download_err then
    uv.fs_unlink(temp_path)
    return nil, ('Could not download Supermaven binary: %s'):format(download_err)
  end

  if not uv.fs_stat(temp_path) then return nil, 'Supermaven binary download did not produce an output file.' end

  local renamed, rename_err = rename_file(temp_path, path)
  if not renamed then
    uv.fs_unlink(temp_path)
    return nil, ('Could not finalize Supermaven binary download: %s'):format(rename_err)
  end

  if platform ~= 'windows' then uv.fs_chmod(path, 493) end

  M.cached_path = path
  return path
end

return M
