--[[
        OttomanicImporter.lua
--]]


local OttomanicImporter, dbg, dbgf = Object:newClass{ className = "OttomanicImporter", register = true }




--- Constructor for extending class.
--
function OttomanicImporter:newClass( t )
    return Object.newClass( self, t )
end



--- Constructor for new instance.
--
function OttomanicImporter:new( t )
    local o = Object.new( self, t )
    
    -- Note: keyword cache init can be a very expensive operation, thus it is relies on a first use scheme.
    -- If user wants to re-init, he/she can reload the plugin, or use the refresh button.
    --keywords:initCache() - init is automatic, but reinit will not be permitted.
    -- keyword cache might get pretty stale - but shouldn't matter, since users keyword is checked during setup.
    -- i.e. user is not going to want to apply different keywords without changing setup, at which point re-init of the cache is an option.
    
    o.tempPaths = {} -- keys are folder paths, values are specs.
    o.permPaths = {} -- keys are folder paths, values are specs.
    o.rawExtPri = {} -- likely raw extensions to match xmp sidecar.
    
    dirChgApp:setMessageCallback( _PLUGIN.id, OttomanicImporter.processDirFileChangeNotifyMessage, o )
    
    return o
end



function OttomanicImporter:getPhotoForXmpSidecar( xmpFile, spec )
    assert( spec.import.importExt.raw, "no raw ext arr" )
    local alreadyChecked = {}
    -- check previously observed raw extensions, if any.
    for rawExt, _t in pairs( self.rawExtPri ) do
        local photoFile = LrPathUtils.replaceExtension( xmpFile, rawExt )
        local photo = cat:findPhotoByPath( photoFile ) 
        if photo then return photo, photoFile end
        alreadyChecked[rawExt] = true
    end
    -- not found via "priority" (previously observed) extensions.
    for i, rawExt in ipairs( spec.import.importExt.raw ) do
        if not alreadyChecked[rawExt] then
            local photoFile = LrPathUtils.replaceExtension( xmpFile, rawExt )
            local photo = cat:findPhotoByPath( photoFile ) 
            if photo then
                self.rawExtPri[rawExt] = true -- add to set of "priority" extensions, so next time, it will be found more quickly.
                return photo, photoFile
            end
        -- else already checked in loop above.
        end
    end
end



-- could try to find a spec for this, but what's the point?
function OttomanicImporter:processDirNotice( msg )
    if not app:getGlobalPref( 'autoImportEnable' ) then return false, "Auto-import is not enabled" end
    if msg.eventType == 'created' then
        app:log( "New dir: '^1' (ad-hoc observer)", msg.path ) 
    elseif msg.eventType == 'deleted' then
        app:logW( "Dir exists, but was supposedly deleted: '^1' (ad-hoc observer)", msg.path ) 
    elseif msg.eventType == 'modified' then
        app:logV( "Dir modified: '^1' (no action taken) - ad-hoc observer.", msg.path ) 
    else
        app:logW( "Un-recognized dir event (^1), path: '^2' - watcher for ad-hoc auto-importer.", msg.eventType, msg.path ) 
    end
    return true
end



-- get spec - most useful for events that matter..
function OttomanicImporter:_getSpec( dir )
    local function getSpec( paths )
        for folderPath, spec in pairs( paths ) do
            local parent = dir
            while parent do
                if parent == folderPath then
                    return spec
                else
                    parent = LrPathUtils.parent( parent )
                end
            end
        end
    end
    -- note: generally user will not have more than a half-dozen ad-hoc auto-imports - usually only one or two, so this is fast:
    local spec = getSpec( self.tempPaths )
    if spec == nil then
        spec = getSpec( self.permPaths )
    end
    if spec then
        return spec
    end
end



-- note: dir-chg app has no ram buffering for changes - it writes them to disk immediately in the form of messages which do not require replies.
-- Response to said notifications is very fast, since processing is asynchronous - thus messages won't expire prematurely. it's ram which will puff
-- up a tiny bit here here until imports play out.
function OttomanicImporter:processFileCreated( msg, spec )
    local file = msg.path
    app:log( "New file: ^1", file )
    self.fileSet = self.fileSet or {}
    self.fileErrCnt = self.fileErrCnt or {}
    self.fileSet[file] = true
    -- this is asynchronous, so additional files can get set while it's running - called for both bg-mirroring and ad-hoc.
    -- and it's silently guarded silently, so every time it runs, it has to do *all* - no excuses.
    app:pcall{ name="Ad-hoc File Created", async=true, guard=App.guardSilent, progress=true, function( call )
        local fileArray = tab:createArray( self.fileSet )
        local nQx = 0
        local trip = 0
        repeat
            trip = trip + 1
            local nQ = #fileArray
            nQx = math.max( nQ, nQx )
            app:logV()
            app:logV( "Considering ^1 (^2 max this trip: ^3).", nQ, nQx, trip )
            app:logV()
            for i, f in ipairs( fileArray ) do
                local fn = LrPathUtils.leafName( f )
                call:setCaption( fn )
                
                -- note: spec.call is used by file-as-specified for stats only (@15/Jun/2014 4:00).
                
                -- Note: import-file-as-specified does not handle auto-read metadata, nor update caption display
                --local noE, mOrI, aIn = spec.import:fileAsSpecified( f, spec, false, true ) -- not "report-only"; return errors here.
                local noE, mOrI, aIn = self:_considerAutoImportingFile( f, spec, false, true ) -- handles read-metadata and updates caption display.
                
                if noE then -- no error
                    background:clearError( "AutoImportError" )
                    if mOrI then -- should be I=true.
                        assert( type( mOrI ) == 'boolean', type( mOrI ) )
                        --app:log( "Imported: ^1", f ) -- redundent
                    else
                        -- app:log( "Not Imported: ^1", f ) -- ditto, I think.
                    end
                    self.fileSet[f] = nil
                    self.fileErrCnt[f] = nil
                elseif mOrI then
                    assert( type( mOrI ) == 'string', type( mOrI ) )
                    if self.fileErrCnt[f] == nil then
                        self.fileErrCnt[f] = 0
                    else
                        self.fileErrCnt[f] = self.fileErrCnt[f] + 1
                        if self.fileErrCnt[f] > 10 then -- 10 strikes yer out..
                            app:logW( "Unable to import file: ^1", f )
                            -- generally, this method is reserved for clearable errors and represents current status, but in this case I think forcing user to clear
                            -- is not unreasonable - he/she needs to know that everything is not OK.
                            background:displayErrorX( { id="AutoImportFailure", immediate=true, promptWhenUserCancels=true }, mOrI ) -- immediate=true means bypass default suppression. I'm kinda borrowing the background task's thingy.
                            self.fileSet[f] = nil
                            self.fileErrCnt[f] = nil
                        elseif self.fileErrCnt[f] < 5 then -- first half of total, don't trip - could just be some other plugin or Lr hogging the catalog..
                            app:logV( "Unable to import file: ^1 (^2 so far)", f, str:nItems( self.fileErrCnt[f], "tries" ) )
                        else -- 5-10 tries so far (time to start trippin'..).
                            -- in case problem is persisting: (cleared upon first import which doesn't error out.
                            app:log( "*** Unable to import file: ^1 (^2 so far)", f, str:nItems( self.fileErrCnt[f], "tries" ) )
                            background:displayErrorX( { id="AutoImportError", immediate=false, promptWhenUserCancels=false }, mOrI ) -- immediate=false means take advantage of default suppression. I'm kinda borrowing the background task's thingy.
                        end
                    end
                else -- error, but no message
                    self.fileSet[f] = nil
                    self.fileErrCnt[f] = nil
                    app:logW( "Error importing file (^1) but no message provided - hmm...", f )
                    Debug.pause( f, spec )
                end
            end
            if not tab:isEmpty( self.fileSet ) then
                fileArray = tab:createArray( self.fileSet )
            else
                break
            end
        until call:isQuit()
        if shutdown then return end
        if tab:isEmpty( self.fileSet ) then
            app:log( "No more files to import this wave.." )
        else
            app:logV( "*** Not all files were imported this wave.." )
        end
        if call:isQuit() then
            app:log( "Import was quit.." )
        end
    end }
    LrTasks.yield() -- give scheduled task a chance to run.
end



--local dbgd
-- file in dir being watched in honor of ad-hoc auto-import (only), is new, or has been modified.
function OttomanicImporter:processFileNotice( msg )
    if not app:getGlobalPref( 'autoImportEnable' ) then return false, "Auto-import is not enabled" end
    local file = msg.path or error( "no path in msg" )
    local dir = LrPathUtils.parent( file )
    -- oi needs the spec for any likely file ops..
    local spec = self:_getSpec( dir )
    if not spec then
        app:logW( "No spec for dir: ^1", dir )
        return
    end
    --if not dbgd then
    --    Debug.lognpp( spec )
    --    dbgd = true
    --end
    if msg.eventType == 'created' then
        self:processFileCreated( msg, spec )
    elseif msg.eventType == 'deleted' then -- spec not needed, but not a likely file op either (normal deletions are handled by "gone" notice).
        app:logW( "File exists, but was supposedly deleted: ^1", msg.path ) 
    elseif msg.eventType == 'modified' then
        assert( spec.readMetadata ~= nil, "que paso?" )
        if spec.readMetadata then
            self:autoReadMetadata( msg.path, spec )
        else
            app:logV( "File modified: '^1' - no action is being taken (auto-read-metadata is not enabled).", msg.path ) 
        end
    else
        app:logW( "Un-recognized file event (^1), path: ^2", msg.eventType, msg.path ) 
    end
    return true
end


-- Neither notifier app nor I can't tell if it's dir or file once it's gone, so.. (Sherlock Holmes..).
function OttomanicImporter:processGoneNotice( msg )
    if not app:getGlobalPref( 'autoImportEnable' ) then return false, "Auto-import is not enabled" end
    local folder = cat:getFolderByPath( msg.path )
    local photo
    if folder then
        app:log( "*** Folder is gone: ^1", msg.path )
    else
        photo = cat:findPhotoByPath( msg.path )
        if photo then
            local parent = LrPathUtils.parent( msg.path )
            if parent and ( LrFileUtils.exists( parent ) == 'directory' ) then -- parent dir must exist, or disappearing photos will be ignored.
                local spec = self:_getSpec( parent )
                if spec then
                    app:logV( "Photo source file has gone missing (but parent folder still exists): ^1", msg.path )
                else
                    app:logW( "No import spec associated with deleted file '^1' -  no action taken.", msg.path )
                    return
                end
                self.goneSet = self.goneSet or {}
                self.goneSet[photo] = true
                local goneArray = tab:createArray( self.goneSet )
                local s, m = cat:update( -5, "Update Deleted Photos Collection", function( context, phase ) -- try for up to 5 seconds, but don't trip if no can do - catch it next time around..
                    delColl:addPhotos( goneArray )
                end )
                if s then
                    self.goneSet = {}
                    app:log( "Added ^1 to \"deleted\" collection", str:nItems( #goneArray, "photos" ) )
                    if spec.removeDeletedPhotos then
                        -- schedule async task to handle photos in del-coll. note: since it's theoretically possible that additional photos will enter del-coll
                        -- before task is complete, and since there is allowed only one such task (guarding), it behooves to assure delcoll is empty before
                        -- sealing the deal..
                        app:pcall{ name="OttomanicImporter_processGoneNotice", async=true, guard=App.guardSilent, function( call )
                            while #delColl:getPhotos() > 0 do -- sufficient logging within:
                                ottomanic:_removeDeletedPhotos( "Removing deleted photo(s) as specified when ad-hoc import was started" ) -- this may present prompt,
                                -- or may not - but if not, there will be a lengthy delay *before* pulling photos from del-coll.
                            end
                        end }
                    else
                        app:logV( "Photo source file has gone missing (but parent folder still exists): '^1' - will be added to 'Deleted' collection, but not removed from catalog.", msg.path )
                    end
                else
                    app:logW( m )
                end
            else
                app:logV( "Photo source file and parent folder have both gone missing: ^1 (no action taken).", msg.path )
            end
        else
            app:logV( "Directory entry went missing, but seems not be folder in Lightroom, nor photo source file: ^1", msg.path )
        end
    end
    return true
end



-- this is how changes after baseline scan get incorporated:
function OttomanicImporter:processDirFileChangeNotifyMessage( msg )
    if msg.name == 'registered' then
        if str:is( msg.comment ) then
            app:logV( "Ottomanic Importer notified of dir registration, comment: '^1'.", msg.comment )
        else
            app:logV( "Ottomanic Importer notified of dir registration." )
        end
    elseif msg.name == 'notify' then
        if str:is( msg.comment ) then
            app:logV( "Ottomanic Importer notified of dir-file change: '^1' (^2) - comment: ^3.", msg.path, msg.eventType, msg.comment )
        else
            app:logV( "Ottomanic Importer notified of dir-file change: '^1' (^2).", msg.path, msg.eventType )
        end
        --Debug.lognpp( msg )
        local isDir, isFile = fso:existsAs( msg.path, "directory" )
        local s, m
        if isDir then
            s, m = self:processDirNotice( msg )
        elseif isFile then
            s, m = self:processFileNotice( msg )
        else
            s, m = self:processGoneNotice( msg )
        end
        if not s then
            Debug.pause( m )
        end
    elseif msg.name == 'error' then
        if str:is( msg.comment ) then
            app:alertLogE( "dir-chg app error: ^1", msg.comment )
        else
            app:alertLogE( "dir-chg app reported error sans comment" )
        end
    else
        if str:is( msg.comment ) then
            app:logV( "Ottomanic Importer received unexpected message (^1), comment: '^2'.", msg.name, msg.comment )
        else
            app:logV( "Ottomanic Importer received unexpected message: '^1'.", msg.name )
        end
        Debug.pause( msg )
    end
end




-- plugin recipient only (not background task) - one dir at a time.
function OttomanicImporter:_register( spec )
    app:callingAssert( spec.folder, "no folder specified" )
    local recs = { { dir=cat:getFolderPath( spec.folder ), events=1, notifyAddr=_PLUGIN.id, recursive=spec.recursive } }
    local s, m = dirChgApp:register( recs )
    local tb
    if spec.resursive then
        tb = " - recursively"
    else
        tb = ""
    end
    if s then
        app:log( "Registered '^1' for changes to dir: '^2'^3", _PLUGIN.id, recs[1].dir, tb )
        return true
    else
        app:logW( "Dirs not registered for plugin - ^1", m )
        return false
    end
end



function OttomanicImporter:_unregister( spec )
    app:callingAssert( spec.folder, "no folder specified" )
    local recs = { { dir=cat:getFolderPath( spec.folder ), events=0, notifyAddr=_PLUGIN.id, recursive=spec.recursive } } -- un-register record (events=0).
    local s, m = dirChgApp:register( recs ) -- register method unregisters too.
    local tb
    if spec.resursive then
        tb = " - recursively"
    else
        tb = ""
    end
    if s then
        app:log( "Unregistered '^1' for changes to dir: '^2'^3", _PLUGIN.id, recs[1].dir, tb )
        return true
    else
        app:logW( "Dirs not un-registered for plugin - ^1", m )
        return false
    end
end



--  Get custom import settings as specified by name.
--
function OttomanicImporter:getCustomSet( customSetName )
    if str:is( customSetName ) then
    
        local setKey = systemSettings:getKey( 'importCustomSets' ) -- default root.
        
        local customSet, errm = systemSettings:getArrayElemByName( setKey, prefs, customSetName )
        
        if customSet then
            customSet.customSetName = customSetName
            return customSet
        else
            return nil, errm
        end

    else
        return nil, "no custom set name"
    end
end


-- presents standard system settings view, with addition of scrutinization button.
function OttomanicImporter:editSystemSettings( title )
    app:pcall{ name=title, async=false, main=function( call )
    
        local viewItems, viewLookup, errm = systemSettings:getViewItemsAndLookup( call )

        if tab:isNotEmpty( viewItems ) then
        
            --Debug.lognpp( viewItems, viewLookup )
        
            local button = app:show{ info=title,
                viewItems = viewItems,
                accItems = { vf:push_button {
                    title="Scrutinize Settings",
                    action=function( button )
                        app:service{ name=button.title, async=true, guard=App.guardVocal, main=function( call )
                            --local x = systemSettings:getValue( 'exportPresetNames' )
                            --Debug.pause( x )
                            local importSettings, errm = self:getImportSettings()
                            if importSettings then
                                Debug.lognpp( importSettings )
                                app:log( "Settings have been scrutinized and no problems were detected." )
                                app:show{ info="Settings have been scrutinized and no problems were detected.",
                                    actionPrefKey = "scrutinized settings are ok",
                                }
                            else
                                app:logErr( errm )
                            end
                        end, finale=function( call )
                            Debug.showLogFile()
                        end }
                    end,
                } },
            }

            if button == 'ok' then
                -- ok
            else
                call:cancel()
                return
            end
            
        else
            app:show{ warning="no view items" }
            call:cancel()
            return
        end
        
    end, finale=function( call )
        if not call:isCanceled() then
            Debug.showLogFile()
        end
    end }
end



--  Called to initialize start/stop menu functions only, *NOT* called upon startup, nor the "show..." menu item.
--  Primary purposes:
--      * initialize set of folders not already started (ripe for starting).
--      * initialize array of active sources which are folders.
--  Notes:
--      * self.permSpecs is initialized (asynchronously) by -auto-start method, upon startup, *and* upon initial startup.
--      * self.tempSpecs is populated by starting ad-hoc.
--      * Not called for start unless auto-importing is enabled, but will be called for stop whether auto-importing enabled or not.
function OttomanicImporter:_initForStartStop( call, start )
    local sources = catalog:getActiveSources()
    call.lrFoldersRipeForStarting = {} -- set of folders ripe for starting ad-hoc. Reminder: only used by "start" function.
    call.lrFolders = {} -- array of folders

    -- only used if called to honor start function:
    local mirrorEna = app:getPref( 'autoMirrorFolders' )
    app:assert( mirrorEna ~= nil, "not init" )

    local function isRipeForStarting( f )
        local p = f
        repeat
            if p then
                local path = cat:getFolderPath( p )
                if mirrorEna then
                    if background.mirrorPaths[path] then
                        app:log( "Folder not ripe to start auto-importing (^1) because it's in the same tree as auto-mirror folder (^2), which takes precedence.", cat:getFolderPath( f ), path )
                        return false
                    else -- not a top-level mirrored folder.
                        dbgf( "Not mirroring folder (at top-level): ^1", path )
                    end
                -- else
                    -- dbgf( "Mirroring not enabled, so folder not a factor auto-mirror-wise: ^1", path )
                end
                if self.tempPaths[path] then
                    if cat:isEqualFolders( p, f ) then
                        app:log( "Folder not ripe to start auto-importing (^1) because it's already a \"temporary\" auto-importing folder.", path )
                        return false
                    elseif self.tempPaths[path].recursive then
                        app:log( "Folder not ripe to start auto-importing (^1) because it's in the same tree as \"temporary\" (and recursive) auto-importing folder (^2).", cat:getFolderPath( f ), path )
                        return false
                    else
                        assert( self.tempPaths[path].recursive ~= nil, "recursive?" )
                    end
                end
                if self.permPaths[path] then
                    if cat:isEqualFolders( p, f ) then
                        app:log( "Folder not ripe to start auto-importing (^1) because it's a \"permanent\" auto-importing folder.", path )
                        return false
                    elseif self.permPaths[path].recursive then
                        app:log( "Folder not ripe to start auto-importing (^1) because it's in the same tree as \"permanent\" (and recursive) auto-importing folder (^2), which takes priority.", cat:getFolderPath( f ), path )
                        return false
                    else
                        assert( self.permPaths[path].recursive ~= nil, "recursive?" )
                    end
                end
            else
                return true
            end
            p = p:getParent() -- *** beware: folder children don't always return their original parent objects - ugh.
        until false
    
        -- never reaches here
    
    end
    for i, source in ipairs( sources ) do
        local sourceType = cat:getSourceType( source )
        if sourceType == 'LrFolder' then
            call.lrFolders[#call.lrFolders + 1] = source
            if start and isRipeForStarting( source ) then
                call.lrFoldersRipeForStarting[source] = true
            -- stop does not need such info.
            end
        else
            app:logv( "Ignoring non-folder source: ^1", cat:getSourceName( source ) )
        end
    end
    if #call.lrFolders == 0 then
        app:show{ warning="Selected folder(s) first." }
        call:cancel()
    end
end



-- supports display of sample file: both manual and auto-import dialog boxes.
local sampleFile
local sampleFiles = {
    raw = nil,
    rgb = nil,
    video = nil,
}



-- presently used for both manual and auto-import UIs.
-- There is a chance the user may very-well want a different setting for auto vs. manual, esp. add-in-place vs. copy.
function OttomanicImporter:_initCommonViewItems( props, import, auto, call )

    local customSetPrefName = auto and "customSetNameAuto" or "customSetNameManual"
    
    app:assert( import, "no import" )
    app:initGlobalPref( customSetPrefName, "" )
    props.customSetName = app:getGlobalPref( customSetPrefName )
    props.samplePhoto = nil -- for thumb, when preview is from catalog photo.
    props.sampleFile = nil -- for thumb, when preview is from disk file.
    app:initGlobalPref( 'sampleKey', 'raw' ) -- start with raw, by default.
    props.sampleKey = app:getGlobalPref( 'sampleKey' )
    props.sampleName = "No image was obtainable for sample." -- for photo label.
    props.samplePath = "" -- sample import path
    
    local setKey = systemSettings:getKey( 'importCustomSets' )
    local dataDescr, errm = systemSettings:getDataDescr( setKey )
    if dataDescr then
        -- good
    else
        app:error( "no data descr for ^1 - ^2", setKey, errm )
    end
    local setNames
    local csItems
    local function updImportSettingsMenu()
        setNames = systemSettings:getArrayNames( setKey )
        csItems = {}
        local found = false
        local firstName
        for i, name in ipairs( setNames ) do
            if firstName == nil then
                firstName = name
            end
            csItems[#csItems + 1] = { title=name, value=name }
            if props.customSetName == name then
                found = true
            end
        end
        
        if found then
            -- 
        elseif firstName then
            app:setGlobalPref( customSetPrefName, firstName )
            props.customSetName = firstName
        else
            app:setGlobalPref( customSetPrefName, "" )
            props.customSetName = ""
        end
        if #csItems > 0 then
            csItems[#csItems + 1] = { separator=true }
        end
        csItems[#csItems + 1] =  { title="Edit (new/delete/modify...)", value=" " } -- space
        props.csItems = csItems
    end
    
    updImportSettingsMenu()

    local function updSamplePath( customSetName )
        if call:isQuit() then return end -- do not update sample path if call is already quit. Note: this is critical, since token pool is shared module variable - upd-sample can stomp on real import-in-progress tokens. ###2
        local sampleKey = app:getGlobalPref( 'sampleKey' ) or 'raw'
        local customSet = self:getCustomSet( customSetName )
        if tab:isNotEmpty( customSet ) then
            import:initImportExt( customSet.importExt )
            local settings = import:initSettings( customSet, app:getGlobalPref( 'customText_1' ), app:getGlobalPref( 'customText_2' ), true )
            assert( settings, "no settings init'd" )
            settings.exifToolSession = true -- force a session for purpose of upd-sample-path
            local spec = { call=call, folder=nil, recursive=nil, settings=settings, coll=nil, import=import, card=nil, auto="Sample Path" } -- re-use exiftool session
            local s, m = import:initSession( spec ) -- should return existing "Sample Path" session, if existing, else open anew.
            --Debug.pause()
            if auto then
                if s then
                    props.samplePath = str:fmtx( "Getting ^1 sample from catalog...", sampleKey )
                    props.samplePhoto = nil
                    local cap = call:setCaption( "Getting ^1 sample from catalog...", sampleKey )
                    local samplePhoto = cat:getAnyPhoto( true, sampleKey, call ) -- must not be missing (file).
                    if samplePhoto then
                        --Debug.pause( sampleKey, "getting metadata" )
                        local sourceFile = samplePhoto:getRawMetadata( 'path' )
                        local ext = LrPathUtils.extension( sourceFile )
                        if settings.initFile then
                            --Debug.pause( sampleKey, "initing tokens" )
                            import:_initFile( sourceFile, spec )
                        end
                        props.sampleName = sourceFile -- LrPathUtils.leafName( sourceFile )
                        props.sampleFile = sourceFile
                        --Debug.pause( sampleKey, "getting filename" )
                        local newExt = import:_getNewExtension( sourceFile, spec )
                        local samplePath = import:_getNewFilePath( sourceFile, spec, newExt )
                        if samplePath then
                            --Debug.pause( sampleKey, LrPathUtils.leafName( samplePath ) )
                            props.samplePath = samplePath
                            props.samplePhoto = samplePhoto
                        else
                            props.samplePath = "No sample import path"
                            props.samplePhoto = nil
                        end
                    else -- catalog empty or all photos missing.
                        props.samplePhoto = nil
                        props.sampleName = str:fmtx( "No ^1 sample source path obtainable", sampleKey )
                        --props.sampleFile = nil - not used for auto prompt.
                        props.samplePath = str:fmtx( "No ^1 sample import path obtainable", sampleKey )
                    end
                    call:setCaption ( cap )
                else
                    props.samplePhoto = nil
                    props.sampleName = str:fmtx( "No ^1 sample source path obtained", sampleKey )
                    --props.sampleFile = nil - not used for auto prompt.
                    props.samplePath = str:fmtx( "No ^1 sample import path obtained", sampleKey )
                end
                return
            end
            -- fall-through => manual
            if s then
                -- Note: sampleFile is module variable computed elsewhere.
                local sourceFile = sampleFiles[sampleKey]
                
                --Debug.pause( sampleKey, sourceFile )
                
                local previewFile = nil
                
                --if sampleFile and fso:existsAsFile( sampleFile ) then
                --    sourceFile = sampleFile
                --else
                --    Debug.pause( "no sample file" )
                --end
                
                if str:is( sourceFile ) then -- source file.
                    local ext = LrPathUtils.extension( sourceFile )
                    if settings.initFile then
                        --Debug.pause( "init-file - manny sample" )
                        import:_initFile( sourceFile, spec ) -- 
                    end
                    local newExt = import:_getNewExtension( sourceFile, spec )
                    --Debug.lognpp( spec )
                    --Debug.pause( "manny source", LrPathUtils.leafName( sourceFile ) )
                    local samplePath = import:_getNewFilePath( sourceFile, spec, newExt )
                    --Debug.pause( "manny sample", LrPathUtils.leafName( samplePath ) )
                    if str:is( samplePath ) then
                        local sup = import:getSupportType( ext )
                        if sup == 'raw' then
                            if import.ets then
                                import.ets:addArg( "-jpgFromRaw\n-b" ) -- big, but unedited.
                                import.ets:addTarget( sourceFile )
                                local rslt, errm = import.ets:execute( 30, true )
                                if not str:is( errm ) then
                                    if str:is( rslt ) then
                                        if #rslt > 300 then -- result should be at least a few hundred bytes
                                            local tempFile = LrPathUtils.getStandardFilePath( 'temp' )
                                            tempFile = LrPathUtils.child( tempFile, str:fmtx( "^1 - sample file.jpg", import:getSessionName() ) )
                                            local s, m = fso:writeFile( tempFile, rslt )
                                            if s then
                                                app:logv( "wrote raw preview to '^1'", tempFile )
                                                previewFile = tempFile
                                            else
                                                previewFile = nil
                                            end
                                        else
                                            --Debug.logn( "Raw result: " .. rslt )
                                            --Debug.pause( str:fmtx( "Invalid raw preview - ^1 bytes", #rslt ) )
                                            app:logv( "*** Invalid raw preview - ^1 bytes", #rslt )
                                            assert( previewFile == nil, "how not nil?" )
                                        end
                                    else
                                        app:logv( "No raw preview" )
                                        previewFile = nil
                                    end
                                else
                                    Debug.pause( rslt, errm or "no err" )
                                end 
                            else
                                Debug.pause( "no ets" )
                            end
                            
                        elseif sup == 'video' then
                            --previewFile = sourceFile - not reliable.
                            previewFile = nil
                        elseif sup == 'rgb' then
                            previewFile = sourceFile 
                        else
                            Debug.pause( "no sup" )
                        end
                    else
                        previewFile = nil
                        --Debug.pause( "no new file path" )
                    end
                    props.sampleFile = previewFile or nil
                    props.sampleName = sourceFile or str:fmtx( "No ^1 source sample obtainable", sampleKey ) -- LrPathUtils.leafName( previewFile )
                    props.samplePath = samplePath or str:fmtx( "No ^1 import sample obtainable", sampleKey )
                    return
                else
                    --Debug.pause( "no sample file 2" )
                end
            else
                Debug.pause( "no session", m )
            end
        else
            Debug.pause( "no set" )
        end
        props.sampleFile = nil
        props.sampleName = str:fmtx( "No ^1 source sample obtained", sampleKey ) -- LrPathUtils.leafName( previewFile )
        props.samplePath = str:fmtx( "No ^1 import sample obtained", sampleKey )
        
    end
    
    updSamplePath( props.customSetName )
    
    local function chgHdlr( id, props, key, value )
        app:pcall{ name="Ottomanic Importer - Manual Change Handler", async=true, guard=App.guardSilent, main=function( icall )
            if key == 'customSetName' then
                if value == " " then -- edit
                    local prev = app:getGlobalPref( customSetPrefName, value )
                    ottomanic:editSystemSettings( "Edit Import Settings" )
                    props[key] = prev
                    updImportSettingsMenu()
                    if call.callback then
                        call.callback()
                    end
                else
                    app:setGlobalPref( customSetPrefName, value )
                    local customSet = self:getCustomSet( value )
                    if customSet then
                        import:initImportExt( customSet.importExt ) 
                    else
                        Debug.pause( "no set" )
                    end
                end
            else
                --Debug.pause( "?" )
                --local name = app:getGlobalPrefName( key )
                --if name == 
            end
            updSamplePath( app:getGlobalPref( customSetPrefName, nil ) )
        end }
    end
    view:setObserver( props, 'customSetName', OttomanicImporter, chgHdlr )
    view:setObserver( prefs, app:getGlobalPrefKey( 'customText_1' ), OttomanicImporter, chgHdlr )
    view:setObserver( prefs, app:getGlobalPrefKey( 'customText_2' ), OttomanicImporter, chgHdlr )
    view:setObserver( prefs, app:getGlobalPrefKey( 'importNumber' ), OttomanicImporter, chgHdlr )

    local viewItems = {
        vf:row {
            vf:static_text {
                title = "Import Settings",
                width = share 'label_width',
            },
            vf:popup_menu {
                bind_to_object = props,
                value = bind( 'customSetName' ),
                items = bind 'csItems',
                width = share 'data_width',
            },
            vf:static_text {
                title = str:fmtx( "Choose existing import preset, or new/delete/modify." ),
                height_in_lines = 1,
                fill_horizontal = 1,
            },
        },
        vf:spacer{ height=15 },
        vf:view {
            vf:row {
                vf:static_text {
                    title = "Sample Source Path",
                    width = share 'label_width',
                },
                vf:static_text {
                    bind_to_object = props,
                    title = bind 'sampleName',
                    width_in_chars = 60,
                    height_in_lines = 2,
                    tooltip = "File is from photo in catalog, not file in import source - sorry, it's not optimal...",
                },
            },
            vf:row {
                --vf:static_text {
                --    title = "",
                --    width = share 'label_width',
                --},
                vf:column {
                    width = share 'label_width',
                    vf:spacer {height = 20},
                    vf:push_button {
                        title = "Raw",
                        width = share 'button_width',
                        action = function( button )
                            app:setGlobalPref( 'sampleKey', 'raw' )
                            app:pcall{ name=button.title, async=true, main=function( call )
                                updSamplePath( props.customSetName )
                            end }
                        end,
                        --bind_to_object = props,
                        --enabled = bind 'ena_raw',
                    },
                    vf:push_button {
                        title = "RGB",
                        width = share 'button_width',
                        action = function( button )
                            app:setGlobalPref( 'sampleKey', 'rgb' )
                            app:pcall{ name=button.title, async=true, main=function( call )
                                updSamplePath( props.customSetName )
                            end }
                        end,
                        --bind_to_object = props,
                        --enabled = bind 'ena_rgb',
                    },
                    vf:push_button {
                        title = "Video",
                        width = share 'button_width',
                        action = function( button )
                            app:setGlobalPref( 'sampleKey', 'video' )
                            app:pcall{ name=button.title, async=true, main=function( call )
                                updSamplePath( props.customSetName )
                            end }
                        end,
                        --bind_to_object = props,
                        --enabled = bind 'ena_video',
                    },
                },
                -- auto-import dialog box uses catalog photo as sample
                LrView.conditionalItem( auto,
                    vf:row {
                        view:getThumbnailViewItem{ viewOptions = {
                            bind_to_object = props,
                            photo = bind 'samplePhoto',
                            tooltip = "Image is of photo in catalog, not file in import source - sorry, it's not optimal...",
                        } },
                        vf:static_text {
                            bind_to_object = props,
                            title = "No preview available",
                            visible = bind {
                                keys = { 'samplePhoto' },
                                operation = function( binder, value, toView )
                                    if props.samplePhoto then
                                        return false
                                    else
                                        return true
                                    end
                                end,
                            }
                        }
                    }
                ),
                -- manual-import dialog box uses source file, or preview extraction, as sample.
                LrView.conditionalItem( not auto,
                    vf:row {
                        vf:picture {
                            bind_to_object = props,
                            value = bind 'sampleFile',
                            width = 300,
                            height = app:getPref( 'sampleThumbHeight' ) or 200,
                        },
                        vf:static_text {
                            bind_to_object = props,
                            title = "No preview available",
                            visible = bind {
                                keys = { 'sampleFile' },
                                operation = function( binder, value, toView )
                                    if props.sampleFile then
                                        return false
                                    else
                                        return true
                                    end
                                end,
                            }
                        }
                    }
                ),
                --
            },
            vf:spacer{ height=10 },
            vf:row {
                vf:static_text {
                    title = "Sample Import Path",
                    width = share 'label_width',
                },
                vf:static_text {
                    bind_to_object = props,
                    title = bind 'samplePath',
                    width_in_chars = 60,
                    height_in_lines = 2,
                    tooltip = "If the above file were being imported (it might not be), then this is what it's path would be.",
                },
            },
        },
        vf:spacer{ height=15 },
        vf:row {
            vf:static_text {
                title = "Custom Text",
                width = share 'label_width',
            },
            vf:edit_field {
                bind_to_object = prefs,
                value = app:getGlobalPrefBinding( "customText_1" ),
                width_in_chars = 15,
            },
            vf:edit_field {
                bind_to_object = prefs,
                value = app:getGlobalPrefBinding( "customText_2" ),
                width_in_chars = 15,
            },
            vf:spacer { width = 20 },
            vf:static_text {
                title = "Start Number",
                tooltip = "Edit this to change the starting value of \"Import Item Number\", or leave as is so next import starts where previous import left off...",
            },
            vf:edit_field {
                bind_to_object = prefs,
                --value = app:getGlobalPrefBinding( "customNum_1" ),
                value = app:getGlobalPrefBinding( "importNumber" ), -- perhaps I need to versions of import-number, just like I have for custom settings name, i.e. auto & manual.
                min = 0,
                max = 9999999,
                precision = 0,
                width_in_digits = 7,
            },
        },
    }
    return viewItems
end



--  Called for each file in an auto-importing folder - may be already in catalog, may be new...
--
function OttomanicImporter:_considerAutoImportingFile( file, spec, iOne, iTwo )
    app:assert( spec.auto, "not auto spec" ) -- note: auto will be false in manual spec.
    Debug.pauseIf( spec.readMetadata == nil ) -- cheap insurance to make sure the new additions are being initialized ###2 remove after a while..
    Debug.pauseIf( spec.removeDeletedPhotos == nil ) -- ditto
    if app:isVerbose() and app:isAdvDbgEna() then
        app:logV()
        app:logV( "Considering auto-import of ^1", file )
    end
    local icall = spec.call or Debug.pause( "no icall" )
    local filename = LrPathUtils.leafName( file )
    local s, m, aic = spec.import:fileAsSpecified( file, spec, iOne, iTwo ) -- or don't import, depending on criteria and discovery..
    if s then
        if m then -- imported
            app:log( "Imported ^1 - and added to plugin's auto-import collection.", file )
            local icount = spec.import.stats:getStat( 'imported' ) -- returns 0 if un-init, never nil.
            icall:setCaption( "#^1: ^2", icount, filename ) -- I guess this is just ignored unless ad-hoc/temporary? ###
            --Debug.pause( icall.cap )
        elseif aic then -- no error, but still not imported, e.g. already in catalog..
            if spec.readMetadata then
                self:autoReadMetadata( file, spec )
            end
        -- else some other reason, like non-importable extension..
        end
    elseif m ~= nil then
        app:logWarning( m ) -- happens sometimes during normal operation when user deletes a photo (it's removed first from catalog, *then* from disk - with a yield in-between, no doubt).
        local cap
        if icall.scope then
            cap = icall:getCaption()                            
            icall:setCaption( "*** ^1 - NOT imported.", filename )
        end
        app:sleep( 3 ) -- error hold-off.
        icall:setCaption( cap ) -- restore previous caption - note: if persistent error, it will reappear.
    else
        Debug.pause( "no s, no m - hmm..." )
    end
    return s, m, aic
end



--  perform auto-import based on spec (one folder) - needs error handling wrappage in calling context.
--
--  Supports recursive auto-import, and looks up photos in catalog each time...
--
--  @usage Handles all: ad-hoc auto-import, permanent auto-import, and auto-import selected folder (once will be true in this latter case).
--
--  @spec (table, required) import spec.
--
function OttomanicImporter:_autoImport( spec )
    local cap
    if spec.call.scope then
        cap = spec.call:getCaption()
    end
    app:callingAssert( spec.removeDeletedPhotos ~= nil, "assure spec includes remove-deleted-photos" )
    local settings = spec.settings or error( "no settings" )
    local files
    if spec.recursive then
        files = LrFileUtils.recursiveFiles
    else
        files = LrFileUtils.files
    end
    local uiTidbit
    if type( spec.auto ) == 'boolean' then
        uiTidbit = "ad-hoc"
    else
        uiTidbit = spec.auto -- either "Auto-mirror Folders" or "Auto-import upon folder selection" or something to that effect.
    end
    local a1, a2 -- flags which determine whether disable message has already been displayed.
    -- auto-import one folder, as specified, unless auto-importing is disabled.
    local function _import( )
        local quit
        app:pcall{ name="Auto-Import", async=false, main=function( call )
            repeat
                if not app:isPluginEnabled() then
                    if not a1 then
                        app:log( "*** Plugin is disabled - no auto importing will take place until it is re-enabled." )
                        a1 = true
                    end
                    break
                else
                    a1 = false
                end
                if not app:getGlobalPref( 'autoImportEnable' ) then
                    if not a2 then
                        app:log( "*** Auto-import is disabled - no auto importing will take place until it is re-enabled." )
                        a2 = true
                    end
                    break
                else
                    a2 = false
                end
                local yc = 0
                local folderPath = cat:getFolderPath( spec.folder )
                local folderName = LrPathUtils.leafName( folderPath ) -- it's faster if you've already got path to get name as leaf than via a call to folder method for getting-name.
                app:logV()
                app:logV( "Auto-importing folder (^1): ^2", uiTidbit, folderPath )
                if spec.recursive then
                    app:logV( "    - recursively." )
                end
                if spec.call.scope then
                    spec.call:setCaption( "Checking ^1^2", folderName, spec.recursive and "/*" or "" )
                end
                -- consider all files in disk folder
                for file in files( folderPath ) do
                    yc = app:yield( yc ) -- yield every 20 times (not necessary to be so careful with yielding in Lr4, but Lr3 is also supported).
                    self:_considerAutoImportingFile( file, spec ) -- logs stuff... (no return value).
                    --app:log( "Consider ^1", file )
                    if spec.call:isQuit() or not app:getGlobalPref( 'autoImportEnable' ) then
                        --Debug.pause( spec.auto )
                        quit = true
                        return
                    end
                end
                if spec.removeDeletedPhotos then
                    -- consider all photos in catalog folder
                    local toDel = {}
                    for i, photo in ipairs( spec.folder:getPhotos( spec.recursive ) or {} ) do
                        local photoPath = photo:getRawMetadata( 'path' ) -- cache?
                        if fso:existsAsFile( photoPath ) then
                            -- splatt
                        else -- no doobie
                            local parentFolder = LrPathUtils.parent( photoPath )
                            local ancestorFolderExists
                            while parentFolder and ( #parentFolder > 1 ) do -- do not consider '/' existences as "adequate".
                                if fso:existsAsDir( parentFolder ) then
                                    ancestorFolderExists = true
                                    break
                                else
                                    parentFolder = LrPathUtils.parent( parentFolder )
                                end
                            end
                            if ancestorFolderExists then
                                toDel[#toDel + 1] = photo
                            end
                        end
                    end
                    if #toDel > 0 then
                        -- note: del-coll is being shared by *all* forms of import/rmv-del, so can't really be cleared at initiation of any one op.
                        local s, m = cat:update( -5, "Update Deleted Photos Collection", function( context, phase )
                            delColl:addPhotos( toDel )
                        end )
                        if s then
                            
                            -- in case of forced scan maybe it should be done at end in calling context ###2.
                            app:pcall{ name="OttomanicImporter_autoImport", async=true, guard=App.guardSilent, function( call )
                                while #delColl:getPhotos() > 0 do
                                    ottomanic:_removeDeletedPhotos( "Remove deleted photos to honor auto-import" ) -- this may present prompt,
                                    -- or may not - but if not, there will be a lengthy delay *before* pulling photos from del-coll.
                                end
                            end }
                            
                        else
                            app:logW( m )
                        end
                    else
                        if spec.recursive then
                            app:logV( "No missing photos in '^1' or subfolders.", folderPath ) 
                        else
                            app:logV( "No missing photos in '^1' (did not consider subfolders).", folderPath ) 
                        end
                    end
                end
            until true
            if spec.call:isQuit() or not app:getGlobalPref( 'autoImportEnable' ) then
                --Debug.pause() -- not gonna happen too much anymore, but cheap insurance.
                quit = true
                return
            end    
        end, finale=function( call )
            if not call.status then
                app:logErr( call.message )
                -- reminder: this not called in manual mode, *except* catalog-sync, which is almost more like manual - oh well ###2.
                background:displayErrorX( { id="AutoImportError", immediate=true, promptWhenUserCancels=true }, call.message )
                -- note: auto-import-error will get cleared upon successful import, so this may not stay displayed for long - depends..
                app:sleep( 3 ) -- so he/she can see..
            end
        end }
        return quit
    end
    
    -- historical note: _import used to be called repeatedly when programmed scan interval was supported instead of dir-chg events from app.
    app:logV( "Attempting auto-import of folder - just once, for now.." )
    _import() -- exiftool session is not closed, but it's OK - one session "forever" to support background process(es).. ad-hoc sessions must be killed externally.
    if cap then spec.call:setCaption( cap ) end
    
end



--  Translates parameters into a spec "object" (table), which can be passed around...
--  This spec can be considered to represent an initialized import session (includes a fresh, new, private, initialized 'Import' instance).
function OttomanicImporter:_createSpec( call, folder, recursive, importCustomSet, customText_1, customText_2, coll, card, auto, readMetadata, removeDeletedPhotos )
    app:callingAssert( type( importCustomSet ) == 'table', "import set must be table" )
    app:callingAssert( type( customText_1 ) == 'string', "ct1 must be string" ) -- pass "" if don't care - needed for parameter passing assurance.
    app:callingAssert( type( customText_2 ) == 'string', "ct2 must be string" ) -- pass "" if don't care - needed for parameter passing assurance.
    app:callingAssert( type( importCustomSet) == 'table', "import set must be table" )
    app:callingAssert( type( readMetadata )=='boolean', "read-metadata must be boolean" )
    app:callingAssert( type( removeDeletedPhotos )=='boolean', "remove-deleted-photos must be boolean" )
    local import=Import:new{ importExt = importCustomSet.importExt } -- separate import object for each spec.
    local settings = import:initSettings( importCustomSet, customText_1, customText_2 )
    app:assert( settings, "no settings" )
    local spec = { call=call, folder=folder, recursive=recursive, settings=settings, coll=coll, import=import, card=card, auto=auto, readMetadata=readMetadata, removeDeletedPhotos=removeDeletedPhotos }
    local s, m = import:initSession( spec ) -- creates new exiftool session, unless auto is string.
    if s then
        assert( import.record, "no import record" )
    else
        app:error( m )
    end
    return spec
end



--  saves auto-start parameters in prefs, so they can be re-read upon Lr startup.
--  Note - this is to support auto-import-folders on a permanent basis.
function OttomanicImporter:_saveAutoStartFolder( folder, customSetName, customText_1, customText_2, recursive )
    app:assert( str:is( customSetName ), "no cset name" )
    local uuid = LrUUID.generateUUID()
    local prefName = str:fmtx( "autoStartFolder_^1", uuid ) -- note: the UUID is meaningless: just a way to assure uniqueness.
    --Debug.pause( "starting", prefName )
    local path = cat:getFolderPath( folder )
    app:setPref( prefName, { folderPath=path, recursive=recursive, customSetName=customSetName, customText_1=customText_1, customText_2=customText_2 } ) -- for startup next time.
    app:log( "Remembering ^1 for next Lightroom startup.", path )
end



--  read previously saved auto-import-folder info, so it can be used to re-start auto-import upon Lr restart.
--  @return spec (if custom-set of same name still exists).
--  @return qual - error message if custom-set does not exist.
function OttomanicImporter:_loadAutoStartSpec( folder, value )
    if value.customSetName then
        --
    else
        --Debug.lognpp( value )
        --Debug.showLogFile()
        return nil, "Custom set name is not defined"
    end
    local call = nil -- filled in later
    
    local customSet = self:getCustomSet( value.customSetName )
    if customSet ~= nil then
        --
    else
        return nil, str:fmtx( "Custom set no longer exists: ^1", value.customSetName )
    end
    -- reminder: specs could be from a previous version of OI.
    value.readMetadata = value.readMetadata or false
    value.removeDeletedPhotos = value.removeDeletedPhotos or false
    local spec, qual = self:_createSpec( call, folder, value.recursive, customSet, value.customText_1 or "", value.customText_2 or "", autoImportCollAdHoc, false, true, value.readMetadata, value.removeDeletedPhotos ) -- folder not card, auto, changes handled via dir-chg app, so interval no longer applies.
    -- note: each created spec represents a new import session - not sure why I'm passing boolean for auto instead of just folder-name, but that's how it is.
    if spec then
        app:log( "Lightroom startup spec created, name: ^1, path: ^2", value.customSetName, cat:getFolderPath( folder ) )
        return spec
    else
        return nil, qual
    end
end



--  Called to start watching permanently (needs error handling wrappage in calling context).
--  Notes:
--      * Called upon startup (async init) with nil params.
--      * Called by menu handler with params derived from active sources and UI.
--
function OttomanicImporter:_autoStartPerm( lrFolderSet, recursive, readMetadata, removeDeletedPhotos, customSetName, importCustomSet, t1, t2, n1 )

    local startupFlag

    local specs = {} -- specs to auto-start permanently - keys are lr-folders.
    
    -- populate specs:
    if lrFolderSet == nil then -- called from background init task.
        -- compute specs based on saved prefs.
        assert( recursive == nil, "how recursive?" )
        assert( importCustomSet == nil, "how icset?" )
        startupFlag = true
        for name, value in app.prefMgr:getPrefPairs() do -- not sorted, current preset.
            if name:find( "autoStartFolder_" ) then
                if value then
                    if value.folderPath then
                        app:log( "Considering auto-import of folder: '^1'", value.folderPath )
                        local lrFolder = cat:getFolderByPath( value.folderPath ) -- changed 2/Jun/2014 2:12 to support unmapped windows network drives.
                        if lrFolder then
                            local spec, qual = self:_loadAutoStartSpec( lrFolder, value )
                            if spec ~= nil then
                                specs[lrFolder] = spec -- more will be logged below.
                            else
                                app:logErr( qual or "no qualification" )
                            end
                        else
                            -- Debug.lognpp( value )
                            -- either it no longer exists, or is an auto-import folder for a different catalog.
                            if fso:existsAsDir( value.folderPath ) then
                                app:log( "*** Folder exists on disk, but does not exist in presently active catalog. It may exist in a different catalog. If not, consider importing the folder (or a photo therein), then select it and choose 'Auto Import - Stop' from the Library menu." )
                            else
                                app:setPref( name, nil ) -- clear.
                                app:logWarning( "*** Folder no longer exists on disk, nor in catalog - auto-importing of said folder has been disabled." ) -- reminder: this will happen if folder *does* exist in a different catalog.
                            end
                        end
                    else
                        app:logWarning( "Bad value found - consider clearing all settings using plugin manager." )
                    end
                else
                end            
            -- else some other pref.
            end
        end
    else -- starting up selected folders.
        -- translate parameters into specs.
        app:callingAssert( type( readMetadata ) == 'boolean', "pass boolean true or false for read-metadata" )
        app:callingAssert( type( removeDeletedPhotos ) == 'boolean', "pass boolean true or false for remove-deleted-photos" )
        for folder, t in pairs( lrFolderSet ) do
            if t then
                local call = nil -- filled in later
                local spec, qual = self:_createSpec( call, folder, recursive, importCustomSet, t1 or "", t2 or "", autoImportCollAdHoc, false, true, readMetadata, removeDeletedPhotos ) -- ditto.
                if spec then
                    specs[folder] = spec
                else
                    app:logWarning( qual )
                end
            else
                Debug.pause( "false negative" ) -- should never happen.
            end
        end
    end
    
    if not tab:isEmpty( specs ) then
        app:log( "Autostarting persistent auto-import folders." )
    else
        app:log( "No persistent auto-import folders discovered for auto-startup..." )
        return 0 -- handle appropriately in calling context, knowing already logged.
    end

    -- startup permanent ad-hoc auto-imports - one task for each permanent spec/folder.
    local nStarted = 0
    for folder, spec in pairs( specs ) do -- likely no more than a few specs
        repeat
            local folderPath = cat:getFolderPath( folder ) -- again, would be slightly better to have specs for folder objects instead of paths, but small price overall.
            if self.permPaths[folderPath] then -- probably should check temp-paths too.
                app:error( "folders should be pre-checked before starting" ) -- this should not happen.
            end
            if not startupFlag then -- not called from startup based on pre-existing prefs.
                assert( str:is( customSetName ) , "no settings name" ) -- redundent, but comforting.
                self:_saveAutoStartFolder( spec.folder, customSetName, spec.customText_1, spec.customText_2, spec.recursive )
            else -- pref already exists
                -- do not create duplicate entry.            
            end
            nStarted = nStarted + 1
            app:pcall{ name=folder:getName() .. " - Permanent", async=true, progress=false, main=function( icall )
                assert( spec.folder, "no folder" )
                icall.lrFolder = spec.folder
                spec.call = icall
                icall.spec = spec
                
                -- reminder: each new spec created, represents a new import session.
                self.permPaths[folderPath] = icall.spec -- consider spec/path reserved for ad-hoc/perm, until further notice..

                repeat
                    local registered = self:_register( spec )
                    -- do force scan whether registration successful or not - I think the handling is robust enough that new files etc.
                    -- will be handled by whichever task gets there first (change task or force-scan), and the other task will cope..
                    -- the goal of registration before force-scan: assure no changes are lost between force-scan and reg (if doing the other way around).
                    -- note: registration method itself has adequate logging.
                    local s, m = LrTasks.pcall( OttomanicImporter._autoImport, ottomanic, spec ) -- also has adequate logging, and caption.
                    if s and not spec.call:isQuit() then
                        app:log( "Folder should be up to date now, auto-import-(ad-hoc)-wise: ^1", cat:getFolderPath( spec.folder ) )
                        if registered then -- app healthy and registration (plus everything else) up to date at this point.
                            app:sleep( math.huge, 7, function() -- sleep and listen for dir-chg events to keep up to date.
                                local s, m = dirChgApp:getPresence( 7 ) -- "foreground" name.
                                if s then
                                    app:logV( "Dir/File Change Notification App continues to serve permanent ad-hoc auto-importing of folder: ^1", folderPath )
                                    return spec.call:isQuit() -- continue to sleep, unless done.
                                elseif m == 'offline' then -- app down
                                    app:log( "*** Dir/File Change Notification App went down - not to worry: baseline-scan will assure no events are lost, and when app comes back up - efficiency will be restored.." ) -- folder path will be logged.
                                    return true -- wake up and re-try re-registration, followed by force scan regardless of success.
                                else -- this happens if some thread hogs the CPU or what have you - just keep quiet for now..
                                    dbgf( "app presence iffy: ^1", m )
                                end
                            end )
                        else
                            app:logW( "Baseline folder scan (ad-hoc/permanent auto-import) completed OK, but registration for dir changes was unsuccessful, will retry.." )
                        end
                    else
                        app:logW( "Baseline folder scan (ad-hoc/permanent auto-import) did not complete successfully, will keep trying - ^1", m or "no more info" )
                    end
                until spec.call:isQuit()
                -- quit, because of user cancel or reload.
                if not shutdown then -- not reload.
                    app:logV( "Ad-hoc auto-importer stopped - unregistering.." )
                    -- note: it may have never been successfully registered, but better to take a whack at un-registering - it won't hurt the app, so cheap insurance.
                    local unregistered = self:_unregister( spec ) -- info is logged within.
                    Debug.pauseIf( not unregistered )
                end
                
                -- regardless of why we're quit, perm-path/spec is history..
                self.permPaths[folderPath] = nil -- in case end-session in finale method errors out.
                        
            end, finale=function( icall )
                icall.spec.import:endSession( icall.spec ) -- close exiftool session if open..
                if folderPath then
                    self.permPaths[folderPath] = nil
                end
            end }
        until true
    end
    app:log( "^1 permanent auto-import folders were started.", nStarted )
    return nStarted
end



--  'Auto-Import - Start' menu handler.
--  Scrutinizes already started auto-importing folders, then presents UI.
--  Based on user preferences, starts ad-hoc or starts-and-records permanent import session.
function OttomanicImporter:start( title )
    local import
    app:service{ name=title, async=true, guard=App.guardVocal, progress=true, main=function( call )
    
        call:setCaption( "Dialog box needs your attention..." )
        if not app:getGlobalPref( 'autoImportEnable' ) then
            app:show{ warning="Auto-importing is disabled - visit plugin manager to re-enable." }
            call:cancel()
            return
        end
    
        self:_initForStartStop( call, true ) -- note: there is no background-pause in here but it should be OK, since
        -- ad-hocs naturally take priority over folder-sel and mirroring, so there should be no conflict, he said..
        if call:isQuit() then
            return
        end 
        
        local ena = app:getPref( 'autoImportSelFolder' )
        local ena2 = app:getPref( 'autoMirrorFolders' )
        local button -- could just use tidbits, but hey..
        -- reminder: mirroring function will detect ad-hoc auto-importers and "step aside".
        if ena and ena2 then -- sel-folder & mirroring are enabled.
            button = app:show{ confirm="Auto-importing folders started in this fashion (ad-hoc), will no longer auto-import upon selection, until ad-hoc auto-importing is stopped, at which point they will resume auto-importing upon selection..\n \nLikewise, if folder or subfolder is/was auto-mirroring, it will discontinue until ad-hoc auto-importing of said folder is stopped.",
                buttons = { dia:btn( "Yes - that's fine..", 'ok' ), dia:btn( "Cancel - need to rethink this....", 'cancel', false ) },
                actionPrefKey = "start ad-hoc auto-importing folder despite \"auto-import upon folder selection\" and auto-mirroring",
            }
        elseif ena then -- sel-folder
            button = app:show{ confirm="Auto-importing folders started in this fashion (ad-hoc), will no longer auto-import upon selection, until ad-hoc auto-importing is stopped, at which point they will resume auto-importing upon selection..",
                buttons = { dia:btn( "Yes - that's fine..", 'ok' ), dia:btn( "Cancel - need to rethink this....", 'cancel', false ) },
                actionPrefKey = "start ad-hoc auto-importing folder despite \"auto-import upon folder selection\"",
            }
        elseif ena2 then -- mirror
            button = app:show{ confirm="If folder or subfolder is/was auto-mirroring, it will discontinue until ad-hoc auto-importing of said folder is stopped.",
                buttons = { dia:btn( "Yes - that's fine..", 'ok' ), dia:btn( "Cancel - need to rethink this....", 'cancel', false ) },
                actionPrefKey = "start ad-hoc auto-importing folder despite \"auto-mirroring\"",
            }
        else
            button='ok'
        end
        if button == 'ok' then
            -- proceed
        elseif button == 'cancel' then
            call:cancel()
            return
        else
            error( "bad button" )
        end

        if tab:isEmpty( call.lrFoldersRipeForStarting ) then
            app:show{ warning="None of selected folders are ripe for initiating ad-hoc auto-import - see log file..",
                --subs = { str:nItems( #call.lrFolders, "selected folders" ) },
            }
            call:cancel()
            return
        end    
        local array = tab:createArrayFromSet( call.lrFoldersRipeForStarting )
        local props = LrBinding.makePropertyTable( call.context ) -- needed for common view items.
        app:initGlobalPref( 'recursive', false )
        app:initGlobalPref( 'forever', false )
        app:initGlobalPref( 'readMetadata', false )
        app:initGlobalPref( 'removeDeletedPhotos', false )
        local tb
        if #array == 1 then
            tb = str:fmtx( "one folder: '^1'", array[1]:getName() )
        else
            tb = str:nItems( #array, "folders" )
        end
        
        local customSetName = app:getGlobalPref( 'customSetNameAuto' )
        local customSet = self:getCustomSet( customSetName ) or {} -- or error?
        import = Import:new{ importExt = customSet.importExt or { raw={}, rgb={}, video={} } } -- Note: this is just to get the ball rolling - import w/ proper import-ext will be used when the time comes.
        local viewItems = self:_initCommonViewItems( props, import, true, call ) -- auto - note: ets for sample path is not opening and closing then auto-dialog box like it is for manual.
        
        viewItems[#viewItems + 1] = vf:spacer{ height=15 }
        viewItems[#viewItems + 1] =
            vf:row {
                vf:checkbox {
                    title = "Auto-import from subfolders too",
                    value = app:getGlobalPrefBinding( 'recursive' ),
                    tooltip = "aka \"recursive\"",
                },
                vf:spacer{ width=10 },
                vf:checkbox {
                    title = "Auto-read changed metadata",
                    value = app:getGlobalPrefBinding( 'readMetadata' ),
                    tooltip = "If checked, then when(if) metadata (e.g. xmp) changes, it will be read automatically from file to catalog; if unchecked, changed source and sidecar files will be ignored.\n \n*** Note: metadata will only be read if it *changes*. It is highly recommended to resolve any existing metadata status issues before enabling this feature.",
                },
                vf:spacer{ width=10 },
                vf:checkbox {
                    title = "Auto-remove deleted photos",
                    value = app:getGlobalPrefBinding( 'removeDeletedPhotos' ),
                    tooltip = "If checked, photos will be removed if source file no longer present on disk - at least one ancestor folder MUST exist (not necessarily parent); if unchecked, no attention paid to source file presence..",
                },
            }
        viewItems[#viewItems + 1] = vf:row {
                vf:checkbox {
                    bind_to_object = prefs,
                    title = "Re-initiate upon startup",
                    value = app:getGlobalPrefBinding( 'forever' ),
                    tooltip = "if checked: folder(s) will resume auto-importing (ad-hoc) upon startup - \"permanently\"/\"forever\" - until you explicitly stop them; if unchecked, they will cease auto-importing when you click the 'X' in the progress scope (upper left corner of Lightroom UI), or when you restart Lightroom.",
                },
            }
        view:setObserver( prefs, app:getGlobalPrefKey( 'forever' ), OttomanicImporter, function( id, props, key, value )
            if value then
                local button = app:show{ confirm="With 'Re-initiate upon startup' box ticked, auto-importing will happen without a progress scope displayed in upper left corner of Lightroom UI. If this is your first time, I recommend leaving this unchecked, so you have visual feedback in the form of that progress scope.\n \nLeave 'Re-initiate upon startup' checked?",
                    buttons = { dia:btn( "Yes - I want it checked", 'ok' ), dia:btn( "No - you talked me out of it", 'cancel' ) },
                    actionPrefKey = "are you sure you want to re-initiate auto-importing upon startup",
                }
                if button == 'cancel' then
                    app:setGlobalPref( 'forever', false )
                end
            end
        end )
        local button = app:show{ confirm="Start ad-hoc auto-importing? (^1)",
            subs = { tb },
            --buttons = { dia:btn( "Yes - For Now (until canceled)", "ok" ), dia:btn( "Yes - Forever (re-initiate upon startup)", "other" ) },
            buttons = { dia:btn( "Yes - Start Now", "ok" ) },
            viewItems = viewItems,
        }
        if button == 'cancel' then
            call:cancel()
            return
        end
        call:setCaption( "Initializing auto-import folders..." )
        local forever = app:getGlobalPref( 'forever' )
        local recursive = app:getGlobalPref( 'recursive' )
        local readMetadata = app:getGlobalPref( 'readMetadata' )
        local removeDeletedPhotos = app:getGlobalPref( 'removeDeletedPhotos' )
        assert( recursive ~= nil, "bad recursive" )
        assert( readMetadata ~= nil, "bad read-metadata" )
        local customSetName = app:getGlobalPref( 'customSetNameAuto' )
        local importCustomSet = self:getCustomSet( customSetName ) or error( "no set" )
        local customText_1 = app:getGlobalPref( 'customText_1' )
        local customText_2 = app:getGlobalPref( 'customText_2' )
        
        -- 'array' is of folders pre-checked and ripe for auto-import initiation.
        if not forever then
            local nStarted = 0
            for i, lrFolder in ipairs( array ) do
                repeat
                    local folderPath = cat:getFolderPath( lrFolder )
                    if self.tempPaths[folderPath] then -- probably should be an error if perm-paths too.
                        app:error( "folders should be pre-checked before starting" ) -- this should not happen.
                    end
                    nStarted = nStarted + 1
                    app:pcall{ name=lrFolder:getName() .. " - Temporary", async=true, progress={ title=str:fmtx( "^1 - ^2", app:getAppName(), lrFolder:getName() ), caption=str:fmtx( "Auto-importing... (click the 'X' to stop)" ) }, main=function( icall )
                        local spec, qual = self:_createSpec( icall, lrFolder, recursive, importCustomSet, customText_1 or "", customText_2 or "", autoImportCollAdHoc, false, true, readMetadata, removeDeletedPhotos ) -- folder not card, auto(boolean), ...
                        if spec then
                            icall.spec = spec
                        else
                            app:logWarning( qual )
                            return
                        end
                        
                        -- reminder: each new spec created, represents a new import session.
                        self.tempPaths[folderPath] = icall.spec -- consider spec/path reserved for ad-hoc/temp, until further notice..

                        repeat
                            local registered = self:_register( spec )
                            -- do force scan whether registration successful or not - I think the handling is robust enough that new files etc.
                            -- will be handled by whichever task gets there first (change task or force-scan), and the other task will cope..
                            -- the goal of registration before force-scan: assure no changes are lost between force-scan and reg (if doing the other way around).
                            -- note: registration method itself has adequate logging.
                            local s, m = LrTasks.pcall( OttomanicImporter._autoImport, ottomanic, spec ) -- also has adequate logging, and caption.
                            if s and not spec.call:isQuit() then
                                app:log( "Folder should be up to date now, auto-import-(ad-hoc)-wise: ^1", cat:getFolderPath( spec.folder ) )
                                if registered then -- app healthy and registration (plus everything else) up to date at this point.
                                    app:sleep( math.huge, 7, function() -- sleep and listen for dir-chg events to keep up to date.
                                        local s, m = dirChgApp:getPresence( 7 ) -- "foreground" name.
                                        if s then
                                            app:logV( "Dir/File Change Notification App continues to serve temporary ad-hoc auto-importing of folder: ^1", folderPath )
                                            return spec.call:isQuit() -- continue to sleep, unless done.
                                        elseif m == 'offline' then -- app down
                                            app:log( "*** Dir/File Change Notification App went down - not to worry: baseline-scan will assure no events are lost, and when app comes back up - efficiency will be restored.." ) -- folder path will be logged.
                                            return true -- wake up and re-try re-registration, followed by force scan regardless of success.
                                        else -- this happens if some thread hogs the CPU or what have you - just keep quiet for now..
                                            dbgf( "app presence iffy: ^1", m )
                                        end
                                    end )
                                else
                                    app:logW( "Baseline folder scan (ad-hoc/temporary auto-import) completed OK, but registration for dir changes was unsuccessful, will retry.." )
                                end
                            else
                                app:logW( "Baseline folder scan (ad-hoc/temporary auto-import) did not complete successfully, will keep trying.. - ^1", m )
                            end
                        until spec.call:isQuit()
                        -- quit, because of user cancel or reload.
                        if not shutdown then -- not reload.
                            app:logV( "Ad-hoc auto-importer stopped - unregistering.." )
                            -- note: it may have never been successfully registered, but better to take a whack at un-registering - it won't hurt the app, so cheap insurance.
                            local unregistered = self:_unregister( spec ) -- info is logged within.
                            Debug.pauseIf( not unregistered )
                        end
                        
                        -- regardless of why we're quit, temp-path/spec is history..
                        self.tempPaths[folderPath] = nil -- in case end-session in finale method errors out.
                        
                    end, finale=function( icall )
                        icall.spec.import:endSession( icall.spec ) -- this is temp import, not sample path.
                        if folderPath then
                            self.tempPaths[folderPath] = nil
                        end
                    end }
                until true
            end
            -- really don't need to prompt user about number started, since they are evidenced in the progress corner.
            app:log( "^1 ad-hoc auto-imports were started.", nStarted )
        else -- forever
            local nStarted = self:_autoStartPerm( call.lrFoldersRipeForStarting, recursive, readMetadata, removeDeletedPhotos, customSetName, importCustomSet, customText_1, customText_2 )
            app:show{ info="^1 permanent auto-import folders started.",
                subs = nStarted,
                actionPrefKey = "permanent auto-import folders started",
            }
        end
    
    end, finale=function( call )
        if import then
            -- this import is just for sample-path, so no harm ending the session (just closes the ets).
            import:endSession( import.spec )
        end
    end }
end



--  'Auto-Import - Stop' menu handler.
--
function OttomanicImporter:stop( title )
    app:service{ name=title, async=true, guard=App.guardVocal, progress=true, main=function( call )
        self:_initForStartStop( call )
        if call:isQuit() then
            return
        end    
        --if tab:isEmpty( self.tempSpecs ) and tab:isEmpty( self.permSpecs ) then
        if tab:isEmpty( self.tempPaths ) and tab:isEmpty( self.permPaths ) then
            app:show{ warning="No selected folder(s) are started, so none can be stopped." }
            call:cancel()
            return
        end
        assert( #call.lrFolders ~= 0, "folder mixup" )
        local tb
        if #call.lrFolders == 1 then
            tb = call.lrFolders[1]:getName()
        else
            tb = str:nItems( #call.lrFolders, "folders" )
        end
        local button = app:show{ confirm="Stop (ad-hoc) auto-importing? (^1)",
            subs = { tb },
            actionPrefKey = "Stop (ad-hoc) auto-importing",
        }
        if button == 'cancel' then
            call:cancel()
            return
        end
        app:log()    
        for i, lrFolder in ipairs( call.lrFolders ) do
            local folderPath = cat:getFolderPath( lrFolder )
            --if self.tempSpecs[lrFolder] then
            if self.tempPaths[folderPath] then
                local spec = self.tempPaths[folderPath]
                local icall = spec.call
                if icall and icall.scope then
                    app:logVerbose( "Ad-hoc auto-import folder should stop in a micro-second or so." ) -- per-folder task is waiting for cancelation to quit.
                    icall.scope:cancel()
                else
                    app:logErr( "ad-hoc auto-importer sans icall or scope - can't stop it." )
                end
            elseif self.permPaths[folderPath] then
                local spec = self.permPaths[folderPath]
                local icall = spec.call
                if icall then -- it's been started
                    local path
                    for name, value in app.prefMgr:getPrefPairs() do -- not sorted, current preset.
                        if name:find( "autoStartFolder_" ) then -- value should be path.
                            if value then
                                local folderPath = value.folderPath
                                local recursive = value.recursive
                                if folderPath == cat:getFolderPath( lrFolder ) then
                                    local sesn = exifTool:getSession( lrFolder:getName() ) -- et session-name is just folder name.
                                    if sesn then
                                        --Debug.pause( "closing exiftool session" )
                                        Debug.pauseIf( sesn:getName() == "Sample Path" )
                                        exifTool:closeSession( sesn ) -- logs closing verbosely, including session name.
                                        app:log( "Auto-import exiftool session closed." )
                                    end
                                    path = folderPath
                                    --Debug.pause( "stopping/clearing perm", name )
                                    app:setPref( name, nil ) -- clear pref.
                                    break   -- found it. most efficient to break here, but more robust to clear-all, in case format of key changes, so none linger from previous.
                                            -- on the other hand, I can always add upgraded logic in future version, to detect previous remnants.
                                end
                            else
                                app:logErr( "bad path" )
                            end
                        else
                            -- some other pref.
                        end
                    end
                    if path then
                        app:logVerbose( "Persistent auto-import folder should stop in a micro-second or so." )
                    else
                        app:logWarning( "Persistent auto-import folder should stop in a micro-second or so, but path was not found in startup registry." )
                    end
                    icall:cancel()
                else
                    app:logErr( "permanent auto-importer sans icall - can't stop it." )
                end
            else
                -- n/a            
            end
        end
    end }
end



--  'Auto-Import - Show' menu handler.
function OttomanicImporter:show( title )
    app:service{ name=title, async=true, guard=App.guardVocal, progress=true, main=function( call )
        local button = app:show{ confirm="Select permanent \"ad-hoc\" auto-importing folders?\n \n(hint: 'recursive' means auto-importing from subfolders too)",
            buttons = { dia:btn( "Yes - non-recursive too", 'ok' ), dia:btn( "Yes - recursive only", 'other' ) },
            actionPrefKey = "Select permanent ad-hoc auto-importing folders",
        }
        if button == 'cancel' then
            call:cancel()
            return
        end
        local recursiveOnly = ( button == 'other' )
        local set = {}
        app:log()
        app:log( "Permanent (ad-hoc) auto-importing folders (excluding temporary/for-now folders):" )
        app:log( "-------------------------------------------------------------------------------" )
        for folderPath, spec in pairs( self.permPaths ) do
            repeat
                if not spec then -- never happens
                    break
                end
                -- sanity check:
                local folder = cat:getFolderByPath( folderPath )
                if folder then assert( spec.folder == folder, "folder/spec mis-match" ) end
                ----------------
                if spec then
                    local recursive = spec.recursive
                    assert( recursive ~= nil, "no recursive" )
                    if recursive then
                        set[spec.folder] = true
                        app:log( "Auto importing folder recursively: ^1", folderPath )
                    elseif not recursiveOnly then
                        set[spec.folder] = true
                        app:log( "Auto importing folder non-recursively: ^1", folderPath )
                    end
                else
                    app:logErr( "permanent auto-importer with no spec" )
                end
            until true
        end
        app:log()
        local array = tab:createArrayFromSet( set )
        if #array > 0 then
            catalog:setActiveSources( array )
            app:log( "Permanent (ad-hoc) auto-importing folders should be active sources now." )
            app:show{ info="^1 (as specified) selected in folders panel.",
                subs = { str:nItems( #array, "auto-importing folders" ) },
                actionPrefKey = "ad-hoc auto-importing folders shown"
            }
        else
            app:log( "No (ad-hoc/forever) auto-importing folders are defined as specified." )
            app:show{ info="No (ad-hoc/forever) auto-importing folders are defined as specified.", actionPrefKey = "No (ad-hoc/forever) auto-importing folders are defined" }
        end
    end }
end



function OttomanicImporter:_presentManualUi( call )
    local importFiles
    local s, m = app:pcall{ name="Present Manual Import Ui", async=false, main=function( icall )
        local props = LrBinding.makePropertyTable( icall.context )
        call:setCaption( "Manual import will start when dialog box is answered..." )
        
        local driveSet = {}
        local importedDrives = {} -- array of drives w/imported files.
        local locSet = {}
        local tb -- tooltip for card-drive edit-field.
        if WIN_ENV then
            tb = "List drives to import from - include colon, and separate with a space (e.g. 'K: M:', without the apostrophes)"
        else
            tb = "List drives to import from - separate with a semi-colon (e.g. '/Drv1; /Drv2', without the apostrophes)"
        end
        
        local driveSpecs
        local driveNames
        --Debug.pause( driveSpecs )
        
        local function computeDrivesMenu()
            local dItems = {{ title="Drives", value=0 }}
            local drivesKey = systemSettings:getKey( 'drives' ) -- get once, use twice...
            driveSpecs = systemSettings:getValue( drivesKey ) or error( "no drives" )
            driveNames = systemSettings:getArrayNames( drivesKey ) or error( "no drive names" )
            if #driveNames > 0 then
                dItems[#dItems + 1] = { separator=true }
                for i, dn in ipairs( driveNames ) do
                    dItems[#dItems + 1] = { title=dn, value=i }
                end
                --Debug.pause( #dItems )
            else
                app:show{ warning="No card drives have been specified - consider editing additional settings to define drives." }
            end
            props.dItems = dItems
        end
        computeDrivesMenu()
        app:initGlobalPref( "importFrom", "" ) -- card drives
        app:initGlobalPref( "importFrom_2", "" ) -- other locations
        props.summary = "Select card drive or browse for other location."
        props.driveMenuNum = 0
        
        app:initGlobalPref( 'customSetNameManual', "" ) -- not nil
        local customSetName = app:getGlobalPref( 'customSetNameManual' )
        local customSet = self:getCustomSet( customSetName ) or {} -- or error? croaks if set-name is nil.
        icall.import = Import:new{ importExt=customSet.importExt or { raw={}, rgb={}, video={} } } -- Note: this is just to get the ball rolling - import w/ proper import-ext will be used when the time comes.

        local function getRootSum( root, card, stats )
            local temp = {}
            if stats:getStat( 'raw' ) > 0 then
                temp[#temp + 1] = str:nItems( stats:getStat( 'raw' ), "raw photos" )
            end
            if stats:getStat( 'rgb' ) > 0 then
                temp[#temp + 1] = str:nItems( stats:getStat( 'rgb' ), "rgb photos" )
            end
            if stats:getStat( 'video' ) > 0 then
                temp[#temp + 1] = str:nItems( stats:getStat( 'video' ), "videos" )
            end
            if #temp > 0 then
                if card then
                    return str:fmtx( "^1 ^2", root, table.concat( temp, ", " ) )
                else
                    return str:fmtx( "'^1': ^2", root, table.concat( temp, ", " ) )
                end
            else
                return "0 importable files"
            end
        end
        
        local function computeSummary()
        
            -- this is normally not necessary, except if prefs have just been reset...:
            local customSetName = app:getGlobalPref( 'customSetNameManual' )
            local importCustomSet = self:getCustomSet( customSetName )
            if importCustomSet then
                icall.import:initImportExt( importCustomSet.importExt ) -- this will recompute import-ext sets.
            end
            
            sampleFile = nil
            sampleFiles = {}
            importFiles = {}
            local sum = {} -- root summaries
            local totals = Call:newStats{ 'raw', 'rgb', 'video' } -- cumulative summaries
            local yc = 0
            for root, driveSpec in pairs( driveSet ) do
                local subfolder
                if not str:is( driveSpec.subfolder ) then
                    Debug.papuse( "no subf" )
                    subfolder = "DCIM"
                else
                    subfolder = driveSpec.subfolder
                end
                local stats = Call:newStats { 'raw', 'rgb', 'video' }
                local filesToImport = {}
                local card = false
                if fso:existsAsDir( root ) then
                    for file in LrFileUtils.recursiveFiles( root ) do
                        yc = app:yield( yc )
                        if file:find( subfolder ) then -- hardcoded. If not correct, use other locations.
                            card = true
                            local ext = LrPathUtils.extension( file )
                            local supportAs = icall.import:getSupportType( ext )
                            if supportAs then
                                -- ###3 I could store all files for sampling, but dunno if I want to: the whole idea is really to see sample import path, not to preview files to be imported.
                                -- If the later is desired, then it seems to make more sense to go all out thumb-wise, more like Lr's import dialog box.
                                sampleFiles[supportAs] = sampleFiles[supportAs] or file
                                stats:incrStat( supportAs ) -- ###3 could be saved in files-to-import and avoid re-computing later. oh well, for now...
                                filesToImport[#filesToImport + 1] = file -- note: if I divided these up, like sample-files, by type, I could do raws first and handle jpeg sidecars better. ###3
                            else
                                app:logv( "Not on list of importable extensions: ^1", file )
                            end
                        else
                            -- ?
                        end
                    end
                    if card then
                        sum[#sum + 1] = getRootSum( root, true, stats )
                    else
                        sum[#sum + 1] = str:fmtx( "^1 ^2 (no files in DCIM card folder - consider \"Other Locations\" instead)", root, str:nItems( #filesToImport, "files" ) )
                    end
                else
                    sum[#sum + 1] = str:fmtx( "^1 (not mounted)", root )
                end
                if #filesToImport > 0 then
                    sampleFile = filesToImport[1]
                    importFiles[#importFiles + 1] = { root=root, card=true, filesToImport=filesToImport }
                    --total = total + #filesToImport
                    totals:incrStat( 'raw', stats:getStat( 'raw' ) )
                    totals:incrStat( 'rgb', stats:getStat( 'rgb' ) )
                    totals:incrStat( 'video', stats:getStat( 'video' ) )
                end
            end
            for path, v in pairs( locSet ) do
                local stats = Call:newStats { 'raw', 'rgb', 'video' }
                local filesToImport = {}
                for file in LrFileUtils.recursiveFiles( path ) do
                    yc = app:yield( yc )
                    local ext = LrPathUtils.extension( file )
                    local supportAs = icall.import:getSupportType( ext )
                    if supportAs then
                        sampleFiles[supportAs] = sampleFiles[supportAs] or file
                        stats:incrStat( supportAs ) -- ###3 could be saved in files-to-import and avoid re-computing later. oh well, for now...
                        filesToImport[#filesToImport + 1] = file
                    else
                        app:logv( "Not on list of importable extensions: ^1", file )
                    end
                end
                sum[#sum + 1] = getRootSum( path, false, stats )
                if #filesToImport > 0 then
                    if sampleFile == nil then
                        sampleFile = filesToImport[1]
                    end
                    importFiles[#importFiles + 1] = { root=path, card=false, filesToImport=filesToImport }
                    totals:incrStat( 'raw', stats:getStat( 'raw' ) )
                    totals:incrStat( 'rgb', stats:getStat( 'rgb' ) )
                    totals:incrStat( 'video', stats:getStat( 'video' ) )
                end
            end
            if #sum > 0 then
                local nTotal = totals:getStat( 'raw' ) + totals:getStat( 'rgb' ) + totals:getStat( 'video' )
                local total = getRootSum( str:fmtx( "^1 total:", nTotal ), true, totals ) -- "cheating" a smidge.
                props.summary = str:fmtx( "^1\n \n^2", table.concat( sum, "\n" ), total )
            else
                props.summary = "Select card drive or browse for other location."
            end
        end
        local function add( driveSpec )
            if driveSet[driveSpec.root] then
                return true -- dup
            end
            driveSet[driveSpec.root] = driveSpec
            local importFrom = LrStringUtils.trimWhitespace( app:getGlobalPref( 'importFrom' ) ) -- card drives
            if str:is( importFrom ) then
                if WIN_ENV then
                    importFrom = importFrom .. " " .. driveSpec.root
                else
                    importFrom = importFrom .. "; " .. driveSpec.root
                end
            else
                importFrom = driveSpec.root
            end
            app:setGlobalPref( 'importFrom', importFrom )
        end
        local function add_2( path )
            if locSet[path] then
                app:show{ warning="Duplicate location" }
                return
            end
            locSet[path] = true
            local importFrom_2 = app:getGlobalPref( 'importFrom_2' ) -- other locations
            if str:is( importFrom_2 ) then
                importFrom_2 = importFrom_2 .. "\n" .. path
            else
                importFrom_2 = path
            end
            app:setGlobalPref( 'importFrom_2', importFrom_2 )
        end
        local function computeDrives()
            props.driveMenuNum = 0
            driveSet = {}
            local _importFrom = app:getGlobalPref( 'importFrom' )
            local importFrom = LrStringUtils.trimWhitespace( _importFrom or "" )
            local drives
            if WIN_ENV then
                drives = str:split( importFrom, " " )
            else
                drives = str:split( importFrom, ";" )
            end
            app:setGlobalPref( 'importFrom', "" )
            if #drives == 0 then -- can happen if prefs cleared(?)
                return
            end
            local dup
            for i, v in ipairs( drives ) do
                local subfolder
                for j, v2 in ipairs( driveSpecs ) do
                    if v2.root == v then
                        subfolder = v2.subfolder
                        break
                    end
                end
                if subfolder then
                    if subfolder ~= "DCIM" then
                        app:logv( "Non-standard subfolder: ^1", subfolder )
                    end
                    add{ root=v, subfolder=subfolder }
                elseif #v < 2 then -- usually '/' on Mac, or 'C' on Windows...
                    app:show{ warning="'^1' is not a legal card drive - please amend, e.g. by editing \"additional settings\" - 'Card Drives'." }
                else
                    -- unconventional pseudo-warning:
                    app:log( "*** WARNING: Card drive is not in the configuration (^1), or has no subfolder specified - defaulting to 'DCIM'. To eliminate this warning, edit additional settings - 'Card Drives'.", v  )                    
                    add{ root=v, subfolder="DCIM" }
                end
            end
        end
        local function computeLocations()
            locSet = {}
            local importFrom_2 = app:getGlobalPref( 'importFrom_2' )
            local paths = str:split( importFrom_2, "\n" )
            app:setGlobalPref( 'importFrom_2', "" )
            if paths == nil then -- happens when clearing all prefs.
                return
            end
            for i, v in ipairs( paths ) do
                add_2( v )
            end
        end
        local function chgHdlr( id, props, key, value )
            app:pcall{ name="Ottomanic Importer - Manual Change Handler", async=true, guard=App.guardSilent, main=function( icall )
                local _name = app:getGlobalPrefName( key )
                if _name == 'importFrom' then
                    computeDrives()
                    computeSummary()
                    --Debug.pause()
                elseif _name == 'importFrom_2' then
                    computeLocations()
                    computeSummary()
                    --Debug.pause()
                else
                    if key == 'driveMenuNum' then
                        if value ~= nil then
                            if value > 0 then
                                local dup = add( driveSpecs[value] )
                                if dup then
                                    -- either true dup or fake dup, in any case, just need to make sure import-from field reflects the true drives selected.
                                    computeDrives() -- seems impossible to tell a true dup, since Lr has not commited the importFrom field when popup is clicked.
                                else
                                    computeSummary() -- recomputing for all drives is not efficient.
                                end
                            else
                                app:show{ warning="Select one of the drives below." }
                            end
                        end
                    else
                        Debug.pause( "?" )
                    end
                end
            end }
        end
        computeDrives()
        computeLocations()
        computeSummary()
        view:setObserver( props, 'driveMenuNum', OttomanicImporter, chgHdlr )
        view:setObserver( prefs, app:getGlobalPrefKey( 'importFrom' ), OttomanicImporter, chgHdlr )
        view:setObserver( prefs, app:getGlobalPrefKey( 'importFrom_2' ), OttomanicImporter, chgHdlr )
        
        icall.callback = computeDrivesMenu
        local viewItems = self:_initCommonViewItems( props, icall.import, false, icall ) -- manual, not auto.
        
        viewItems[#viewItems + 1] = vf:spacer{ height=15 }
        viewItems[#viewItems + 1] = 
            vf:row {
                vf:static_text {
                    title = "Card Drives",
                    width = share 'label_width',
                },
                vf:edit_field {
                    bind_to_object = prefs,
                    value = app:getGlobalPrefBinding( 'importFrom' ),
                    width_in_chars = 40,
                    tooltip = tb,
                },
                vf:popup_menu {
                    bind_to_object = props,
                    value = bind 'driveMenuNum',
                    tooltip = "Select card drives to peruse for files to import - you can have extras, just make sure you aren't short ;-}",
                    items = bind 'dItems',
                },
                vf:push_button {
                    title = "Browse",
                    action = function( button )
                        app:pcall{ name="Browse for Card Drive", async=true, main=function( icall )
                            local path = dia:selectFolder {
                                title = "Select card drive, or import folder",
                                initialDirectory = "/",
                            }
                            if path ~= nil then
                                local comp = str:breakdownPath( path )
                                local drive = comp[1]
                                if str:is( drive ) then
                                    add{ root=drive, path=table.concat( comp, "\\" ) }
                                else
                                    app:show{ warning="No root (drive) found in '^1'", path }
                                end
                            end
                        end }
                    end,
                },
            }
        
        viewItems[#viewItems + 1] = 
            vf:row {
                vf:static_text {
                    title = "Other Locations",
                    width = share 'label_width',
                },
                vf:edit_field {
                    bind_to_object = prefs,
                    value = app:getGlobalPrefBinding( 'importFrom_2' ),
                    tooltip = "Paths to other locations potentially containing files to import. - add paths directly to this box (one per line) or using 'Browse' button, delete paths directly from this box.",
                    width_in_chars = 50,
                    height_in_lines = 3,
                },
                vf:push_button {
                    title = "Browse",
                    action = function( button )
                        app:pcall{ name="Browse for Location", async=true, main=function( icall )
                            local path = dia:selectFolder {
                                title = "Select location with files to import",
                                initialDirectory = "/",
                            }
                            if path ~= nil then
                                local comp = str:breakdownPath( path )
                                local drive = comp[1]
                                if str:is( drive ) then
                                    add_2( path )
                                else
                                    app:show{ warning="No root (drive) found in '^1'", path }
                                end
                            end
                        end }
                    end,
                },
            }
            
        viewItems[#viewItems + 1] = vf:spacer{ height=15 }
        viewItems[#viewItems + 1] = 
            vf:row {
                vf:static_text {
                    title = "Summary",
                    width = share 'label_width',
                },
                vf:static_text {
                    bind_to_object = props,
                    title = bind 'summary',
                    width_in_chars = 60,
                    height_in_lines = app:getPref( 'summaryLines' ) or 10,
                },
            }
            
        local accItems = {}
        accItems[#accItems + 1] = 
            vf:row {
                vf:push_button {
                    title = "Refresh",
                    action = function( button )
                        app:service{ name="Refresh", async=true, guard=App.guardSilent, main=function( _icall )
                        
                            _icall.prevCap = call:setCaption( "Refresh dialog box is awaiting your response..." )
                            local button = app:show{ confirm="Refresh keyword cache too?\n \nAnswer 'Yes' only if keywords have been added to *both* Lightroom and custom import settings.\n \n(you can also just reload the plugin to reinitialize the keyword cache)",
                                buttons = { dia:btn( "Yes", 'ok' ), dia:btn( "No", 'other' ) },
                                actionPrefKey = "Refresh keyword cache",
                            }
                            if button == 'ok' then
                                call:setCaption( "Initializing keyword cache..." )
                                keywords:initCache()
                                call:setCaption( "Refreshing other stuff..." )
                            elseif button == 'other' then
                                app:log( "Not re-initializing the keyword cache." )
                                call:setCaption( "Refreshing" )
                            elseif button == 'cancel' then
                                _icall:cancel()
                                return
                            end
                            
      	                    local file, name = app.prefMgr:getPrefSupportFile()
   	                        if str:is( file ) then
                                assert( name == LrPathUtils.leafName( file ), "Preset file naming anomaly" )
                                local presetName = app.prefMgr:getPresetName()
          	                    if fso:existsAsFile( file ) then
                                    app.prefMgr:loadPrefFile( file, presetName ) -- load props used to do this (throws error if probs). re-reads backing file.
                                    app:logv( "Reloaded advanced settings for ^1 preset, by re-reading preset backing file: ^2", presetName, file )
              	                else
              	                    app:show{ error="Unable to reload advanced settings for ^1, preset backing file not found:\n^2", presetName, file } -- Its created when the set is created, and each time when switching sets - so simple error here OK.
              	                end
                            end
                            developSettings:clearUserPresetCache() -- forces re-init of dev-cache if warranted when init-ing settings.
                            local customSetName = app:getGlobalPref( 'customSetNameManual' )
                            local importCustomSet = self:getCustomSet( customSetName ) or error( "no import settings are defined" )
                            icall.import:initImportExt( importCustomSet.importExt ) -- this will recompute import-ext sets.
                            local customText_1 = app:getGlobalPref( 'customText_1' ) or error( "no ctxt1" )
                            local customText_2 = app:getGlobalPref( 'customText_2' ) or error( "no ctxt2" )
                            local card = str:is( LrStringUtils.trimWhitespace( app:getGlobalPref( 'importFrom' ) ) )
                            local auto = false
                            
                            local settings = icall.import:initSettings( importCustomSet, customText_1, customText_2 ) -- force re-read of dev-settings cache and double-check settings...
                            
                            computeSummary() -- depends on import-ext sets.
          	                
                        end, finale=function( _icall )
                            call:setCaption( _icall.prevCap )
                        end }
                    end,
                },
                vf:push_button {
                    title = "Log File",
                    action = function( button )
                        app:pcall{ name="Show Log File", async=true, guard=App.guardSilent, main=function( _icall )
                            local customSetName = app:getGlobalPref( 'customSetNameManual' )
                            local importCustomSet = self:getCustomSet( customSetName ) or error( "no set" )
                            local customText_1 = app:getGlobalPref( 'customText_1' ) or error( "no ctxt1" )
                            local customText_2 = app:getGlobalPref( 'customText_2' ) or error( "no ctxt2" )
                            local card = str:is( LrStringUtils.trimWhitespace( app:getGlobalPref( 'importFrom' ) ) )
                            local auto = false
                            local settings = icall.import:initSettings( importCustomSet, customText_1, customText_2 )
                            app:showLogFile()
                        end }
                    end,
                },
                vf:push_button {
                    title = "Help",
                    action = function( button )
                        app:pcall{ name="Manual Import Help", async=true, guard=App.guardSilent, main=function( icall )
                            local p = {}
                            p[#p + 1] = str:fmtx( "If card drive is \"not mounted\", make sure card in drive is browsable using ^1, then click 'Refresh'", app:getShellName() )
                            dia:quickTips( p )
                        end }
                    end,
                },
            }
        
        local button
        repeat
            button = app:show{ confirm="Import?",
                subs = {}, -- reserved for future.
                buttons = { dia:btn( "Yes - Import Now", "ok" ) }, --dia:btn( "Refres h", 'other' ) },
                viewItems = viewItems,
                accItems = accItems,
                }
            if button == 'ok' then
                if #importFiles > 0 then
                    break
                else
                    if not str:is( LrStringUtils.trimWhitespace( app:getGlobalPref( 'importFrom' ) ) ) and not str:is( LrStringUtils.trimWhitespace( app:getGlobalPref( 'importFrom_2' ) ) ) then
                        app:show{ warning="Add card drives or other locations to import." }
                    else
                        app:show{ warning="There are no files to import on the selected card drives or other locations." }
                    end
                end
            elseif button == 'cancel' then
                call:cancel()
                return
            else
                error( "pgm fail" )
            end
        until false
    end, finale=function( icall )
        app:log()
        if icall.import then -- in this case import is in the icall, spec to..
            -- Debug.pauseIf( icall.import.ets and icall.import.ets:getName() == "Sample Path" ) -- this happens
            Debug.pauseIf( icall.import.ets and icall.import.ets:getName() == "Manual Import" ) -- this doesn't.
            Debug.pauseIf( icall.spec ~= nil, "got ispec" ) -- not happening
            Debug.pauseIf( not icall.import.ets, "no ets" ) -- not happening
            --icall.import:endSession( icall.spec ) -- this is what last release did which was a no-op because icall.spec is nil.
            exifTool:closeSession( icall.import.ets ) -- this is probably all that needs to be done - working: sample session is getting opened and closes - nice..
        else
            Debug.pause( "no icall import" )
        end
    end }
    if s then
        return importFiles
    else
        return nil, m
    end
end



--  'Manual Import' menu handler.
function OttomanicImporter:manual( title )
    app:service{ name=title, async=true, progress=true, main=function( call )
        local s, m = background:pause( 30 ) -- background init can be lengthy, default tmo is 10.
        if not s then
            app:logErr( "Not paused - ^1", m )
            return
        end
        
        local importFiles
        importFiles, m = self:_presentManualUi( call )
        if call:isQuit() then
            return
        end
        if importFiles and #importFiles > 0 then
            call:setCaption( "Initializing for import..." )
        elseif str:is( m ) then
            app:logError( m )
            return
        else
            app:logWarning( "Nothing to import." )
            return
        end

        local folder = nil
        local recursive = nil
        local customSetName = app:getGlobalPref( 'customSetNameManual' )
        local importCustomSet = self:getCustomSet( customSetName ) or error( "no set" )
        local customText_1 = app:getGlobalPref( 'customText_1' )
        local customText_2 = app:getGlobalPref( 'customText_2' )
        local auto = false
        local readMetadata = false -- manual import implies not metadata reading, since it can't possibly change (no dir-chg registration..).
        local removeDeletedPhotos = false -- manual import implies not removing anything..
        
        local spec, qual = self:_createSpec( call, folder, recursive, importCustomSet, customText_1 or "", customText_2 or "", manualImportColl, nil, auto, readMetadata, removeDeletedPhotos ) -- card comes later, manual - not auto.
        if spec then
            call.spec = spec
        else
            app:logWarning( qual )
            return
        end
        -- new import session.
        --Debug.logn( "spec", "qual" )
        --Debug.lognpp( spec, qual )
        --Debug.showLogFile()
        assert( spec.import, "no spec import" )
        assert( spec.import.record, "no spec import record" )
        
        app:log()
        app:log()
        app:log( "Importing..." )
        app:log()

        call:setCaption( "Importing..." )
        local importDriveSet = {}
        for i, imp in ipairs( importFiles ) do
            local src = imp.root
            local files = imp.filesToImport
            local card = imp.card
            if card then
                app:log( "Importing from card: ^1", src )
            else
                app:log( "Importing from other location: ^1", src )
            end
            spec.card = card
            spec.import:initSource( spec )
            for i, file in ipairs( files ) do
                --app:log( file )
                local s, m = spec.import:fileAsSpecified( file, spec )
                if s then
                    if m then
                        if type( m ) == 'boolean' then
                            if m then -- imported
                                if imp.card then
                                    importDriveSet[src] = true
                                -- else not a card...
                                end
                            else
                                Debug.pause( "no error, but not imported either." ) -- I don't think this happens.
                            end
                        elseif type( m ) == 'string' then
                            app:logv( m )
                        else
                            error( "bad return type" )
                        end
                    else 
                        --Debug.pause( "status ok, and no message" ) -- I think this happens when file is not appropriate to be added...
                    end
                else
                    app:logErr( "file not imported successfully - ^1", m or "no reason given - please report problem." ) -- should already be appropriate logs & stats.
                end
            end
            spec.import:endSource( spec )
            app:log()
        end
        app:log()
   
        if spec.import.stats:getStat( "imported" ) > 0 then
            catalog:setActiveSources{ manualImportColl }
        else
            app:logWarning( "Nothing was imported." )
            return
        end

        local prompted = spec.import:considerDeletingSources( call )
        assert( prompted ~= nil, "prompted nil 2" )
        
        local drives = tab:createArrayFromSet( importDriveSet )
        if importCustomSet.ejectCards then
            if #drives > 0 then
                call:setCaption( "Ejecting" )
                local ejected, summary = fso:eject( drives )
                if ejected then
                    local actionPrefKey = "Cards ejected - ok to remove"
                    local answer = dia:getAnswer( actionPrefKey )
                    if answer ~= 'ok' then
                        app:show{ info=summary,
                            actionPrefKey = actionPrefKey,
                        }
                        prompted = true
                    elseif answer ~= nil then
                        Debug.pause( answer )
                    end
                elseif summary then -- error
                    app:logErr( summary ) -- errm.
                -- else nuthin: ejector has already logged warnings
                end
            else
                app:log( "No cards to eject." )    
            end
        else
            app:log( "Not ejecting." )    
        end
        
        call:setCaption( "Grand finale..." ) -- never visible if no finale.
        assert( prompted ~= nil, "prompted nil 3" )
        spec.import:considerGrandFinale( call, prompted )
        call:setCaption( "" )

    end, finale=function( call )
        background:continue()
        app:log()
        if call.spec then
            local import = call.spec.import
            --Debug.pauseIf( call.spec.import.ets and ( call.spec.import.ets:getName() == 'Sample Path' ) ) -- not happening
	        --Debug.pauseIf( call.spec.import.ets and ( call.spec.import.ets:getName() == 'Manual Import' ) ) -- happening
	        if import then
                import:endSession( call.spec ) -- session needs to be properly ended - not just exif-tool session closed.
                assert( import.stats, "no stats in import object" )
                app:log()
                app:log()
                app:log( "Imported: ^1", import.stats:getStat( "imported" ) )
                app:log( "Already in catalog: ^1", import.stats:getStat( "alreadyInCatalog" ) )
            else
                Debug.pause( "?" )
                app:logE( "No import in call spec" )
            end
        else
            app:log( "Premature termination" )
        end
    end }
end


-- self-wrapped, synchronous.
-- returns legacy-compatible table of import settings, or nil and error message.
-- only throws fatal errors.
function OttomanicImporter:getImportSettings()
    local importSettings
    local s, m = app:pcall{ name="Get Import Settings", async=false, main=function( call )
        
        local setKey = systemSettings:getKey( 'importCustomSets' )
        --Debug.pause( "names", prefs[setKey .. "_names"] )
        local whole = systemSettings:getValue( setKey, prefs, { whole=true } ) -- @5/Jan/2013 20:42 no longer throws error.
        if whole ~= nil then
            --Debug.lognpp( "whole", whole )
            importSettings = systemSettings:getValue( setKey ) -- prefs, no options.
            if importSettings == nil then
                error( "can't get current import settings" )
            end
        else
            error( "can't get all import settings" )
        end        
    end }
    if s then
        assert( importSettings ~= nil, "pgm fail" )
        return importSettings
    else
        return nil, m
    end
end



-- note: due to limitations of run-open-panel, it is not possible to select folders and files both, in same chooser box.
function OttomanicImporter:importFoldersOrFiles( title )
    app:service{ name=title, async=true, progress=true, guard=App.guardVocal, main=function( call )   
    
        local s, m = background:pause( 30 ) -- ditto.
        if not s then
            app:error( m )
        end

        local importCustomSet = {
            customSetName = title,
            importExt = {
                raw = {
                    "3fr",
                    "ari", "arw",
                    "bay",
                    "crw", "cr2", "cap",
                    "dcs", "dcr", "dng", "drf",
                    "eip", "erf",
                    "fff",
                    "iiq",
                    "k25", "kdc",
                    "mef", "mos", "mrw",
                    "nef", "nrw",
                    "obm", "orf",
                    "pef", "ptx", "pxn",
                    "r3d", "raf", "raw", "rwl", "rw2", "rwz",
                    "sr2", "srf", "srw",
                    "x3f",
                    -- ditto, upper case
                    "3FR",
                    "ARI", "ARW", "A7R", -- a7r new @Lr5.3
                    "BAY",
                    "CRW", "CR2", "CAP",
                    "DCS", "DCR", "DNG", "DRF",
                    "EIP", "ERF",
                    "FFF",
                    "IIQ",
                    "K25", "KDC",
                    "MEF", "MOS", "MRW",
                    "NEF", "NRW",
                    "OBM", "ORF",
                    "PEF", "PTX", "PXN",
                    "R3D", "RAF", "RAW", "RWL", "RW2", "RWZ",
                    "SR2", "SRF", "SRW",
                    "X3F",
                },
                rgb = { -- complete, I think.
                -- non-raw still-image files, both cases:
                    "TIF", "tif", "TIFF", "tiff",
                    "JPG", "jpg", "JPEG", "jpeg",
                    "PSD", "psd", 
                },
                video = {
                    -- video, from http://helpx.adobe.com/lightroom/kb/video-support-lightroom-4-3.html
                    "MOV",
                    "M4V",
                    "MP4",
                    "MPE",
                    "MPEG",
                    "MPG4",
                    "MPG",
                    "AVI",
                    "MTS",
                    "3GP",
                    "3GPP",
                    "M2T",
                    "M2TS",
                    -- lower
                    "mov",
                    "m4v",
                    "mp4",
                    "mpe",
                    "mpeg",
                    "mpg4",
                    "mpg",
                    "avi",
                    "mts",
                    "3gp",
                    "3gpp",
                    "m2t",
                    "m2ts",
                },
            },
            importType = 'Add', -- this line added 15/Apr/2013 16:27 (not sure how it ever just added, but in Lr5-beta sans mod, was copying without this line).
        }
        if app:lrVersion() >= 5 then
            local a = importCustomSet.importExt.rgb
            a[#a + 1] = 'png'
            a[#a + 1] = 'PNG'
        end
        local fileTypes = {}
        -- Note: this seems to have no value, but also seems to be correct, according to documentation, and so it remains as reminder -
        tab:appendArrays( fileTypes, importCustomSet.importExt.raw, importCustomSet.importExt.rgb, importCustomSet.importExt.video )
        --Debug.lognpp( fileTypes )
        app:initPref( 'reportOnly', false )
        app:initPref( 'selectInLr', false )
        app:initPref( 'subfoldersToo', true ) -- recursive.
        local accItems = {}
        accItems[#accItems + 1] = vf:row {
            --[[ *** save as reminder - not working: display only comes up *after* dismissing open-files-and-folders dialog box (even if floating), at which point - it's too late..
            vf:push_button {
                title="Define Extensions",
                action=function( button )
                    defineExts( button.title )
                end,
            },
            --]]
            vf:checkbox {
                title = "Subfolders too",
                value = app:getPrefBinding( 'subfoldersToo' ),
                tooltip = "aka \"recursive\", meaning: consider files within subfolders of folder selected, instead of only considering files in folder selected.",
            },
            vf:checkbox {
                title = "Report (dont import)",
                value = app:getPrefBinding( 'reportOnly' ),
                tooltip = "Do not import anything, just report about what is importable, and what isn't, and why...",
            },
            vf:checkbox {
                title = "Select if already imported",
                bind_to_object = prefs,
                value = app:getPrefBinding( 'selectInLr' ),
                enabled = app:getPrefBinding( 'reportOnly' ),
                tooltip = "Select in Lr all \"subject\" files (e.g. those in selected folder(s)) which are already in catalog.",
            },
        }
        accItems[#accItems + 1] = vf:spacer { height = 5 }
        if WIN_ENV then -- why not Mac? ###2 (I think I got this from John Ellis - do test on Mac.
            accItems[#accItems + 1] = vf:static_text { title = "Click 'Choose Selected' to import selected folders." }
                -- seems acc-view screen real-estate is limited: anything after this is not displayed.
        end
        
        call:setCaption( "Dialog box needs your attention..." )
        local selPaths = LrDialogs.runOpenPanel {
            title = "Select folders or files to \"add to catalog\" (i.e. import).",
            prompt = "Import Files",
            canChooseFiles = true, -- note: accessory view would not be presented if this were false.
            canChooseDirectories = true,
            canCreateDirectories = true, -- why not!?
            allowsMultipleSelection = true,
            fileTypes = fileTypes, -- as of yet, this does no good, or at least not for me - not on Windows.
            accessoryView = vf:view( accItems ),            
            initialDirectory = LrPathUtils.standardizePath( "/" ),
        }
        if selPaths == nil or #selPaths == 0 then
            call:cancel()
            return
        end
    
        local folder = nil
        local recursive = nil
        local customText_1 = ""
        local customText_2 = ""
        local card = false
        local auto = false
    
        local spec, qual = self:_createSpec( call, folder, recursive, importCustomSet, customText_1, customText_2, manualImportColl, card, auto, false, false ) -- not reading metadata, nor removing anything..
        if spec then
            call.spec = spec
        else
            app:logWarning( qual )
            return
        end
        -- new import session.
        
        app:log()
        app:log()
        app:log( "Importing..." )
        app:log()

        local getFilesFunc
        local reportOnly = app:getPref( 'reportOnly' )
        local selectInLr = app:getPref( 'selectInLr' )
        local subfoldersToo = app:getPref( 'subfoldersToo' )
        if reportOnly then
            call:setCaption( "Computing Report in Log File..." )
        else
            call:setCaption( "Importing Folders and/or Files..." )
        end
        if subfoldersToo then
            app:log( "Considering subfolders too (recursively)." )
            getFilesFunc = LrFileUtils.recursiveFiles
        else
            app:log( "Considering top-level folders only (not subfolders...)." )
            getFilesFunc = LrFileUtils.files
        end
        app:log()
        
        local filesToImport = {}
        local import = call.spec.import or error( "no import in call" )
        local alreadyInCatalog = {}

        local function importFile( file )
            import.stats:incrStat( "considered" )
            if not reportOnly then
                app:log()
                app:log( "Considering import: ^1", file )
            end
            local s, m, aic = import:fileAsSpecified( file, spec, reportOnly )
            if s then -- no error
                if m then -- imported (or would be).
                    if reportOnly then
                        app:log( "^1 - would be imported.", file )
                    else
                        app:log( "Imported" )
                    end
                else -- no error, but not imported (maybe because already in catalog).
                    if aic then
                        alreadyInCatalog[#alreadyInCatalog + 1] = aic -- photo (write-only unless "select-in-lr", but cheap..).
                    -- else 'nuff loged already.
                    end
                end
            else
                if reportOnly then
                    app:logWarning( "Wouldn't be imported: '^1' - ^2", file, m or "no reason given" )
                else
                    app:logWarning( "Not imported: ^1", m or "no reason given" )
                end
            end
        end
        for i, path in ipairs( selPaths ) do
            repeat
                app:log()
                app:log( "Considering selected path: ^1", path )
                app:log()
                local status = LrFileUtils.exists( path )
                if status == 'file' then
                    importFile( path )                
                elseif status == 'directory' then
                    local root = str:getRoot( path )
                    if root == path then
                        local button = app:show{ confirm="Are you sure you want to sync the root of the drive (^1)?",
                            subs = root,
                            actionPrefKey = str:fmtx( "Sync Root ^1", root ),
                        }
                        if button ~= 'ok' then
                            break
                        end
                    end
                    for file in getFilesFunc( path ) do
                        importFile( file ) -- bumps stats.
                    end
                else
                    app:log( "bad folder" )
                end
            until true
        end
        app:log()

        if reportOnly then
            -- just present log
            if selectInLr then
                if #alreadyInCatalog > 0 then
                    local s, m = cat:selectPhotos( nil, alreadyInCatalog, true, nil ) -- auto-most-sel, assure-folders if need be, no cache.
                    if s then
                        app:log( "^1 already in catalog, selected.", str:nItems( #alreadyInCatalog, "photos" ) )
                    else
                        app:logW( m )
                    end
                else
                    app:log( "None of the subject photos were already in the catalog, so photo selection not changed." )
                end
            -- else ignore array of those already in catalog.
            end
        else
            if import.stats:getStat( "imported" ) > 0 then
                local button = app:show{ confirm="^1 imported and put in a fresh collection - go there now?", import.stats:getStat( "imported" ),
                    buttons = { dia:btn( "Yes", 'ok' ), dia:btn( "No", 'other' ), dia:btn( "Cancel", 'cancel' ) },
                    actionPrefKey = 'imported folders and files - goto collection',
                }
                if button == 'ok' then
                    catalog:setActiveSources{ manualImportColl }
                elseif button == 'cancel' then
                    call:cancel()
                end
            else
                app:show{ warning="Nothing was imported - presumably because there were no files met import requirements, most notably: filename extension, and not already in catalog.\n \nMay be worth having a peek at the log file if this doesn't make sense..." }
            end
        end
        
    end, finale=function( call )
        background:continue()
        app:log()
        if call.spec then
            local stats = call.spec.import.stats
            app:log()
            app:log()
            app:log( "Total files considered: ^1", stats:getStat( "considered" ) )
            if app:getPref( 'reportOnly' ) then
                app:log( "Not already in catalog: ^1", stats:getStat( "imported" ) )
                app:log( "Excluded based on type: ^1", stats:getStat( "excluded" ) )
            else
                app:log( "Imported: ^1", stats:getStat( "imported" ) )
                app:log( "Excluded: ^1", stats:getStat( "excluded" ) )
            end
            app:log( "Already in catalog: ^1", stats:getStat( "alreadyInCatalog" ) )
        else
            app:log( "Premature termination" )
        end
    end }
end



function OttomanicImporter:_selectExts( namePfx, items )
    local name = namePfx.."Exts"
    local values = app:getPref( name ) or {}
    local clr = #values == #items
    --Debug.pause( name, clr )
    if clr then
        app:setPref( name, {} )
    else
        local newVals = {}
        for i, v in ipairs( items ) do
            newVals[i] = v.value
        end
        app:setPref( name, newVals )
    end
end



function OttomanicImporter:_hideUnhideReport( doHide, ttl )
    Debug.pause( doHide, ttl )
    local doUnhide
    app:service{ name=ttl, async=true, guard=App.guardVocal, main=function( call )
        call:initStats{ 'totalFiles', 'matchToHide', 'matchToUnhide', 'hidden', 'unhidden' } -- 'notMatch'
        doUnhide = doHide == false
        local tidbit_1 -- hide/report.
        local tidbit_2 -- unhide/report.
        if doHide then
            tidbit_1 = "To hide"
        elseif doUnhide then
            tidbit_2 = "To un-hide"
        else -- report
            tidbit_1 = "Importable/hidable"
            tidbit_2 = "Hidden/unhidable"
        end
        local dir = app:getPref( 'hideExtsInDir' )
        if str:is( dir ) then
            if fso:existsAsDir( dir ) then
                app:log()
                app:log( dir )
                app:log()
            else
                app:show{ warning="'^1' does not exist.", dir }
                call:cancel''
                return
            end
        else
            app:show{ warning="'Folder Location' is blank (it must be set to path of existing directory)." }
            call:cancel''
            return
        end
        local recursive = app:getPref( 'hideRecurse' )
        assert( recursive ~= nil, "nil" )
        local fileIter
        if recursive then
            fileIter = LrFileUtils.recursiveFiles
        else
            fileIter = LrFileUtils.files
        end
        local extArr = tab:appendArrays( {}, app:getPref( 'rawExts' ) or {}, app:getPref( 'vidExts' ) or {}, app:getPref( 'rgbExts' ) or {} )
        if #extArr == 0 then
            app:show{ warning="Select extension(s) first." }
            call:cancel''
            return
        end
        app:log()
        app:log( "Selected extensions: ^1", table.concat( extArr, ", " ) )
        app:log()
        local extSet = tab:createSet( extArr )
        local hide = {}
        local unhide = {}
        local hExt = "_hidden_by_omi_"
        if doHide or not doUnhide then -- hide or report
            for file in fileIter( dir ) do
                call:incrStat( 'totalFiles' )
                local ucExt = LrStringUtils.upper( LrPathUtils.extension( file ) or "" )
                if extSet[ucExt] then
                    app:log( "^1 (^2): ^3", tidbit_1, ucExt, file )
                    hide[#hide + 1] = file
                    call:incrStat( 'matchToHide' )
                else
                    --app:logV( "No-match (^1): ^2", ucExt, file )
                    --call:incrStat( 'notMatch' )
                end
            end
        end
        if doUnhide or not doHide then -- unhide or report
            for file in fileIter( dir ) do
                call:incrStat( 'totalFiles' )
                local ext = LrPathUtils.extension( file ) or ""
                if ext == hExt then
                    local ucExt = LrStringUtils.upper( LrPathUtils.extension( LrPathUtils.removeExtension( file ) ) or "" )
                    if extSet[ucExt] then
                        app:log( "^1 (^2): ^3", tidbit_2, ucExt, file )
                        unhide[#unhide + 1] = file
                        call:incrStat( 'matchToUnhide' )
                    else
                        --app:logV( "No-match (^1): ^2", ucExt, file )
                        --call:incrStat( 'notMatch' )
                    end
                else
                    --Debug.pause( file, ext, hExt )
                end
            end
        end
        if doHide then
            if #hide > 0 then
                repeat
                    local btn = app:show{ confirm="Hide? (as shown in log file)",
                        buttons={ dia:btn( "Yes", 'ok' ), dia:btn( "Show Log File", 'other' ) },
                    }
                    if btn == 'ok' then
                        break
                    elseif btn == 'other' then
                        app:log( "User opted to peruse the log file.." )
                        app:showLogFile()
                    else
                        call:cancel()
                        return
                    end                                
                until false
                app:log()
                app:log( "Hiding..." )
                app:log()
                for i, srcFile in ipairs( hide ) do
                    local destFile = LrPathUtils.addExtension( srcFile, hExt )
                    --Debug.pause( srcFile, destFile, hExt )
                    local s, m = fso:moveFile( srcFile, destFile ) -- false, false
                    if s then
                        app:log( "Hidden: '^1' (renamed to '^2')", srcFile, LrPathUtils.leafName( destFile ) )
                        call:incrStat( 'hidden' )
                    else
                        app:logE( m )                                    
                    end
                end
                -- app:log()
            else
                app:log( "Nuthin' to hide.." )
            end
        elseif doUnhide then
            if #unhide > 0 then
                repeat
                    local btn = app:show{ confirm="Unhide? (as shown in log file)",
                        buttons={ dia:btn( "Yes", 'ok' ), dia:btn( "Show Log File", 'other' ) },
                    }
                    if btn == 'ok' then
                        break
                    elseif btn == 'other' then
                        app:showLogFile()
                    else
                        call:cancel()
                        return
                    end                                
                until false
                app:log()
                app:log( "Unhiding..." )
                app:log()
                for i, srcFile in ipairs( unhide ) do
                    local destFile = LrPathUtils.removeExtension( srcFile )
                    --Debug.pause( srcFile, destFile )
                    local s, m = fso:moveFile( srcFile, destFile ) -- false, false
                    if s then
                        app:log( "Unhidden: '^1' (renamed from '^2')", destFile, LrPathUtils.leafName( srcFile ) )
                        call:incrStat( 'unhidden' )
                    else
                        app:logE( m )                                    
                    end
                end
            else
                app:log( "Nuthin' to unhide.." )
            end
        else
            app:log( "End of report." )
        end
    end, finale=function( call )
        app:log()
        if doHide then
            app:log( "Total files: ^1", call:getStat( 'totalFiles' ) )
            app:log( "Files with selected extensions:" )
            app:log( "Hidable: ^1", call:getStat( 'matchToHide' ) )
            app:log( "Hidden: ^1", call:getStat( 'hidden' ) )
            --app:log( "No Match: ^1", call:getStat( 'notMatch' ) )
        elseif doUnhide then
            app:log( "Total files: ^1", call:getStat( 'totalFiles' ) )
            app:log( "Files with selected extensions:" )
            app:log( "Unhidable: ^1", call:getStat( 'matchToUnhide' ) )
            app:log( "Unhidden: ^1", call:getStat( 'unhidden' ) )
            --app:log( "No Match: ^1", call:getStat( 'notMatch' ) )
        elseif not call:isQuit() then
            app:log( "Total files: ^1", call:getStat( 'totalFiles' ) / 2 )
            app:log( "Files with selected extensions:" )
            app:log( "Importable/Hidable: ^1", call:getStat( 'matchToHide' ) )
            app:log( "Hidden/Unhidable: ^1", call:getStat( 'matchToUnhide' ) )
            -- app:log( "No Match: ^1", call:getStat( 'notMatch' ) ) - not sure, since this gets bumped for not-hidable, and not-unhidable: there is overlap..
        end
    end }    
end



function OttomanicImporter:hideAndImport( title )
    local doHide
    local doUnhide
    app:pcall{ name=title, async=true, guard=App.guardVocal, main=function( call )
        app:assert( app:lrVersion() >= 4, "Sorry - this feature requires Lr5 (preferrably), or Lr4." )
        local extSupport = cat:getExtSupport() -- all
        local raw = {}
        local rgb = {}
        local vid = {}
        for k, v in tab:sortedPairs( extSupport ) do
            if v == 'raw' then
                raw[#raw + 1] = { title=k, value=k }
            elseif v == 'rgb' then
                rgb[#rgb + 1] = { title=k, value=k }
            elseif v == 'video' then
                vid[#vid + 1] = { title=k, value=k }
            else
                error( "bad" )
            end
        end
        local vi = {}
        vi[#vi + 1] = vf:row {
            vf:static_text {
                title="Folder Location",
                width = share 'lbl_wid',
            },
            vf:edit_field {
                bind_to_object=prefs,
                value = app:getPrefBinding( 'hideExtsInDir' ),
                width_in_chars = 40,
                tooltip = "Path to folder in which files will be hidden, un-hidden, or reported about...",
            },
            vf:push_button {
                title="Browse",
                action=function( button )
                    dia:selectFolder( {
                        title="Choose folder (subfolders too, implied)",
                    }, prefs, app:getPrefKey( 'hideExtsInDir' ) )
                end,
                tooltip = "Choose 'Folder Location' using OS folder browser.",
            },
        }
        vi[#vi + 1] = vf:spacer{ height=5 }
        app:initPref( 'hideRecurse', true )
        vi[#vi + 1] = vf:row {
            vf:checkbox {
                title="Recursive",
                bind_to_object = prefs,
                value = app:getPrefBinding( 'hideRecurse' ),
                width = share 'lbl_wid',
                tooltip = "Check to include folder & subfolders, uncheck for folder only (no subfolders).",
            },
            vf:static_text {
                title="Check 'Recursive' box to search folder location recursively, i.e. subfolders too.",
                tooltip = "If unchecked, subfolders will not be considered when hiding/un-hiding or reporting-about..",
            },
        }
        vi[#vi + 1] = vf:spacer{ height=15 }
        vi[#vi + 1] = vf:row {
            vf:static_text {
                title="Extensions",
                width = share 'lbl_wid',
                tooltip = "\"Target\" extensions. Files of other (unselected) extensions will not be affected by hide/unhide/report functions.",
            },
            vf:spacer { width=5 },                            
            vf:static_text {
                title = "Video",
                text_color = LrColor( 'blue' ),
                tooltip = "Click blue text to select (or deselect) all video extensions.",
                mouse_down = function()
                    self:_selectExts( 'vid', vid )
                end,
            },
            vf:simple_list {
                width = 100,
                height= 200,
                bind_to_object=prefs,
                value = app:getPrefBinding( "vidExts" ),
                items = vid,
                allows_multiple_selection = true, -- without multiple selection, there's no good reason to use a simple-list, is there?
                tooltip = "\"Target\" video extensions. Files of other (unselected) video extensions will not be affected by hide/unhide/report functions.",
            },
            vf:static_text {
                title = "Raw",
                text_color = LrColor( 'blue' ),
                tooltip = "Click blue text to select (or deselect) all raw extensions.",
                mouse_down = function()
                    self:_selectExts( 'raw', raw )
                end,
            },
            vf:simple_list {
                width = 100,
                height= 200,
                bind_to_object=prefs,
                value = app:getPrefBinding( "rawExts" ),
                items = raw,
                allows_multiple_selection = true, -- without multiple selection, there's no good reason to use a simple-list, is there?
                tooltip = "\"Target\" raw file extensions. Files of other (unselected) raw extensions will not be affected by hide/unhide/report functions.",
            },
            vf:spacer { width=5 },                            
            vf:static_text {
                title = "RGB",
                text_color = LrColor( 'blue' ),
                tooltip = "Click blue text to select (or deselect) all RGB extensions.",
                mouse_down = function()
                    self:_selectExts( 'rgb', rgb )
                end,
            },
            vf:simple_list {
                width = 100,
                height= 150, -- the default - redundent.
                bind_to_object=prefs,
                value = app:getPrefBinding( "rgbExts" ),
                items = rgb,
                allows_multiple_selection = true, -- without multiple selection, there's no good reason to use a simple-list, is there?
                tooltip = "\"Target\" RGB image file extensions. Files of other (unselected) rgb extensions will not be affected by hide/unhide/report functions.",
            },
        }
        
        local windowTitle = app:getAppName().." - "..call.name
        local ai = {}
        if app:lrVersion() >= 4 then
            ai[#ai + 1] = vf:spacer { height=20 }
        end
        ai[#ai + 1] = vf:row {
            vf:push_button {
                title = "Report",
                action = function( button )
                    self:_hideUnhideReport( nil, button.title )
                end,
                tooltip = "Report: which files are hidden, which aren't (of specified \"target\" extensions I mean).",
            },
            vf:push_button {
                title = "Unhide",
                action = function( button )
                    self:_hideUnhideReport( false, button.title )
                end,                                                               
                tooltip = "Unhide hidden files, (of specified \"target\" extensions I mean).",
            },
            vf:push_button {
                title = "Hide",
                action = function( button )
                    self:_hideUnhideReport( true, button.title )
                end,                                                               
                tooltip = "Hide files of specified \"target\" extensions (in 'Folder Location', as specified).",
            },
            vf:spacer { fill_horizontal=.5 },
            vf:push_button {
                title = "Open Import Dialog Box",
                tooltip = "Open Lr's (standard/native) import dialog box, with import source set to 'Folder Location'. If already open, does nothing.",
                action = function( button )
                    app:pcall{ name=button.title, async=true, guard=App.guardSilent, main=function( call )
                        local dir = app:getPref( 'hideExtsInDir' )
                        if str:is( dir ) then
                            if fso:existsAsDir( dir ) then
                                catalog:triggerImportUI( dir )
                            else
                                app:show{ warning="'^1' does not exist.", dir }
                            end
                        else
                            app:show{ warning="'Folder Location' is blank." }
                        end
                    end }
                end,                                                               
            },
            vf:push_button {
                title = "I Feel Lucky (Import)",
                -- warning: tooltip does not seem to be working in floating dialog box.
                tooltip = "Import from 'Folder Location' using settings from most recent import.\n \nPS - if you know what those settings are, then it ain't luck ;-}.",
                action = function( button )
                    app:pcall{ name=button.title, async=true, guard=App.guardSilent, main=function( call )
                        local dir = app:getPref( 'hideExtsInDir' )
                        if str:is( dir ) then
                            if fso:existsAsDir( dir ) then
                                catalog:triggerImportFromPathWithPreviousSettings( dir )
                            else
                                app:show{ warning="'^1' does not exist.", dir }
                            end
                        else
                            app:show{ warning="'Folder Location' is blank." }
                        end
                    end }
                end,                                                               
            },
            vf:spacer { fill_horizontal=.5 },
            LrView.conditionalItem( app:lrVersion() >= 4, vf:spacer{ fill_horizontal=1 } ),
            LrView.conditionalItem( app:lrVersion() >= 4, vf:push_button {
                title="Help",
                action=function()
                    local m = {}
                    m[#m + 1] = str:fmtx( "'^1' is a \"floating\" window, which means it will stay open until you close it, but you can work in other Lightroom windows while it's open. However, a floating window seems to disappear when another window is over it.", windowTitle )
                    m[#m + 1] = "So, move (floating) window frame to preferred location (not underneath anything) - that way, it won't get hidden whenever it loses focus (e.g. another Lr window becomes selected)."
                    m[#m + 1] = "When you are done with it, close using 'X' button - that way, when you re-open it, it'll be in the same place."
                    m[#m + 1] = "PS - Remember to unhide files after hiding has served it's purpose, or else they will remain hidden ;-}."
                    dia:quickTips( m )
                end,
            } ),
        }
        if app:getPref( 'modal' ) then -- modal
            local button=app:show{ confirm="Hide/Un-hide (or report about) files with specified extensions in specified folder.",
                --buttons={ dia:btn( "Hide", 'ok' ), dia:btn( "Report", 'other2' ), dia:btn( "Un-hide", 'other' ) },
                buttons={ dia:btn( "Done", 'ok' ) },
                viewItems=vi,
                accItems=ai,
            }
        else -- non-modal should be preferred, if supported.
            -- construct args for floating dialog.
            local args = {}
            args.title = windowTitle
            args.contents = vf:view( tab:appendArray( vi, ai ) ) -- Lr bug prohibits having edit-fields in scrolled-view when it's combined with other items in parental view.
            args.blockTask = true -- wrap in synchronous call.
            args.save_frame = windowTitle
            args.resizable = true
            args.onShow = function( params ) -- @10/Jan/2014 16:21, not used, but strangely comforting to have..
                call.toFront = params.toFront or error( "no to-front" )
                call.close = params.close or error( "no close" )
            end
            args.windowWillClose = nil -- so be it (let it close..).
            args.selectionChangeObserver = nil -- function taking no args: use get-target-photos to get new complement.
            args.sourceChangeObserver = nil
            dia:presentFloatingDialog{ name=args.title, guard=App.guardNot, args=args } -- redundent params passed for emphasis, async call derived from block-task arg.
        end

    end }
end



-- this function was originally invented to be called when 'file' modification detected.
-- but has the smarts to not read-metadata if not necessary/appropriate, so can be used
-- in force-scan loop as well (or multiple events trying to say it was modified..).
-- @12/Jun/2014, is being called for created files too, since could be xmp files.
function OttomanicImporter:autoReadMetadata( file, spec )
    if app:lrVersion() < 5 then app:callingError( "do not call if lr-ver not at least 5" ) end -- shouldn't happen, since options are not presented in Lr4-, still..(cheap ins.).
    local photo
    local photoFile
    local xmpFile
    local ext = LrPathUtils.extension( file )
    local support = spec.import:getSupportType( ext ) -- raw, rgb, or video
    if support then
        if support == 'raw' then -- includes DNG.
            if str:isEqualIgnoringCase( ext, "dng" ) then
                xmpFile = file
                photoFile = file
                photo = cat:findPhotoByPath( file ) -- maybe nil, or not..
            else -- proprietary raw
                photoFile = file
                xmpFile = LrPathUtils.replaceExtension( file, "xmp" )
                photo = cat:findPhotoByPath( photoFile ) -- maybe nil, or not..
            end
        elseif support == 'video' then
            app:logV( "Video file modified: '^1' - currently no action is being taken.", file ) 
        elseif support == 'rgb' then
            xmpFile = file
            photoFile = file
            photo = cat:findPhotoByPath( photoFile ) -- maybe nil, or not..
        else
            error( support )
        end
    elseif str:isEqualIgnoringCase( ext, "xmp" ) then -- xmp sidecar file changed.
        xmpFile = file
        photo, photoFile = self:getPhotoForXmpSidecar( xmpFile, spec )
    else
        -- if changed file is neither importable nor xmp, then ignore
        app:logV( "File modified: '^1' - currently no action is being taken.", file ) 
    end
    if photo then -- got it..
        local editTime = photo:getRawMetadata( 'lastEditTime' )
        local metaTime
        if xmpFile ~= photoFile then
            metaTime = math.max( fso:getFileModificationDate( xmpFile ) or -math.huge, fso:getFileModificationDate( photoFile ) or -math.huge )
        else
            metaTime = fso:getFileModificationDate( photoFile ) or -math.huge
        end
        -- note: the following check allows method to work in force-scan context, but also eliminates a double-save when dir-chg-app reports a double-mod (why it does that I do not know).
        if metaTime > editTime then -- metadata changed since photo was last "edited".
            -- since new read-method is undocumented, it may not work on Mac. ###1
                          -- readPhotoMetadata( photo, photoPath, alreadyInLibraryModule, service, manualSubtitle )
            local s, m = cat:readPhotoMetadata( photo, photoFile, false, self.call, nil ) -- note: this feature would suck if Lr4- or manual modes (Lr5 has *undocumented* read-metadata SDK method).
                -- consider a no-validate mode too. as currently programmed, it will wait up to 5 seconds, for photo to appear edited.
            if s then
                app:log( "Metadata read from '^1' to catalog.", xmpFile )
            else
                app:logW( "Unable to read metadata from '^1' to catalog - ^2.", xmpFile, m )
            end
        else
            app:logV( "Metadata time is earlier than last edit time - metadata not being read." )
        end
    else
        dbgf( "no photo / no metadata read" )
    end
end



function OttomanicImporter:getAutoMirrorInclExcl()
    local defs = systemSettings:getValue( 'autoMirrorFolderDefs' )
    local incl = {}
    local excl = {}
    local _incl = {}
    local _excl = {}
    for i, v in ipairs( defs ) do
        repeat
            local ena = v['folderDefEna']
            if not ena then break end -- ignore disabled defs.
            local inc = v['inclFolderSubstr']
            local ire = v['inclFolderRegex']
            local exc = v['exclFolderSubstr']
            local ere = v['exclFolderRegex']
            if str:is( inc ) then
                if _incl[inc] == ire then -- dup
                else
                    incl[#incl + 1] = { substr=inc, regex=ire }
                    _incl[inc] = ire
                end
            end                
            if str:is( exc ) then
                if _excl[exc] == ere then -- dup
                else
                    excl[#excl + 1] = { substr=exc, regex=ere }
                    _excl[exc] = ere
                end
            end                
        until true
    end
    return { incl = (#incl > 0) and incl, excl = (#excl > 0) and excl } -- false if none is OK.
end



-- if starters are passed in, it's for plugin manager (auto-mirror), otherwise menu service.
function OttomanicImporter:catalogSync( title, starters, importExt, readMetadata, removeDeletedPhotos )
    local spec
    local props
    app:service{ name=title, async=true, guard=App.guardVocal, progress=true, function( call ) -- main
        local autoImportEnable = app:getGlobalPref( 'autoImportEnable' )
        local autoMirrorFolders = app:getPref( 'autoMirrorFolders' )
        if not autoImportEnable then
            app:show{ warning="Auto-import must be enabled for catalog sync to work." } -- could bypass this requirement ###2.
            call:cancel()
            return
        end
        --[[ I dont think this is necessary - OI seems whether file is imported due to event or scan - doesn't really matter, so don't trip..
        if autoMirrorFolders and not starters then -- bypass prompt if serving mirror function.
            app:show{ info="Consider disabling auto-folder mirroring (uncheck 'Auto-mirror Folders') before synchronizing common catalog folders, to avoid conflict in case there are dir/file changes which would result in a conflict (or just assure there are no such events whilst running catalog sync).",
                actionPrefKey = "Auto-mirror catalog-sync consideration",
            }
        end
        --]]
        
        app:showBezel( nil, "Dialog box will be displayed as soon as background process allows." ) -- ###2 build into bg pause function?
        local s, m = background:pause( 30 ) -- note: this kills auto-sel folder, BUT auto-mirroring *events* will still be processed.
        if s then
            app:clearBezel()
        else
            app:logE( m )
            return
        end
        
        --[[ *** don't do this: leaving auto-sync dirs as is will keep them excluded - 'sall good..
        if tab:is( self.tempPaths ) or tab:is( self.permPaths ) then
            local button = app:show{ confirm="I recommend stopping ad-hoc auto-importing before doing catalog sync, but it's your call..",
                buttons = { dia:btn( "Proceed - I'll take my chances..", 'ok' ), dia:btn( "Cancel - I'll take care of it..", 'cancel' ) },
            }
            if button == 'cancel' then
                call:cancel()
                return
            end
        end
        --]]
        
        -- ###1 note: there is potential for overlapping entries, maybe doc: won't hurt nuthin' just a waste if overlappers are selected.
        -- maybe don't give users enough credit though (ha-ha). - just document it.
        local catFolders = catalog:getFolders()
        local folderSet = tab:createSet( catFolders )
        local activeSources = starters or catalog:getActiveSources()
        local folderPaths = {}
        local folderSourceSet = {}
        for i, v in ipairs( activeSources ) do
            if cat:getSourceType( v ) == 'LrFolder' then
                folderSet[v] = true
                folderSourceSet[v] = true
            end
        end
        local folders = tab:createArray( folderSet )
        local folderPaths = {}
        for i, f in ipairs( folders ) do
            folderPaths[f] = cat:getFolderPath( f )
        end
        table.sort( folders, function( one, two )
            if one and two then
                return folderPaths[one] < folderPaths[two]
            end
        end )
        props = LrBinding.makePropertyTable( call.context )
        local vi = {}
        for i, f in ipairs( folders ) do
            local path = folderPaths[f]
            local ena = fso:existsAsDir( path )
            local propName = "folder_"..i
            props[propName] = folderSourceSet[f] or false
            vi[#vi + 1] = vf:row {
                vf:checkbox {
                    title = path,
                    bind_to_object = props,
                    value = bind( propName ),
                    enabled = ena,
                }
            }
        end
        
        app:initGlobalPref( 'catalogSyncImportExt', "" ) -- blank means *all* importables.
        app:initGlobalPref( 'catalogSyncReadMetadata', false )
        app:initGlobalPref( 'catalogSyncRemoveDeletedPhotos', false )
        props.importExt = importExt or app:getGlobalPref( 'catalogSyncImportExt' )
        props.readMetadata = bool:booleanValue( readMetadata, app:getGlobalPref( 'catalogSyncReadMetadata' ) )
        props.removeDeletedPhotos = bool:booleanValue( removeDeletedPhotos, app:getGlobalPref( 'catalogSyncRemoveDeletedPhotos' ) )
        vi[#vi + 1] = vf:spacer{ height=10 }
        vi[#vi + 1] = vf:row {
            vf:static_text {
                title = "Limited imported extensions to:",
            },
            vf:edit_field {
                bind_to_object = props,
                value = bind'importExt',
                width_in_chars = 20,
                tooltip = "Case sensitive; blank means *all* possible importables. To limit: enter list of extensions separated by commas, e.g. 'NEF, CR2, JPG, jpg' (without the apostrophes).",
            },
        }
        vi[#vi + 1] = vf:spacer{ height=10 }
        vi[#vi + 1] = vf:row {
            vf:checkbox {
                title = "Auto-read changed metadata",
                bind_to_object = props,
                value = bind'readMetadata',
                tooltip = "if this box is checked, and disk file is already in catalog, but xmp has changed since photo last edited in Lightroom, then metadata will be read from file to catalog; if un-checked, no action will be taken when files on disk are already in catalog.",
            },
            vf:spacer{ width=10 },
            vf:checkbox {
                title = "Auto-remove deleted photos",
                bind_to_object = props,
                value = bind'removeDeletedPhotos',
                tooltip = "If checked, photos will be removed if source file no longer present on disk - at least one ancestor folder MUST exist (not necessarily parent); if unchecked, no attention paid to source file presence..",
            },
        }
        
        local button = app:show{ confirm="Import files in following folders and subfolders that are not already in catalog?",--, nor will deleted photos be accrued in 'Deleted' collection.",
            --subs = { tidbit, tidbit2 },
            viewItems = vi,
            --actionPrefKey = "Button-initiated catalog sync"
        }
        if button == 'ok' then
            app:logV( "Got permission to sync catalog folders." )
        else
            call:cancel()
            return
        end
        
        local importSettings = background:getImportSettings( props.importExt or "" ) -- really just a canned "Add", with overlayed import extensions - nothing backgroundy about it, not sel-foldery nor mirrory..
        
        local importColl = autoImportCollMirror -- ###2 - a little wonked, but better than the alternatives @12/Jun/2014 6:19.
        local autoName = call.name -- 'Catalog Sync'
        local readMeta = props.readMetadata
        local delPhotos = props.removeDeletedPhotos
        --local removeMissingPhotos = app:getGlobalPref( 'catalogSyncRemoveMissingPhotos' )
        --      ottomanic:_createS pec( call, folder, recursive, importCustomSet, customText_1, customText_2, coll, card, auto, rm, rdp )
        spec = self:_createSpec( call, nil, true, importSettings, "", "", importColl, false, autoName, readMeta, delPhotos )
            -- reminder: by definition, read-metadata is false, since no registration for changes accompany the catalog sync.
        for i, f in ipairs( folders ) do
            if props['folder_'..i] then
                spec.folder = f
                local s, m = LrTasks.pcall( OttomanicImporter._autoImport, self, spec )
                if spec.call:isQuit() then
                    break -- done: no more folders..
                end
                if s then
                    --Debug.pause( "ai" )
                    app:logv( "auto-imported selected folder (^1) - one pass anyway.", f:getPath() )
                else
                    app:logE( m ) -- in case of catalog-sync, this needs to be a true warning/error.
                end
            else
                app:log( "Skipping ^1 and subfolders.", cat:getFolderPath( f ) )
            end
        end
        
    end, finale=function( call )
        if spec then
            Debug.pauseIf( spec.import.ets ) -- not anticipating ets for auto-add importing.
            exifTool:closeSession( spec.import.ets ) -- catalog sync is like a forced mirroring - theoretically there is no "session" to end - not even any exif-tool either..
        end
        if props then
            if removeDeletedPhotos == nil then
                app:setGlobalPref( 'catalogSyncRemoveDeletedPhotos', props.removeDeletedPhotos )
            end
            if readMetadata == nil then
                app:setGlobalPref( 'catalogSyncReadMetadata', props.readMetadata )
            end
            if importExt == nil then
                app:setGlobalPref( 'catalogSyncImportExt', props.importExt )
            end
        end
        background:continue()
    end }
end



-- Note: the problem with this method if not prompting (apk prompt permanently suppressed) is that
-- there is no way to lock the user out, but still allow for injected keystrokes to have effect.
function OttomanicImporter:_removeDeletedPhotos( actionPrefKey )
    app:pcall{ name="OttomanicImporter_removeDeletedPhotos", async=false, preserve={ selPhotos=true }, function( call )
        if actionPrefKey then -- potentially repressed prompt - also indicates calling is from auto-import and not manual rmv-del.
            local answer = dia:getAnswer( actionPrefKey )
            if answer then -- remembered
                app:showBezel( { dur=1.5, holdoff=1.5 }, "*** Removing Deleted Photos - HANDS OFF LIGHTROOM !!! ***" )
            end
        end
        local delArr = delColl:getPhotos()
        if #delArr == 0 then return end -- reminder: this is re-entrant, and may have been called in a few different contexts, so one may have done the job whilst,
        -- this call was thinkin' about it (bezel is gated but only allows backlog of 10).
        local removeFromCatalog = {}
        local removeFromDelColl = {}
        local cache = lrMeta:createCache{ photos=delArr, rawIds={ 'path', 'isVirtualCopy' }, fmtIds={ 'copyName' }, call=call }
        app:log()
        app:log( "Deleted photos to be removed from catalog:" ) 
        app:log( "------------------------------------------" )
        for i, photo in ipairs( delArr ) do
            local photoPath = cache:getRaw( photo, 'path' )
            if fso:existsAsFile( photoPath ) then
                removeFromDelColl[#removeFromDelColl + 1] = photo
            else
                app:log( cat:getPhotoNameDisp( photo, true, cache ) )
                removeFromCatalog[#removeFromCatalog + 1] = photo
            end
        end
        if #removeFromDelColl > 0 then
            local s, m = cat:update( 30, "Remove photos that do not belong in deleted collection", function( context, phase )
                delColl:removePhotos( removeFromDelColl )
            end )
            if s then
                app:log( "^1 removed from \"deleted\" collection.", str:nItems( #removeFromDelColl, "photos" ) )
            else
                app:logE( m )
                return
            end
        end
        if #removeFromCatalog > 0 then
            catalog:setActiveSources{ delColl } -- could use cat:set.. version, but for only one known source, it's overkill.
            -- reminder: del-photos method will try hard to have photos to be deleted selected - e.g. will clear view-filter adjustment,
            -- but will NOT attempt to expand stacks. - all such things will be restored to how they were upon finale.
            local deleted = cat:deletePhotos{ promptTidbit="Items", call=call, photos=removeFromCatalog, actionPrefKey=actionPrefKey, final=true } -- splatt delete, so no catalog access required
            if deleted then
                app:logV( "Deleted" )
            -- else 'nuff said..
            end
        else
            app:log( "No photos to remove from catalog." )
        end
    end, finale=function( call )
        -- will preserve sel-photos, & active-sources, ...
    end }
end


function OttomanicImporter:removeDeletedPhotos( title )
    app:service{ name=title, async=true, progress=true, function( call )
        -- note: any in gone-sets that haven't made it through to del-coll yet, can be caught next time around.
        self:_removeDeletedPhotos() -- no apk => prompt
    end, finale=function( call )
        -- will preserve sel-photos, & active-sources, ...
    end }
end



-- menu handler for adding folder to catalog (sans photos).
function OttomanicImporter:addFolder( title )
    app:service{ name=title, async=true, progress=true, preserve={ selPhotos=true }, function( call )
        local folderPath = dia:selectFolder{
            title = "Choose folder to add to catalog (no photos will be imported)",
        }
        if folderPath == nil then
            call:cancel()
            return
        end
        local folder = cat:getFolderByPath( folderPath, true ) -- bypass cache.
        if folder then
            local button = app:show{ confirm="Folder is already in catalog - go there now?",
                buttons = dia:yesNo(),
                call = call,
            }
            if button == 'ok' then -- yes
                app:log( "Going there.." )
                catalog:setActiveSources{ folder } -- should be no problem..
                call.selPhotos = nil -- cancel auto-restoral of preserved sel-photos etc.
            else -- return
                app:log( "Not going there.." )
                -- no action required
            end
            call:cancel'' -- silent cancellation.
            return
        end
        local sourceFile = LrPathUtils.child( _PLUGIN.path, "one_pixel.jpg" )
        local targetFile = LrPathUtils.child( folderPath, "_folder_seed_photo_(one_pixel).jpg" )
        local s, m = fso:copyFile( sourceFile, targetFile, false, true ) -- dir already exists - overwrite file if need be.
        if s then
            local photo
            s, m = cat:update( 30, "Import Folder Seed Photo", function( context, phase )
                photo = catalog:addPhoto( targetFile )
            end )
            if s then
                if photo then
                    folder = cat:getFolderByPath( folderPath )
                    if folder then
                        app:logV( "Folder found in catalog after it was added." )
                    else
                        app:logW( "Folder supposedly added to catalog, but I can't find it!" )
                        return -- reluctant to deleted photos in folder that can't be found.
                    end
                    catalog:setActiveSources{ folder } -- will essentially "always" succeed.
                    local deleted = cat:deletePhotos {
                        call = call,
                        photos = { photo },
                        promptTidbit = "Folder seed photo",
                        -- rest are nil/default.
                    }
                    if deleted then
                        local srcs = catalog:getActiveSources() 
                        if srcs and #srcs == 1 and cat:isFolderEqual( folder, srcs[1] ) then
                            local button = app:show{ confirm="You're in the newly added folder - stay here or return to previous sources?",
                                buttons = { dia:btn( "Stay", 'ok' ), dia:btn( "Return", 'cancel' ) }
                            }
                            if button == 'ok' then -- stay
                                app:log( "Staying" )
                                call.selPhotos = nil -- cancel auto-restoral of preserved sel-photos etc.
                            else -- return
                                app:log( "Returning" )
                                -- no action required
                            end
                            call:cancel'' -- silent cancellation.
                        else
                            app:log( "*** Active sources changed, so no offer made to stay/return.." )
                        end
                    else
                        app:logW( "Folder seed photo not deleted." )
                    end
                else
                    app:logW( "Unable to add photo to catalog." )
                end
            else
                app:logE( "Unable to import folder seed photo - ^1", m )
            end
        else
            app:logE( "Unable to copy folder seed file - ^1", m )
        end
    end } --, finale=function( call )
    -- end }
end



function OttomanicImporter:findMissingOrEmptyFolders( title )
    app:pcall{ name=title, async=true, progress=true, function( call )
        app:initGlobalPref( 'findFoldersMode', 'notOnDisk' )
        local vi = {}
        vi[#vi + 1] = vf:row {
            vf:radio_button {
                title = "Not present on disk",
                value = app:getGlobalPrefBinding( 'findFoldersMode' ),
                checked_value = 'notOnDisk',
                tooltip = "Find folders not present on disk, regardless of photos in catalog.",
            },
            vf:radio_button {
                title = "Without photos in catalog",
                value = app:getGlobalPrefBinding( 'findFoldersMode' ),
                checked_value = 'withoutPhotos',
                tooltip = "Find folders without photos in catalog, regardless of whether they're online or not.",
            },
            vf:radio_button {
                title = "Either",
                value = app:getGlobalPrefBinding( 'findFoldersMode' ),
                tooltip = "Find folders that are not on disk or have no photos - either one..",
                checked_value = 'either',
            },
            vf:radio_button {
                title = "Both",
                value = app:getGlobalPrefBinding( 'findFoldersMode' ),
                checked_value = 'both',
                tooltip = "Find folders that are not on disk, but only if they have no photos.",
            },
        }
        local button = app:show{ confirm="Find folders?",
            viewItems = vi,
            call = call,
        }
        if button == 'cancel' then
            call:cancel()
            return
        end
        local mode = app:getGlobalPref( 'findFoldersMode' ) or error( "no mode" )
        call:setCaption( "Finding folders.." )
        local targets = {}
        local children
        local function parent ( single )
            if call:isQuit() then return end
            local onDisk
            local withPhotos
            if mode ~= 'withoutPhotos' then
                onDisk = fso:existsAsDir( cat:getFolderPath( single ) )
            end
            if mode ~= 'notOnDisk' then
                withPhotos = #(single:getPhotos() or {}) > 0
            end
            if mode == 'notOnDisk' then
                if not onDisk then
                    targets[#targets + 1] = single    
                end
            elseif mode == 'withoutPhotos' then
                if not withPhotos then
                    targets[#targets + 1] = single    
                end
            elseif mode == 'either' then
                if not onDisk or not withPhotos then
                    targets[#targets + 1] = single    
                end
            elseif mode == 'both' then
                if not onDisk and not withPhotos then
                    targets[#targets + 1] = single    
                end
            else
                app:error( "bad mode: ^1", mode )
            end
            children( single:getChildren() )
        end
        function children( array )
            for i, folder in ipairs( array ) do
                parent( folder )
                if call:isQuit() then return end
            end
        end
        children( catalog:getFolders() )
        if #targets > 0 then
            catalog:setActiveSources( targets )
            if #targets == 1 then
                app:show{ info="1 such folder is selected.", actionPrefKey="Missing or empty folder(s) selected" }
            else
                app:show{ info="^1 such folders are selected.", #targets, actionPrefKey="Missing or empty folder(s) selected" }
            end
        else
            app:show{ info="There are no such folders in your catalog.", actionPrefKey="No missing or empty folder(s) in catalog" }
        end
    end }   
end

return OttomanicImporter