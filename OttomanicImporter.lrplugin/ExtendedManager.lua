--[[
        ExtendedManager.lua
--]]


local ExtendedManager, dbg, dbgf = Manager:newClass{ className='ExtendedManager' }



--[[
        Constructor for extending class.
--]]
function ExtendedManager:newClass( t )
    return Manager.newClass( self, t )
end



--[[
        Constructor for new instance object.
--]]
function ExtendedManager:new( t )
    return Manager.new( self, t )
end



--- Initialize global preferences.
--
function ExtendedManager:_initGlobalPrefs()
    -- Instructions: delete the following line (or set property to nil) if this isn't an export plugin.
    --fprops:setPropertyForPlugin( _PLUGIN, 'exportMgmtVer', "2" ) -- a little add-on here to support export management. '1' is legacy (rc-common-modules) mgmt.
    -- Instructions: uncomment to support these external apps in global prefs, otherwise delete:
    -- app:initGlobalPref( 'exifToolApp', "" )
    -- app:initGlobalPref( 'mogrifyApp', "" )
    -- app:initGlobalPref( 'sqliteApp', "" )

    -- leave log dir entirely up to user - until specified, it will automatically use Lr default.
    -- app:initGlobalPref( 'logDir', LrPathUtils.child( LrPathUtils.parent( LrApplication.activeCatalog():getPath() ), 'com.robcole.logs' ) )

    app:initGlobalPref( 'customSetNameAuto', "Add in Place" )
    app:initGlobalPref( 'customSetNameManual', "Import from Cards" )
    app:initGlobalPref( 'autoImportEnable', true )
    app:initGlobalPref( "recursive", false )
    app:initGlobalPref( "readMetadata", false )
    app:initGlobalPref( "customText_1", "" )
    app:initGlobalPref( "customText_2", "" )
    app:initGlobalPref( "importNumber", 1 ) -- replaces customNum_1
    app:initGlobalPref( "importCritEna", false ) -- enable additional import criteria (e.g. duplicate checking).
    app:initGlobalPref( "origFilenameEna", false ) -- enable original filename support.
    
    --app:registerPreset( "Export After Import", 3 ) -- not sure why no others are registered (commented out 5/Jan/2015 14:36 since functionality is built-in to default preset now).
    
    Manager._initGlobalPrefs( self )
end



--- Initialize local preferences for preset.
--
function ExtendedManager:_initPrefs( presetName )
    -- Instructions: uncomment to support these external apps in global prefs, otherwise delete:
    -- app:initPref( 'exifToolApp', "", presetName )
    -- app:initPref( 'mogrifyApp', "", presetName ) -- *** NOTE: CONVERT IS HANDLED AS A SETTING NOT A PREFERENCE.
    -- app:initPref( 'sqliteApp', "", presetName )
    -- *** Instructions: delete this line if no async init or continued background processing:
    --app:initPref( 'background', false, presetName ) -- true to support on-going background processing, after async init (auto-update most-sel photo).
    -- *** Instructions: delete these 3 if not using them:
    --app:initPref( 'processTargetPhotosInBackground', false, presetName )
    --app:initPref( 'processFilmstripPhotosInBackground', false, presetName )
    --app:initPref( 'processAllPhotosInBackground', false, presetName )
    app:initPref( 'autoMirrorFolders', false, presetName )
    app:initPref( 'autoMirrorImportExt', "", presetName )
    app:initPref( 'autoMirrorReadMetadata', false, presetName )
    app:initPref( 'autoMirrorRemoveDeletedPhotos', false, presetName )
    app:initPref( 'autoImportSelFolder', false, presetName )
    app:initPref( 'autoImportSelFolderCont', false, presetName )
    app:initPref( 'autoImportSelFolderReadMetadata', false, presetName )
    app:initPref( 'autoImportSelFolderRemoveDeletedPhotos', false, presetName )
    app:initPref( 'autoImportSelFolderInterval', 1, presetName )
    app:initPref( 'autoImportSelFolderRecursive', false, presetName )
    app:initPref( 'autoImportSelFolderCustomSetName', "Add in Place", presetName ) -- aka import settings.
--    app:initPref( 'autoImportSelFolderCustomSetNameItems', {}, presetName ) -- popup items
    app:initPref( 'autoImportSelFolderCustomText_1', "", presetName )
    app:initPref( 'autoImportSelFolderCustomText_2', "", presetName )
    app:initPref( 'autoImportSelFolderCustomNum_1', 1, presetName )
    app:initPref( 'dirChgAppVerbose', false, presetName )
    Manager._initPrefs( self, presetName )
end



--- Start of plugin manager dialog.
-- 
function ExtendedManager:startDialogMethod( props )
    -- *** Instructions: uncomment if you use these apps and their exe is bound to ordinary property table (not prefs).
    view:setObserver( prefs, app:getGlobalPrefKey( 'autoImportEnable' ), Manager, Manager.prefChangeHandler )
    Manager.startDialogMethod( self, props ) -- adds observer to all props.
end



--- Preference change handler.
--
--  @usage      Handles preference changes.
--              <br>Preferences not handled are forwarded to base class handler.
--  @usage      Handles changes that occur for any reason, one of which is user entered value when property bound to preference,
--              <br>another is preference set programmatically - recursion guarding is essential.
--
function ExtendedManager:prefChangeHandlerMethod( _id, _prefs, key, value )
    local name = app:getGlobalPrefName( key )
    if name == 'autoImportEnable' then
        if not value then
            -- this warning is not exactly true as stated, and is maybe overkill: user is warned when attempting to initiate auto-importing when disabled.
            --app:show{ warning="Remember to reenable. Having it enabled has no effect if no folders have been started for auto-importing." }
        end
        -- bound directly to pref, so no additional change handling is necessary.
    else
        --Debug.pause( name )
        Manager.prefChangeHandlerMethod( self, _id, _prefs, key, value ) -- also async: so far no ill effects(?) ###3
    end
end



--- Property change handler.
--
--  @usage      Properties handled by this method, are either temporary, or
--              should be tied to named setting preferences.
--
function ExtendedManager:propChangeHandlerMethod( props, name, value, call )
    if app.prefMgr and (app:getPref( name ) == value) then -- eliminate redundent calls.
        -- Note: in managed cased, raw-pref-key is always different than name.
        -- Note: if preferences are not managed, then depending on binding,
        -- app-get-pref may equal value immediately even before calling this method, in which case
        -- we must fall through to process changes.
        return
    end
    if name == 'autoImportSelFolder' then
        if value then
            local temp, perm = ottomanic.tempPaths, ottomanic.permPaths
            if tab:isNotEmpty( temp ) or tab:isNotEmpty( perm ) then
                app:show{ info="Ad-hoc auto-importing takes precedence over auto-importing upon folder selection (when folder is selected which is already auto-importing ad-hoc).",
                    actionPrefKey = "enabling auto-import upon folder selection with ad-hoc auto-importing",
                }
            -- else nada
            end
        -- else x
        end
    elseif name == 'autoMirrorFolders' then
        if value then
            local temp, perm = ottomanic.tempPaths, ottomanic.permPaths
            if tab:isNotEmpty( temp ) or tab:isNotEmpty( perm ) then
                app:show{ info="Ad-hoc auto-importing takes precedence over auto-mirroring, when folders are in both trees. If ad-hoc stopped, mirroring will resume for said folders.",
                    actionPrefKey = "enabling auto-mirror folders with ad-hoc auto-importing",
                }
            -- else nada
            end
        end
    end
    -- Note: preference key is different than name.
    Manager.propChangeHandlerMethod( self, props, name, value, call )
end



function ExtendedManager:recomputeCsItems()
	local customSetName = app:getPref( 'autoImportSelFolderCustomSetName' )
    local setKey = systemSettings:getKey( 'importCustomSets' ) -- get custom set key for current preset.
    local names = systemSettings:getArrayNames( setKey ) or {}
    local cs = {}
    local found = false
    for i, name in ipairs( names ) do
        cs[#cs + 1] = { title=name, value=name }
        if customSetName == name then
            found = true
        end
    end
    self.props['autoImportSelFolderCustomSetNameItems'] = cs -- items are linked to this.
    if found then
        -- 
    elseif #cs > 0 then
        app:setPref( 'autoImportSelFolderCustomSetName', cs[1].value ) -- value is linked to this.
    else
        app:setPref( 'autoImportSelFolderCustomSetName', "" )
    end
end



function ExtendedManager:presetChangeCallback( v )
    Manager.presetChangeCallback( self, v )
    self:recomputeCsItems()
end



--- Sections for bottom of plugin manager dialog.
-- 
function ExtendedManager:sectionsForBottomOfDialogMethod( vf, props)

    local appSection = {}
    if app.prefMgr then
        appSection.bind_to_object = props
    else
        appSection.bind_to_object = prefs
    end
    
	appSection.title = app:getAppName() .. " Settings"
	appSection.synopsis = bind{ key='presetName', object=prefs }
	appSection.spacing = vf:label_spacing()
	
	-- add (vertical) space ( default=5 )
	local function space( amt )
	    appSection[#appSection + 1] = vf:spacer{ height=amt or 5 }
	end
	local function sep()
	    appSection[#appSection + 1] = vf:separator{ fill_horizontal=1 }
	end
	--[[
	local function subsection( title )
	    space()
	    sep()
	    space()
        appSection[#appSection + 1] = vf:row {
            vf:spacer{ width=share'label_width' }, -- used in 'Settings' class.
            vf:static_text {
                title = title,
                width = share( title ),
            },
        }
        appSection[#appSection + 1] = vf:row {
            vf:spacer{ width=share'label_width' }, -- used in 'Settings' class.
            vf:separator {
                width = share( title ),
            },
        }
	    space()
	end
	--]]
	
	space()
	appSection[#appSection + 1] = vf:row {
	    vf:checkbox {
	        title = "Enable Auto-importing",
	        value = app:getGlobalPrefBinding( 'autoImportEnable' ),
	        tooltip = "Must be checked for any auto-importing to work. uncheck to pause auto-importing...",
	    },
	    vf:spacer{ width=15 },
        vf:static_text {
            title = "Background process",
            width = share 'label_width',
        },
        vf:static_text {
            bind_to_object = prefs,
            title = app:getGlobalPrefBinding( 'backgroundState' ),
            width_in_chars = 45, -- ok I guess.
            tooltip = 'background task status',
        },
	}

    --subsection( "Dir/File Change Notifier App" )
	--appSection[#appSection + 1] = vf:spacer{ height=10 }
	--appSection[#appSection + 1] = vf:separator{ fill_horizontal=1 }
	--appSection[#appSection + 1] = vf:spacer{ height=10 }

    --[[
    appSection[#appSection + 1] =
        vf:row {
            bind_to_object = props,
            vf:static_text {
                title = "Presence:",
                width = share 'label_width',
            },    
            vf:static_text {
                title = app:getGlobalPrefBinding( 'dirChgAppDescr' ),
                width_in_chars = 80, -- way overkill @this.
                tooltip = "online, offline, not-responding, ...",
            },
        }
    --]]
    
    --[[
    appSection[#appSection + 1] =
        vf:row {
            vf:static_text {
                title = "External App",
	            width = share'prim_lbl_w',
            },
            vf:checkbox {
                title = "Verbose",
                value = bind( 'dirChgAppVerbose' ),
                tooltip = "If dir-chg app not already running, start it up in verbose logging mode (for trouble-shooting..).",
            },
            vf:push_button {
                title = "Start",
                action = function( button )
                    app:pcall{ name="Start App", async=true, guard=App.guardVocal, progress=true, function( call )
                        local s, m = dirChgApp:assureRunning( props.dirChgAggApp ) -- synchronous
                        call:setCaption( "Dialog box needs your attention.." )
                        if s then
                            app:show{ info="App is running." }
                        else
                            app:show{ warning=m }
                        end
                    end }
                end,
            },
            vf:push_button {
                title = "Stop",
                action = function( button )
                    app:pcall{ name="Stop App", async=true, guard=App.guardVocal, progress=true, main=function( call )
                        local s, m = dirChgApp:quit()
                        call:setCaption( "Dialog box needs your attention.." )
                        if s then
                            app:show{ info="App quit." }
                        else
                            app:show{ info="App did not respond - perhaps it wasn't running.." }
                        end
                    end }
                end,
            },
        }    
    --]]

    --[=[    
    appSection[#appSection + 1] = vf:spacer{ height=5 }
    appSection[#appSection + 1] =
        vf:row {
            bind_to_object = props,
            vf:static_text {
                title = "Startup Parameters:",
                width = share 'label_width',
            },    
            vf:checkbox {
                title = "Verbose",
                value = bind( 'dirChgAppVerbose' ),
                tooltip = "If dir-chg app not already running, start it up in verbose logging mode (for trouble-shooting..).",
            },
            --[[
            vf:checkbox {
                title = "Online",
                value = app:getGlobalPrefBinding( 'dirChgAppOnline' ), -- ditto.
                tooltip = "If dir-chg app not already running, start it up with FTP enabled (online).",
            },
            --]]
        }
    --]=]
        
    --[[        
    appSection[#appSection + 1] = vf:row {
        vf:static_text {
            title = "Service Summary:",
            width = share 'label_width',
        },    
        vf:static_text {
            title = app:getGlobalPrefBinding( 'ftpServiceSumm' ),
            width_in_chars = 80, -- way overkill @this.
            tooltip = "Services exiting, active jobs, total number of tasks...",
        },
    }--]]
	
	appSection[#appSection + 1] = vf:spacer{ height=10 }
	appSection[#appSection + 1] = vf:separator{ fill_horizontal=1 }
	appSection[#appSection + 1] = vf:spacer{ height=10 }

    local autoMirrorEnaBinding = binding:getMatchBinding{ props=prefs, trueKeys={ app:getGlobalPrefKey( 'autoImportEnable' ), app:getPrefKey( 'autoMirrorFolders' ) } }

	appSection[#appSection + 1] = vf:row {
	    vf:checkbox {
	        title = "Auto-mirror Folders",
	        value = bind'autoMirrorFolders',
	        enabled = app:getGlobalPrefBinding( 'autoImportEnable' ),
	        tooltip = "Check this box to have all or specified folders in Lightroom mirror their counterpart on disk. Click the 'Edit Additional Settings' button below for more options.",
	        width=share'prim_lbl_w',
	    },
	    vf:spacer{ width=5 },
	    vf:static_text {
	        title = "Import Extensions:",
	        width=share'sec_lbl_w',
	        enabled = autoMirrorEnaBinding,
	    },
	    vf:edit_field {
	        value = bind'autoMirrorImportExt',
	        width_in_chars = 20,
	        tooltip = "Enter a list of extensions subject to auto-importing to honor auto-mirror and/or catalog-sync functions (separated by commas); or leave blank to import all possible importables.\n \n*** Case-sensitive, so if you want 'JPG' and/or 'jpg' - enter both.",
	        enabled = autoMirrorEnaBinding,
	    },
	    vf:spacer{ width=10 },
	    --LrView.conditionalItem( 
	    --    app:isAdvDbgEna(),
    	    vf:push_button { -- same as menu function
    	        title = "Catalog Sync",
    	        tooltip = "Does the same thing as similarly named feature in Library menu (plugin extras), *except* for the addition of initially checked auto-mirroring folders. Also, initial settings in form will come from here..\n \n*** Useful for seeing which folders are auto-mirroring, even if you cancel the sync.",
    	        action = function( button )
    	            app:pcall{ name="Init Folders", async=true, function( call )
    	                local mirrorFolders = {}
        	            for path, spec in pairs( background.mirrorPaths ) do
        	                mirrorFolders[#mirrorFolders + 1] = cat:getFolderByPath( path, true ) -- true => bypass folder cache (I've not managed initialization..).
        	            end
        	            ottomanic:catalogSync( button.title, mirrorFolders, app:getPref( 'autoMirrorImportExt' ), app:getPref( 'autoMirrorReadMetadata' ), app:getPref( 'autoMirrorRemoveDeletedPhotos' ) ) -- runs as a service.
        	        end } -- no finale.
    	        end,
    	    }
    	--),
	}
	
	if app:lrVersion() >= 5 then
    	appSection[#appSection + 1] = vf:row {
    	    vf:checkbox {
    	        title = "Auto-read metadata",
    	        value = bind'autoMirrorReadMetadata', -- props -> prefs via change handler.
    	        enabled = autoMirrorEnaBinding,
    	        tooltip = "If checked, then when photo files (or xmp sidecars) are changed outside Lightroom, metadata will automatically be read from changed file into the catalog; if unchecked, Ottomanic Importer will ignore file changes (there will be an entry in log file if verbose mode is enabled, but that's all).\n \n*** Consider saving all metadata, or at least reviewing metadata statuses before enabling this feature, so you don't inadvertently lose catalog settings.",
	            width=share'prim_lbl_w',
    	    },
    	    vf:spacer{ width=5 },
    	    vf:checkbox {
    	        title = "Auto-remove deleted photos",
    	        value = bind'autoMirrorRemoveDeletedPhotos', -- props -> prefs via change handler.
    	        enabled = autoMirrorEnaBinding,
    	        tooltip = "If checked, photos will be removed from catalog if corresponding source files no longer exist, provided parent folder is still present/online."
    	    },
    	}
    else
        appSection[#appSection + 1] = vf:column {
            vf:spacer{ height=7 },
            vf:static_text {
                title = "In Lr5+, options for auto-reading changed metadata would be here.",
            },
        }
    end
	
	appSection[#appSection + 1] = vf:spacer{ height=10 }
	appSection[#appSection + 1] = vf:separator{ fill_horizontal=1 }
	appSection[#appSection + 1] = vf:spacer{ height=10 }
	local aiSelFolderEnableBinding = bind { -- auto-import selected-folder enable binding.
        keys = {
            {
                key = app:getGlobalPrefKey( 'autoImportEnable' ),
                bind_to_object = prefs,
                -- key is unique.
            },
            {
                key = 'autoImportSelFolder',
                bind_to_object = props,
                -- key is unique.
            },
        },
        operation = function( binder, value, toUi )
            return app:getGlobalPref( 'autoImportEnable' ) and props.autoImportSelFolder
        end
    }
    local contEnaBinding = bind {
        keys = {
            {
                key = app:getGlobalPrefKey( 'autoImportEnable' ),
                bind_to_object = prefs,
                -- key is unique.
            },
            {
                key = 'autoImportSelFolder',
                bind_to_object = props,
                -- key is unique.
            },
            {
                key = 'autoImportSelFolderCont',
                bind_to_object = props,
                -- key is unique.
            },
        },
        operation = function( binder, value, toUi )
            return app:getGlobalPref( 'autoImportEnable' ) and props.autoImportSelFolder and props.autoImportSelFolderCont
        end
    }
	appSection[#appSection + 1] = vf:row {
	    vf:checkbox {
	        bind_to_object = props,
	        title = "Auto-import upon folder selection",
	        value = bind 'autoImportSelFolder',
	        enabled = bind {
                keys = {
                    {
                        key = app:getGlobalPrefKey( 'autoImportEnable' ),
                        bind_to_object = prefs,
                        -- key is unique.
                    },
                },
                operation = function( binder, value, toUi )
                    return app:getGlobalPref( 'autoImportEnable' )
                end,
	        },
	        tooltip = "Auto import upon folder selection (once).",
	    },
	    vf:checkbox {
	        bind_to_object = props,
	        title = "Subfolders too",
	        value = bind 'autoImportSelFolderRecursive',
	        enabled = aiSelFolderEnableBinding,
	        tooltip = "Auto import selected folder, and subfolders too (recursively).",
	    },
	    vf:checkbox {
	        bind_to_object = props,
	        title = "Recheck every",
	        value = bind 'autoImportSelFolderCont',
	        enabled = aiSelFolderEnableBinding,
	        tooltip = "Auto import files in selected folder(s) - re-check at specified interval.",
	    },
	    vf:edit_field {
	        bind_to_object = props,
	        value = bind 'autoImportSelFolderInterval',
	        precision=0,
	        min=1,
	        max=999, -- is there ever a reason to need more than 99 seconds between checks?
            width_in_digits = 3,
            enabled = contEnaBinding,
	        tooltip = "Check for new photos every this many seconds: 1 to ~17 minutes",
	    },
	    vf:static_text {
	        title = "seconds",
	        enabled = contEnaBinding,
	    },
	}

	appSection[#appSection + 1] = vf:row {
	    vf:checkbox {
	        bind_to_object = props,
	        title = "Read metadata",
	        value = bind 'autoImportSelFolderReadMetadata',
	        enabled = aiSelFolderEnableBinding,
	        tooltip = "Auto-read metadata, if it *changes* on disk, into catalog.\n \n*** It is highly recommended to resolve all metadata status issues before enabling this feature, to avoid accidental loss of catalog metadata.",
	    },
	    vf:checkbox {
	        bind_to_object = props,
	        title = "Remove Deleted Photos",
	        value = bind 'autoImportSelFolderRemoveDeletedPhotos',
	        enabled = aiSelFolderEnableBinding,
	        tooltip = "If checked, photos will be removed if source file no longer present on disk - at least one ancestor folder MUST exist (not necessarily parent); if unchecked, no attention paid to source file presence..",
	    },
    }
	
    self:recomputeCsItems()
    
    appSection[#appSection + 1] = 
        vf:spacer { height = 5 }
    appSection[#appSection + 1] =    
        vf:row {
            vf:static_text {
                title = "Import Settings",
                width = share 'label_width_1',
                enabled = aiSelFolderEnableBinding,
            },
            vf:popup_menu {
                bind_to_object = props,
                value = bind 'autoImportSelFolderCustomSetName', -- any reason I don't just bind to prefs and forget the props?
                items = bind 'autoImportSelFolderCustomSetNameItems',
                width_in_chars = 30, -- must support longest preset name, @21/May/2013 20:06, statically.
                tooltip = "Settings used for importing upon folder selection (only) - consider using \"Add in Place\" instead of \"Copy/Move..\".",
                enabled = aiSelFolderEnableBinding,
            },
            vf:static_text {
                title = str:fmtx( "Import settings to be used only for\nauto-import upon folder selection." ),-- Reload plugin to refresh list\nif you edit/add additional settings." ),
                height_in_lines = 3,
                fill_horizontal = 1,
                enabled = aiSelFolderEnableBinding,
            },
        }
    appSection[#appSection + 1] =
        vf:row {
            vf:static_text {
                title = "Custom Text",
                width = share 'label_width_1',
                enabled = aiSelFolderEnableBinding,
            },
            vf:edit_field {
                bind_to_object = props,
                value = bind( "autoImportSelFolderCustomText_1" ),
                width_in_chars = 15,
                enabled = aiSelFolderEnableBinding,
                tooltip = "Available for folder/file-naming - upon folder selection only.",
            },
            vf:edit_field {
                bind_to_object = props,
                value = bind( "autoImportSelFolderCustomText_2" ),
                width_in_chars = 15,
                enabled = aiSelFolderEnableBinding,
                tooltip = "Available for folder/file-naming - upon folder selection only.",
            },
            vf:spacer { width = 20 },
            vf:static_text {
                title = "Start Number",
                enabled = aiSelFolderEnableBinding,
            },
            vf:edit_field {
                bind_to_object = props,
                value = bind( "autoImportSelFolderCustomNum_1" ),
                min = 0,
                max = 9999999,
                precision = 0,
                width_in_digits = 7,
                enabled = aiSelFolderEnableBinding,
                tooltip = "Available for folder/file-naming - upon folder selection only.",
            },
        }
        
	appSection[#appSection + 1] = vf:spacer{ height=10 }
	appSection[#appSection + 1] = vf:separator{ fill_horizontal=1 }
	appSection[#appSection + 1] = vf:spacer{ height=10 }
	appSection[#appSection + 1] = vf:row {
	    vf:checkbox {
	        title = "Additional Import Criteria",
	        value = app:getGlobalPrefBinding( 'importCritEna' ),
	        tooltip = "Implementation of \"additional import criteria\" is via \"advanced settings\", and so depends on preset, but initialization is common to all - this box determines whether duplicate checking (and/or other additional import criteria) infrastructure is initialized for use as various presets see fit..",
	    },
	    vf:checkbox {
	        title = "Original Filename Support",
	        value = app:getGlobalPrefBinding( 'origFilenameEna' ),
	        enabled = app:getGlobalPrefBinding( 'importCritEna' ),
	        tooltip = "Original filenames support is provided by SQLiteroom - if you aren't starting Lightroom via SQLiteroom-saved bat file, then do not check this box..\n \n*** To be clear: original filenames are valid upon such startup and are maintained be Ottomanic Importer imports - original filenames for other-wise imported stuff will not be included.",
	    },
	}
	
	appSection[#appSection + 1] = vf:spacer{ height=10 }
	appSection[#appSection + 1] = vf:separator{ fill_horizontal=1 }
	appSection[#appSection + 1] = vf:spacer{ height=10 }
	
	if false and gbl:getValue( 'background' ) then -- not using conventional background task.
	
	    -- *** Instructions: tweak labels and titles and spacing and provide tooltips, delete unsupported background items,
	    --                   or delete this whole clause if never to support background processing...
	    -- PS - One day, this may be handled as a conditional option in plugin generator.
	
        appSection[#appSection + 1] =
            vf:row {
                bind_to_object = props,
                vf:static_text {
                    title = "Auto-check control",
                    width = share 'label_width',
                },
                vf:checkbox {
                    title = "Automatically check most selected photo.",
                    value = bind( 'background' ),
    				--tooltip = "",
                    width = share 'data_width',
                },
            }
        appSection[#appSection + 1] =
            vf:row {
                bind_to_object = props,
                vf:static_text {
                    title = "Auto-check selected photos",
                    width = share 'label_width',
                },
                vf:checkbox {
                    title = "Automatically check selected photos.",
                    value = bind( 'processTargetPhotosInBackground' ),
                    enabled = bind( 'background' ),
    				-- tooltip = "",
                    width = share 'data_width',
                },
            }
        appSection[#appSection + 1] =
            vf:row {
                bind_to_object = props,
                vf:static_text {
                    title = "Auto-check whole catalog",
                    width = share 'label_width',
                },
                vf:checkbox {
                    title = "Automatically check all photos in catalog.",
                    value = bind( 'processAllPhotosInBackground' ),
                    enabled = bind( 'background' ),
    				-- tooltip = "",
                    width = share 'data_width',
                },
            }
        appSection[#appSection + 1] =
            vf:row {
                vf:static_text {
                    title = "Auto-check status",
                    width = share 'label_width',
                },
                vf:edit_field {
                    bind_to_object = prefs,
                    value = app:getGlobalPrefBinding( 'backgroundState' ),
                    width = share 'data_width',
                    tooltip = 'auto-check status',
                    enabled = false, -- disabled fields can't have tooltips.
                },
            }
    end
    
    if not app:isRelease() and app:isAdvDbgEna() then
    	appSection[#appSection + 1] = 
    		vf:row {
    			vf:push_button {
    				title = "Reload Plugin",
    				width = share 'label_width',
    				action = function( button )
    				    app:pcall{ name=button.title, async=false, main=function( call )
    				        reload:now()
    			        end }
    				end,
    			},
    			vf:static_text {
    				title = str:format( "Reload plugin after editing advanced settings." ),
    			},
    		}
    end
		
	appSection[#appSection + 1] = 
		vf:row {
			vf:push_button {
				title = "Edit Additional Settings",
				width = share 'label_width',
				tooltip = "Additional settings used here and there in OI, including ad-hoc import setting options, and auto-mirroring folder definitions..",
				action = function( button )
				    app:pcall{ name=button.title, async=true, guard=App.guardVocal, main=function( call )
				        app:assurePrefSupportFile() -- new @9/May/2014 1:14 - documented on web page.
    				    ottomanic:editSystemSettings( button.title ) -- wrapped, but synchronous, and not guarded.
    				    self:recomputeCsItems()
    				end }
				end
			},
			vf:static_text {
				title = str:format( "Edit additional preference and import settings" ),
			},
		}
		
	appSection[#appSection + 1] = vf:spacer{ height=10 }
	appSection[#appSection + 1] = 
		vf:row {
			vf:push_button {
				title = "Sample Metadata",
				tooltip = "Purpose of this button is to show exif 'id' and Lr metadata 'key' values which you have at your disposal for customizing duplicate detection or filenaming..",
				action = function( button )
				    local isAdvDbgEna
				    app:service{ name='Test', async=true, main=function( call )

                        local candPhoto = cat:getAnyPhoto()
                        if not candPhoto then
                            app:logE( "Could not find any photo." )
                            return
                        end
                        
                        local isUsable, isntIt = exifTool:isUsable()
                        if isUsable then
                            app:log( "ExifTool is usable - ^1", isntIt or "no additional info" )
                        else
                            app:logE( "ExifTool is NOT usable - ^1", isntIt or "no additional info" )
                            return
                        end
                        
                        local allRawMeta = candPhoto:getRawMetadata() -- no name means all.
                        local targetPath = allRawMeta['path'] or error( "no path in raw metadata" )
                        local targetName = cat:getPhotoNameDisp( candPhoto, true ) -- full path & copy name.
                        
                        isAdvDbgEna = app:isAdvDbgEna()
                        if not isAdvDbgEna then
                            Debug.init( true )
                        end
                        Debug.clearLogFile()
                        Debug.logn( "Debug log file was cleared to make way for metadata info.." )
                        Debug.lognpp( "Sample photo:", targetName )
                        exifTool:addArg( "-S" ) -- exiftool app emulating a session - this much works (it's not 100% compatible anymore).
                        exifTool:setTarget( targetPath )
                        local rslt, errm = exifTool:execute()
                        if str:is( rslt ) then
                            local exif, nope = exifTool:parseShorty( rslt )
                            if exif then
                                Debug.logn( "Exif metadata in '-S' format:")
                                Debug.lognpp( exif )
                            else
                                app:logE( nope )
                            end
                        else
                            app:logE( errm )
                        end
                        
                        Debug.logn( "Raw metadata from catalog:" )
                        Debug.lognpp( allRawMeta )
                        Debug.logn( "Formatted metadata from catalog:" )
                        local allFmtMeta = candPhoto:getFormattedMetadata() -- no name means all.
                        Debug.lognpp( allFmtMeta )
                        --  @param      params      parameter table, with optional members: 'format' (idOnly, idPlusFriendly, friendlyOnly, friendlyPlusId)
                        --
                        -- Lr Metadata:get HelpT ext( params )
                        local contents, buffer = lrMeta:getHelpText{ format='friendlyPlusId' }
                        app:log()
                        app:log( "\n"..contents )
                        app:log()
                        app:log( "Sample exif (from source file), and Lr (catalog) metadata (raw & formatted) is in the debug log, which should been opened in default app." )
                        app:log( "Also, just above in this log file are the Lr metadata ID's associated with Lr metadata titles which may help if you are customizing in depth.." )
                        app:log()                        
                        
                    end, finale=function( call )
                        if not call:isQuit() then
                            Debug.showLogFile()
                        end
                        if not isAdvDbgEna then
                            Debug.init( false )
                        end
                    end }
				end
			},
			vf:static_text {
				title = str:format( "Display sample of exif (file) metadata, and Lr (catalog) metadata." ),
			},
		}
		
		
	--[[ *** save for posterity, I guess (reminder: floaters don't display tooltips if plugin manager dialog box is also being displayed).
	appSection[#appSection + 1] =
	    vf:row {
	        vf:push_button {
	            title = "Hide/Unhide/Report",
  				width = share 'label_width',
  				tooltip = "Hide importable files, un-hide previously hidden files, or report about importable file types - whether hidden or not...",
	            action = function( button )
	                app:show{ info="This feature is also available on the Library menu (Plugin Extras) as \"Hide n' Import...\"",
	                    actionPrefKey = "Hide|Unhide|Report feature is also on Library menu...",
	                }
	                ottomanic:hideAndImport( button.title )
	            end,
	        },
	        vf:static_text {
	            title = "Hide (or unhide) files with specified extensions"..(app:lrVersion() <= 3 and " - Lr5 (or Lr4) only." or ""),
	            tooltip = "in case they're causing problems...",
	        },
	    }
	--]]
    

    if not app:isRelease() then
    	appSection[#appSection + 1] = vf:spacer{ height = 20 }
    	appSection[#appSection + 1] = vf:static_text{ title = 'For plugin author only below this line:' }
    	appSection[#appSection + 1] = vf:separator{ fill_horizontal = 1 }
    	appSection[#appSection + 1] = 
    		vf:row {
    			vf:edit_field {
    				value = bind( "testData" ),
    			},
    			vf:static_text {
    				title = str:format( "Test data" ),
    			},
    		}
    	appSection[#appSection + 1] = 
    		vf:row {
    			vf:push_button {
    				title = "Test",
    				action = function( button )
    				    app:service{ name='Test', async=true, main=function( call )

                            local pname = app:getPresetName()
                            local key = systemSettings:getKey( "settings", pname )
                            Debug.pause( key, systemSettings.reg[key].readMetadataTheOldWay, app:getPref( 'readMetadataTheOldWay' ) )

                        end, finale=function( call )
                            if not call:isCanceled() then
                                Debug.showLogFile()
                            end
                        end }
    				end
    			},
    			vf:static_text {
    				title = str:format( "Perform tests." ),
    			},
    		}
    end
		
    local sections = Manager.sectionsForBottomOfDialogMethod ( self, vf, props ) -- fetch base manager sections.
    if #appSection > 0 then
        tab:appendArray( sections, { appSection } ) -- put app-specific prefs after.
    end
    return sections
end



return ExtendedManager
-- the end.