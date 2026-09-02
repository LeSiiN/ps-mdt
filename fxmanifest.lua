fx_version 'cerulean'
lua54 'yes'
use_experimental_fxv2_oal 'yes'
game 'gta5'

name 'ps-mdt'
author "Project Sloth Development Team"
description 'Project Sloth MDT'
version '3.1.4'

ui_page 'web/dist/index.html'

-- ps_lib is gone. Everything it provided (logging, callbacks, notifications,
-- framework getters) now lives in bridge/ inside this resource and is built on
-- ox_lib + the qb-core API. qbx_core exposes that same API through its
-- compatibility layer (`provide 'qb-core'`), so QBCore and Qbox both work
-- without a separate framework setting.
dependencies {
  'oxmysql',
  'ox_lib'
}

-- Order matters: ox_lib first so `lib` exists, then config.lua so `Config`
-- exists, then the logger which creates the shared `MDT` table.
shared_scripts {
  '@ox_lib/init.lua',
  'config.lua',
  'bridge/shared/*.lua'
}

-- bridge/ before client/ so `MDT` is fully populated before any feature file
-- runs. Globs are loaded alphabetically, so framework.lua precedes utils.lua.
client_scripts {
  'bridge/client/*.lua',
  'client/**.lua'
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'bridge/server/*.lua',
  'server/**.lua'
}

files {
  'web/dist/index.html',
  'web/dist/**/*'
}

data_file 'DLC_ITYP_REQUEST' 'stream/ps-mdt.ytyp'

-- Server convars (set in server.cfg):
-- set   ps_mdt_fivemanage_key_images "YOUR_FIVEMANAGE_IMAGES_API_KEY"
-- set   ps_mdt_fivemanage_key_logs   "YOUR_FIVEMANAGE_LOGS_API_KEY"
-- setr  ps_mdt_debug 1   -- verbose logging without editing config.lua
convar_category 'PS-MDT' {
  'Settings for ps-mdt resource',
  {
    { 'FiveManage Images API Key', 'ps_mdt_fivemanage_key_images', 'CV_STRING', '' },
    { 'FiveManage Logs API Key',   'ps_mdt_fivemanage_key_logs',   'CV_STRING', '' },
    { 'Debug logging',             'ps_mdt_debug',                 'CV_BOOL',   'false' },
  }
}
