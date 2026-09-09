fx_version 'cerulean'
game 'rdr3'

author 'VEX Framework'
description 'Secure progress-action and task-locking dependency for RedM'
version '1.0.0'

lua54 'yes'

ui_page 'ui/index.html'

shared_scripts {
    'config.lua',
    'shared/sh_utils.lua'
}

client_scripts {
    'client/cl_animation.lua',
    'client/cl_controls.lua',
    'client/cl_main.lua'
}

server_scripts {
    'server/sv_trust.lua',
    'server/sv_main.lua'
}

files {
    'ui/index.html',
    'ui/style.css',
    'ui/app.js'
}

dependencies {
    'vex_core',
    'vex_callback'
}