local version = tostring(vim.version())

return {
  name = 'supermaven',
  cmd = function(dispatchers, config) return require('supermaven_language_server.server').cmd(dispatchers, config) end,
  root_markers = { '.git' },
  workspace_required = false,
  init_options = {
    editorInfo = {
      name = 'Neovim',
      version = version,
    },
    editorPluginInfo = {
      name = 'supermaven-language-server',
      version = version,
    },
  },
  settings = {
    supermaven = {
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
    },
  },
}
