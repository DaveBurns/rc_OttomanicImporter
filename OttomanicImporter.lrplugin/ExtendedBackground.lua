--[[
        ExtendedBackground.lua
        
        Responsibilities include:
            * Auto-import upon folder selection (handled as one-at-a-time auto-imports, even if re-check period ~= 0) - does NOT use dir-chg app notifications.
            * Auto-mirroring chosen folders - one-time force scan followed by dir-chg notifications - auto-starts app and keeps it informed of subject dirs..
--]]

local ExtendedBackground, dbg, dbgf = Background:newClass{ className = 'ExtendedBackground' }



local events = 1        -- bit-mask (currently, non-zero means "all events" - there is no facility for selective listening, although there could be..).
local noEvents = 0      -- un-register by registering for no events.
local backgroundAddr = _PLUGIN.id..".Background"    -- notification address (on the intercom) for background task.
    

-- hard-coded import set used for mirroring - import extensions may be paired down..
ExtendedBackground.importCustomSet = {
    customSetName = "Auto-mirror Folders",
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
    local a = ExtendedBackground.importCustomSet.importExt.rgb
    a[#a + 1] = 'png'
    a[#a + 1] = 'PNG'
end



--- Constructor for extending class.
--
--  @usage      Although theoretically possible to have more than one background task,
--              <br>its never been tested, and its recommended to just use different intervals
--              <br>for different background activities if need be.
--
function ExtendedBackground:newClass( t )
    return Background.newClass( self, t )
end



--- Constructor for new instance.
--
--  @usage      Although theoretically possible to have more than one background task,
--              <br>its never been tested, and its recommended to just use different intervals
--              <br>for different background activities if need be.
--
function ExtendedBackground:new( t )
    local interval -- determines bg task frequency - do not exceed 1 (second), or it's too laggy (in my opinion), and no less than .1 or it's just a waste..
    local minInitTime
    local idleThreshold
    -- *** reminder: background task timing assumes a 1 second interval as baseline, so don't change it (see skip-counter).
    -- it doesn't use much CPU nor disk anymore, since it's just looking for sel changes or mirror incl/excl changes.
    if app:getUserName() == '_RobCole_' and app:isAdvDbgEna() then
        interval = .5 -- push the limit for personal testing / use.. - .1 works just dandy.
        idleThreshold = 1 -- not used (since no idle processing is being considered)
        minInitTime = .5 -- a half seconds is plenty for me to see it's happening...
    else
        interval = .5 -- default is .5 which strikes a good balance of responsiveness (auto-importing sel-folders) and conservative resource usage.
        idleThreshold = 1 -- not used (since no idle processing is being considered)
        minInitTime = nil -- accept default: 10-15 seconds or so.
    end    
    local o = Background.new( self, { interval=interval, minInitTime=minInitTime, idleThreshold=idleThreshold } )
    o.oneSecTicks = math.ceil( 1 / interval ) -- how many intervals make up a second.
    o.lastCatFolderSet = nil -- last set of catalog folders, for folder-set change detection.
    o.lastMirrorFolderInclExcl = nil -- last set of incl/excl criteria for change detection.
    o.mirrorPaths = {} -- lookup: keys are folder paths, values are specs. note: these are only recorded when successfully registered.
        -- an implication of this is: if there ever is any suspicion that app may not have the latest, clearing this out will cause
        -- all to be recomputed and re-registered.
    return o
end



-- this is the same as OI's, except for the log tidbit.
function ExtendedBackground:processDirNotice( msg )
    if not app:getPref( 'autoMirrorFolders' ) then return false, "Auto-mirroring is not enabled" end
    if msg.eventType == 'created' then
        app:log( "New dir: '^1' (noticed by background task)", msg.path ) 
    elseif msg.eventType == 'deleted' then
        app:logW( "Dir exists, but was supposedly deleted: '^1' (noticed by background task)", msg.path ) 
    elseif msg.eventType == 'modified' then
        app:logV( "Dir modified: '^1' (no action taken) - noticed by background task.", msg.path ) 
    else
        app:logW( "Un-recognized dir event (^1), path: '^2' - received by background task.", msg.eventType, msg.path ) 
    end
    return true
end



-- really making sure the file is registered for mirroring, but finding it's spec (if present, it will always match mirror-spec, but may not be present).
function ExtendedBackground:getMirrorSpecForFile( file )
    --local tried = { "\n" }
    for folderPath, spec in pairs( self.mirrorPaths ) do
        --app:logV( "Considering mirror-path '^1', spec: ^2", folderPath, spec and true )
        local parent = LrPathUtils.parent( file )
        while parent do
            if parent == folderPath then
                Debug.pauseIf( self.mirrorSpec ~= spec, "spec mismatch" )
                return spec -- @8/Jun/2014 20:55, this will always be the mirror-spec.
            else
                --tried[#tried + 1] = parent
                parent = LrPathUtils.parent( parent )
            end
        end
    end
    --local c = table.concat( tried, "\n" )
    --app:log( "*** No mirror spec for file: '^1' - tried: ^2", file, c )
end



-- only used for auto-mirroring - not folder-sel.
-- reminder: folder-sel importing is only honored if not subdir of auto-mirrored dir, so speparate settings makes sense.
function ExtendedBackground:processFileNotice( msg )
    if not app:getPref( 'autoMirrorFolders' ) then return false, "Auto-mirroring is not enabled" end
    assert( self.mirrorSpec, "no mirror spec" )
    assert( self.mirrorSpec.call, "no mirror spec call" )
    --Debug.pauseIf( self.mirrorSpec.folder == nil, "no folder in mirror spec" ) - folder is not needed for auto-mirroring updates. *** It will be needed for periodic maint imports (in case user answered 'No',
        -- or Ottomanic was reloaded, or dir-chg app was restarted(?)).
    if msg.eventType == 'created' then
        local spec = self:getMirrorSpecForFile( msg.path or error( "no path in msg" ) )
        if spec then
            ottomanic:processFileCreated( msg, spec )
        else
            Debug.pause() -- this shouldn't happen often, since event notices are only being registered for mirroring - not folder-sel.
            -- it could happen during the window before registration changes take hold, since those are asynchronous..
            app:log( "*** New file reported by dir-chg app - no associated mirror-spec, so ignored: ^1", msg.path )
        end
    elseif msg.eventType == 'deleted' then -- this mostly never happens (it means file was deleted, but exists on disk - possible if events and timing are just so..).
        -- could assure spec, but since it's a don't care, why not save a few cpu cycles..
        app:logW( "File exists, but was supposedly deleted: ^1", msg.path ) -- presumably, file was "undeleted" after delete notification was sent.
    elseif msg.eventType == 'modified' then
        if app:getPref( 'autoMirrorReadMetadata' ) then
            local spec = self:getMirrorSpecForFile( msg.path ) -- make sure parent dir is currently active (enabled for mirroring).
            if spec then
                assert( spec.readMetadata ~= nil, "read-metadata not spec" ) -- sanity check..
                ottomanic:autoReadMetadata( msg.path, spec )
            else
                app:logW( "File modified: '^1' - no action is being taken (no import spec found).", msg.path ) 
            end
        else
            app:logV( "File modified: '^1' - no action is being taken (auto-read-metadata is not enabled).", msg.path ) 
        end
    else
        app:logW( "Un-recognized file event (^1), path: ^2", msg.eventType, msg.path ) 
    end
    return true
end



-- *** note: this should match method in OI module, save for a few spec-related things..
-- Neither notifier app nor I can't tell if it's dir or file once it's gone, so.. (Sherlock Holmes..).
function ExtendedBackground:processGoneNotice( msg )
    if not app:getPref( 'autoMirrorFolders' ) then return false, "Auto-mirroring is not enabled" end
    local folder = cat:getFolderByPath( msg.path )
    local photo
    if folder then
        app:log( "*** Folder is gone: ^1", msg.path )
    else
        photo = cat:findPhotoByPath( msg.path )
        if photo then
            local parent = LrPathUtils.parent( msg.path )
            if parent and ( LrFileUtils.exists( parent ) == 'directory' ) then -- parent dir must exist, or disappearing photos will be ignored.
                app:logV( "Photo source file has gone missing (but parent folder still exists): ^1", msg.path )
                self.goneSet = self.goneSet or {}
                self.goneSet[photo] = true
                local goneArray = tab:createArray( self.goneSet )
                local s, m = cat:update( -5, "Update Deleted Photos Collection", function( context, phase ) -- try for up to 5 seconds, but don't trip if no can do - catch it next time around..
                    delColl:addPhotos( goneArray )
                end )
                if s then
                    self.goneSet = {}
                    app:log( "Added ^1 to \"deleted\" collection", str:nItems( #goneArray, "photos" ) )
                    if app:getPref( 'autoMirrorRemoveDeletedPhotos' ) then -- this keeps it dynamic, since not fixed into the spec.
                        app:pcall{ name="ExtendedBackground_processGoneNotice", async=true, guard=App.guardSilent, function( call )
                            while #delColl:getPhotos() > 0 do
                                ottomanic:_removeDeletedPhotos( "Removing deleted photo(s) as dictated by auto-mirror setting" ) -- this may present prompt,
                                -- or may not - but if not, there will be a lengthy delay *before* pulling photos from del-coll.
                            end
                        end }
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



-- this is how folders get auto-mirrored..
function ExtendedBackground:processDirFileChangeNotifyMessage( msg )
    if msg.name == 'registered' then
        if str:is( msg.comment ) then
            app:logV( "Background task notified of dir registration, comment: '^1'.", msg.comment )
        else
            app:logV( "Background task notified of dir registration." )
        end
    elseif msg.name == 'notify' then
        if str:is( msg.comment ) then
            app:logV( "Background task notified of dir-file change: '^1' (^2) - comment: ^3.", msg.path, msg.eventType, msg.comment )
        else
            app:logV( "Background task notified of dir-file change: '^1' (^2).", msg.path, msg.eventType )
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
        if not s then -- I think the only trapped/reported error is: auto-mirror not enabled.
            app:logW( m )
        -- else enough logged already..
        end
    elseif msg.name == 'error' then
        -- reminder: single biggest difference between app-alert and bg-disp is the latter requires an ID and is intended for potentially fleating errors (to be cleared by ID).
        -- but also: app-alert includes (log and) immediate bezel display, and no prompt upon cancel - holdoff?. bg-disp-err has a delayed effect by default, and no holdoff (nor log) - option to prompt upon cancel.
        if str:is( msg.comment ) then
            app:alertLogE( "dir-chg app error: ^1", msg.comment ) -- ###2 not sure why it's using app-alert instead of bg-disp.
        else
            app:alertLogE( "dir-chg app reported error sans comment" ) -- ditto.
        end
    else
        if str:is( msg.comment ) then
            app:logV( "Background task received unexpected message (^1), comment: '^2'.", msg.name, msg.comment )
        else
            app:logV( "Background task received unexpected message: '^1'.", msg.name )
        end
        Debug.pause( msg )
    end
end


-- get a copy of the import settings with specified import-extension bootstrapped in.
function ExtendedBackground:getImportSettings( importExtStr )
    if importExtStr ~= nil and type( importExtStr) ~= 'string' then
        app:callingError( type( importExtStr ) )
    end
    local ics
    if str:is( importExtStr ) then
        local extArr = str:split( importExtStr, "," )
        if #extArr > 0 then
            ics = tab:deepCopy( ExtendedBackground.importCustomSet ) -- make a deep copy, so we're not permanently modifying static variable.
            local ie = { raw={}, rgb={}, video={} }
            local rawSet, rgbSet, videoSet = tab:createSet( ics.importExt.raw ), tab:createSet( ics.importExt.rgb ), tab:createSet( ics.importExt.video )
            for i, ext in ipairs( extArr ) do
                if #ext > 4 then
                    app:logW( "Are you sure '^1' is a valid extension (seems long - remember to separate extensions with commas)?", ext )
                end
                -- reminder: these should be a fairly comprehensive set of extensions - granted, they don't include all case variations.
                if rawSet[ext] then
                    ie.raw[#ie.raw + 1] = ext
                elseif rgbSet[ext] then
                    ie.rgb[#ie.rgb + 1] = ext
                elseif videoSet[ext] then
                    ie.video[#ie.video + 1] = ext
                else -- it seems this sort of error should illicit a bezel or scope display, if auto-importing anyway ###1.
                    app:logW( "'^1' is not being considered a valid extension. If it should be considered valid, then please notify Rob Cole so it can be added to list - thanks.", ext )
                end
            end
            ics.importExt = ie -- rebuilt.
            --Debug.lognpp( ics )
        else -- never happens
            ics = ExtendedBackground.importCustomSet -- use in place
        end
    else
        ics = ExtendedBackground.importCustomSet -- use in place
    end
    return ics
end



--- Initialize background task - precedes periodic processing, but done asynchronously.
--
--  @param      call object - usually not needed, but its got the name, and context... just in case.
--
function ExtendedBackground:init( call )
    self.call = call
    --Debug.pause()
    local s, m, m2, m3, m4, m5, set = LrTasks.pcall( cat.assurePluginCollections, cat, { "Auto-imported (ad-hoc)", "Auto-imported (folder-sel)", "Auto-imported (auto-mirror)", "Manually-imported", "Deleted" } ) -- new collection for mirror'd imports?
    if s then
        app:assert( set, "no set" )
        gbl:setValue( 'autoImportCollAdHoc', m )
        gbl:setValue( 'autoImportCollFolderSel', m2 )
        gbl:setValue( 'autoImportCollMirror', m3 )
        gbl:setValue( 'manualImportColl', m4 )
        gbl:setValue( 'delColl', m5 )
        app:logv( "Plugin collections \"assured\".." )
        local ics = self:getImportSettings( app:getPref( 'autoMirrorImportExt' ) )        
        local readMetadata = app:getGlobalPref( 'autoMirrorReadMetadata' ) or false -- reminder: this is the mirroring spec, not the auto-import upon folder-sel spec.
        local removeDeletedPhotos = app:getGlobalPref( 'autoMirrorRemoveDeletedPhotos' ) or false -- reminder: this is the mirroring spec, not the auto-import upon folder-sel spec.
        self.mirrorSpec = ottomanic:_createSpec( call, nil, true, ics, "", "", autoImportCollMirror, false, "Auto-mirror Folders", readMetadata, removeDeletedPhotos )
        local legacyColl -- Legacy coll deletion logic can be removed in 2016 (after most people using it have upgraded).
        for i, v in ipairs( set:getChildCollections() ) do
            if v:getName() == "Auto-imported" then
                legacyColl = v
                break
            end
        end
        s, m = cat:update( 60, "Clear auto-import collection", function( context, phase )
            if legacyColl then
                legacyColl:delete()
            end
            autoImportCollAdHoc:removeAllPhotos()
            autoImportCollFolderSel:removeAllPhotos()
            autoImportCollMirror:removeAllPhotos()
            manualImportColl:removeAllPhotos()
            -- deleted collection accrues indefinitely - cleared by explicit manual action only.
        end )
        app:log( "Plugin import collections emptied." )
        dirChgApp:setMessageCallback( backgroundAddr, ExtendedBackground.processDirFileChangeNotifyMessage, self )
        Import.fnSet = {}
        Import.dtoTable = {}
        Import.allPhotoRecs = {}
        Import.exifTable = {}       -- shared table containing exif info of candidate photos.
        local allPhotos = catalog:getAllPhotos()
        if app:getGlobalPref( 'importCritEna' ) then
            if app:getGlobalPref( 'origFilenameEna' ) then
                local s, m = cat:initForOriginalFilenames() -- logs details upon success.
                if not s then
                    app:logE( m )
                    self.initStatus = false
                    return
                end
            else
                app:log( "Original filename support is not enabled, so not being initialized.." )
            end
            -- reminder: whatever goes in a record must be updated when photo added in Import.lua (see 'if added and photo').
            -- Lr seems to be an inordinately long time for this info, but I not sure whatta do 'bout it ###3 (I could optimize items requested based on options selected, but currently
            -- this init routine isn't smart enough to know what user is doing in advanced preference file, so just get's the things being used by default.
            local cache = lrMeta:createCache{ photos=allPhotos, fmtIds={ 'fileName', 'cameraSerialNumber', 'cameraModel' }, rawIds={ 'path', 'uuid', 'dateTimeOriginal', 'isVirtualCopy' }, call=call } -- overkill, since cache not used elsewhere - oh well..
            -- benefit of cache is in call handling, and standard convention.. - slight performance penalty is a non-issue since confined to startup/init and the vast moajority of time is spent by Lr gathering catalog info.
            call:setCaption( "Processing acquired metadata..." ) -- hardly worth displaying - the *vast* majority of time is spent in Lr's batch metadata getting method(s).
            for i, photo in ipairs( allPhotos ) do
                repeat
                    if cache:getRaw( photo, 'isVirtualCopy' ) then break end -- ignore virtual copies
                    local filename = cache:getFmt( photo, 'fileName' ) -- should be in the cache ###1.
                    Import.fnSet[filename] = true -- reminder: if user deletes this file, it will still be recorded here ###2 - it's been documented on web page.
                    local dto = cache:getRaw( photo, 'dateTimeOriginal' )
                    -- be sure to include a corresponding line in Import module when adding to or changing:
                    local rec = { sn=cache:getFmt( photo, 'cameraSerialNumber' ), model=cache:getFmt( photo, 'cameraModel' ), fn=filename, path=cache:getRaw( photo, 'path' ), uuid=cache:getRaw( photo, 'uuid' ),  dto=cache:getRaw( photo, 'dateTimeOriginal' ) }
                    Import.allPhotoRecs[photo] = rec -- glorified metadata cache..
                    if dto then
                        local pt = Import.dtoTable[dto]
                        if pt == nil then
                            Import.dtoTable[dto] = {}
                            pt = Import.dtoTable[dto]
                        end
                        pt[photo] = rec
                    else
                        --Debug.pause( "no dto" )
                    end
                until true
            end
        else
            app:log( "Additional import criteria (e.g. duplicate file checking) is not enabled, so not being initialized.. (still - initializing for filename uniqueness support)" )
            local cache = lrMeta:createCache{ photos=allPhotos, fmtIds={ 'fileName' }, call=call } -- overkill, since cache not used elsewhere - oh well..
            for i, photo in ipairs( allPhotos ) do
                local filename = cache:getFmt( photo, 'fileName' )
                Import.fnSet[filename] = true -- reminder: if user deletes this file, it will still be recorded here ###2 - it's been documented on web page.
            end
        end
        if s then
            s, m = LrTasks.pcall( OttomanicImporter._autoStartPerm, ottomanic ) -- returns a number, which may be zero or greater.
        end
    end
    if s then
        local nStarted = m -- write-only...    
        self.initStatus = true
        -- this pref name is not assured nor sacred - modify at will.
        if not app:getPref( 'autoImportSelFolder' ) then
        --if not app:getPref( 'background' ) then -- check preference that determines if background task should start.
            -- leave it run, but just don't do anything in it. self:quit() -- indicate to base class that background processing should not continue past init.
        end
        --Debug.pause()
    else
        self.initStatus = false
        app:logE( "Unable to initialize due to error: ^1", m )
        app:show{ error="Unable to initialize - check log file for details." }
    end
end



--- Perform background photo processing, if there were any, which there isn't, yet...
--
--  @param target lr-photo to be processed, may be most-selected, selected, filmstrip, or any (if idle processing).
--  @param call background call object.
--  @param idle (boolean) true iff called from idle-processing considerator.
--
--  @usage set enough-for-now when time intensive operations have occurred such that subsequent idle-processing would be too much for now (ignored if idle processing).
--         <br>this is a non-critical value, but may help prevent Lightroom UI jerkiness in some cases.
--
function ExtendedBackground:processPhoto( target, call, idle )
    self.enoughForNow = false -- set to true if time consuming processing took place, which is not expected to happen again next time.
end



-- Determine if currently selected folders are same as previously selected folders.
-- Note: it is unsufficient to check active-sources, since it will be a different object even if it points to the same folders,
-- note: there well not be a false positive if a collection were added to the mix, since it's only looking at folders.
function ExtendedBackground:_equiv( t2 )
    local t1 = self.lastSelFolders
    if ( t1 == nil ) and ( t2 == nil ) then
        return true
    elseif t1 == nil then
        return false
    elseif t2 == nil then
        return false
    end
    if type( t1 ) ~= type( t2 ) then
        app:error( "bad type" )
    end
    if #t1 ~= #t2 then
        return false
    end
    local lookup = tab:createSet( t2 )
    for i, v in pairs( t1 ) do
        if not lookup[v] then
            return false
        end
    end
    return true
end


-- for auto-import sel-folder:
local skipCounter = 0
local canceled


-- Called every bg interval to either skip a beat, do nothing, or see if folder changed and auto-import..
-- Reminder: NOT called unless auto-importing is enabled, and sel-folder mode too.
function ExtendedBackground:_autoImportSelFolder()

    -- get list of active folders - these will be auto-imported if conditions are such, and maybe saved for comparison to see if needs be done again..
    local selFolders = {}
    for i, src in ipairs( catalog:getActiveSources() ) do
        if cat:getSourceType( src ) == 'LrFolder' then
            selFolders[#selFolders + 1] = src
        end
    end

    local setCap = true -- we want caption when auto-imp begins, except maybe if repeat scan..
    if app:getPref( 'autoImportSelFolderCont' ) then -- continuous
        skipCounter = skipCounter + 1
        local skipLimit = app:getPref( 'autoImportSelFolderInterval' ) * self.oneSecTicks -- number of ticks required for minimum elapsed time in seconds.
        if skipCounter >= skipLimit then -- not sure how much sense this makes in case of auto-sel, but I guess it doesn't hurt..
            skipCounter = 0
            setCap = false -- if re-checking due to interval expiration, then no caption. users will just have to trust it's working,
            -- or check the log file..
        elseif self:_equiv( selFolders ) then --same folders as last time.
            return -- skip
        else -- new folder selection.
            skipCounter = 0
            canceled = false
        end
    else -- check for new sel - if same sel, we're done here.
        canceled = false
        if self.lastSelFolders == nil then 
            -- proceed (would be detected by -equiv func, but this allows custom dbg msg.
            dbgf( "initial dir(s) selected" )
        elseif not self:_equiv( selFolders ) then
            --Debug.pause( "neq" )
            dbgf( "new dir(s) selected" )
        else
            return            
        end
        skipCounter = 0 -- not-applicable if autoImportSelFolderInterval is disabled, but assures a reset skip-counter in case user enables.
    end

    local customSetName = app:getPref( 'autoImportSelFolderCustomSetName' )
    if not str:is( customSetName ) then
        app:logWarning( "No custom set name." )
        return
    end
    
    local importCustomSet = ottomanic:getCustomSet( customSetName )
    if importCustomSet == nil then
        app:logWarning( "No custom set: ^1", customSetName )
        return
    end
    
    -- read initialized prefs (never nil).
    local recursive = app:getPref( 'autoImportSelFolderRecursive' )
    local customText_1 = app:getPref( "autoImportSelFolderCustomText_1" )
    local customText_2 = app:getPref( "autoImportSelFolderCustomText_2" )
    local card = false
    local auto = "Auto-import Selected Folder" -- *** beware: this is being checked for verbatim when deciding whether to log or suppress.
    local readMetadata = app:getPref( "autoImportSelFolderReadMetadata" )
    local removeDeletedPhotos = app:getPref( "autoImportSelFolderRemoveDeletedPhotos" )
    local folder = nil -- note: folder will be bootstrapped in context.
    -- in this case, one spec is shared by all folders, which is OK, since they will be handled synchronously (folder bootstrapped in loop).
    -- worth noting: although a new import object will be created each time, it is smart enough to re-use the exiftool session object will be created only the first time,
    -- which is dedicated to auto-import selected folder(s) only.
    local spec, qual = ottomanic:_createSpec( self.call, folder, recursive, importCustomSet, customText_1 or "", customText_2 or "", autoImportCollFolderSel, card, auto, readMetadata, removeDeletedPhotos )
    if spec then
        app:log( "auto-import spec created for background processing (upon folders selection)" )
    else
        app:error( qual ) -- throw background error handled in standard fashion (this function will still continue to be called, after a delay, so user needs to fix, or reload, or disable plugin, or something, *iff* it keeps happening, otherwise it will be cleared and carry on...
    end
    
    -- checks if specified (selected) folder is in tree being mirrored, or importing ad-hoc.
    -- if not in already auto-importing tree, it's ripe for auto-importing as selection.
    local function isOkToAutoImportSelFolder( f )
        local p = f
        repeat
            if p then
                local path = cat:getFolderPath( p ) -- normalized
                if self.mirrorPaths[path] then
                    app:logV( "Not auto-importing selected folder (^1) because it's in the same tree as auto-mirror folder (^2), which takes priority.", cat:getFolderPath( f ), path )
                    return false
                else
                    dbgf( "Not mirroring folder (at top level anyway): ^1", path )
                end
                if ottomanic.tempPaths[path] then
                    if cat:isEqualFolders( p, f ) then
                        app:logV( "Not auto-importing selected folder (^1) because it's a \"temporary\" auto-importing folder, which takes priority.", path )
                        return false
                    elseif ottomanic.tempPaths[path].recursive then
                        app:logV( "Not auto-importing selected folder (^1) because it's in the same tree as \"temporary\" (and recursive) auto-importing folder (^2), which takes priority.", cat:getFolderPath( f ), path )
                        return false
                    else
                        assert( ottomanic.tempPaths[path].recursive ~= nil, "recursive?" )
                    end
                end
                if ottomanic.permPaths[path] then
                    if cat:isEqualFolders( p, f ) then
                        app:logV( "Not auto-importing selected folder (^1) because it's a \"permanent\" auto-importing folder, which takes priority.", path )
                        return false
                    elseif ottomanic.permPaths[path].recursive then
                        app:logV( "Not auto-importing selected folder (^1) because it's in the same tree as \"permanent\" (and recursive) auto-importing folder (^2), which takes priority.", cat:getFolderPath( f ), path )
                        return false
                    else
                        assert( ottomanic.permPaths[path].recursive ~= nil, "recursive?" )
                    end
                end
            else
                return true
            end
            p = p:getParent() -- *** beware: children don't return their original parent objects - ugh.
        until false
    end
    
    if not canceled then -- never canceled or cancellation reset.
        app:pcall{ name="Auto-import sel folders - baseline scan", function( icall )
            for i, lrFolder in ipairs( selFolders ) do
                repeat
                    if not app:getGlobalPref( 'autoImportEnable' ) then return end
                    if not app:getPref( 'autoImportSelFolder' ) then return end
                    if icall:isQuit() then return end -- from inner func - will still save last-sel-folders..
                    local ok = isOkToAutoImportSelFolder( lrFolder )
                    if ok then
                        if setCap then
                            icall:assureScope{ title="Auto-importing selected folder" }
                        else
                            icall:killScope()
                        end
                        spec.folder = lrFolder -- bootstrap target folder.
                        --Debug.pause( cat:getFolderPath( spec.folder ) )
                        spec.call = icall -- for p.scope
                        local s, m = LrTasks.pcall( OttomanicImporter._autoImport, ottomanic, spec ) -- take one pass then return. Note: repetition (continuous-ness) is handled by code way up north..
                        if spec.call:isQuit() then
                            canceled = true
                            return -- 9/10 it's only one folder and so this is a don't care - still now it's consistent..
                        end
                        if s then
                            --Debug.pause( "ai" )
                            app:logv( "auto-imported selected folder (^1) - one pass anyway.", lrFolder:getPath() )
                        else
                            -- bollocks.
                            app:logv( m ) -- why not an error or warning? - I can't remember now, it seems there was potential for false errors/warnings which could not be retracted...
                        end
                    else
                        --Debug.pause( "not ripe:", lrFolder:getName() ) - evident by lack of p.scope.
                    end
                until true
            end
        end }
        -- note: exif-tool session for sel-folders is never closes.
    else
        app:logV( "Auto-import upon folder selection is still canceled.." )
    end
    
    self.lastSelFolders = selFolders

end



-- determines if there is an ad-hoc auto-importer in same tree as top-level catalog path.
function ExtendedBackground:_isAutoImportingAdHoc( catPath )
    local function is( pathSpecs )
        for adHocPath, spec in pairs( pathSpecs ) do
            if str:isBeginningWith( adHocPath, catPath ) then -- ad-hoc path begins with cat-path, 
                return true                                   -- so it's in the same tree.
            --else
                --Debug.pause( adHocPath, catPath )
            end
        end
    end
    if is( ottomanic.tempPaths ) then return true
    else return is( ottomanic.permPaths ) end
end


-- get all online catalog folders
function ExtendedBackground:_getCatFolderSet()
    local folders = catalog:getFolders()
    local set = {}
    for i, f in ipairs( folders ) do
        local path = cat:getFolderPath( f ) -- get normalized path.
        if fso:existsAsDir( path ) then
            set[path] = f
        end
    end
    return set
end


-- Determine if update is warranted, and if so, prepare requisite data structures.
-- note: mirror-paths is used in ottomanic too, and so should never be set nil.
function ExtendedBackground:_prepareForUpdate()
    local update
    -- note: cat-folder-set is only for top-level folders, whereas change to incl/excl could affect subfolder inclusion/exclusion.
    if self.mirrorFolderInclExcl == nil then
        self.mirrorFolderInclExcl = ottomanic:getAutoMirrorInclExcl()
        app:logV( "folder incl/excl init" )
        update = true
    else
        local inclExcl = ottomanic:getAutoMirrorInclExcl()
        if not tab:isEquivalent( self.mirrorFolderInclExcl, inclExcl ) then
            -- assert( not tab:isEquiv( self.mirrorFolderInclExcl, inclExcl ), "###4" ) - not asserting.
            self.mirrorFolderInclExcl = inclExcl
            app:logV( "folder incl/excl change" )
            update = true
        else -- no update required as result of incl/excl criteria change.
            -- assert( tab:isEquiv( self.mirrorFolderInclExcl, inclExcl ), "###4" ) - not asserting.
            --Debug.pause( "incl/excl equiv" )
        end
    end
    if self.catFolderSet == nil then
        self.catFolderSet = self:_getCatFolderSet()
        app:logV( "cat folder set init" )
        update = true
    else
        local set = self:_getCatFolderSet()
        if not tab:isEquivalent( self.catFolderSet, set ) then
            -- assert( not tab:isEquiv( self.catFolderSet, set ), "###4" ) - not asserting.
            self.catFolderSet = set
            app:logV( "cat folder set change" )
            update = true
        else -- no update required as result of cat-folder-set change
            -- assert( tab:isEquiv( self.catFolderSet, set ), "###4" ) - not asserting.
            --Debug.pause( "cat-folder-set equiv" )
        end
    end
    return update
end



local logSkip = 0
local noDirChgMsgLogged
-- called every interval (e.g. .5 seconds) - so must do nothing most of time ;-}.
function ExtendedBackground:_autoMirrorFolders()

    assert( self.call, "no bg call" )
    assert( self.mirrorSpec, "no import spec for mirroring" )
    assert( self.mirrorPaths ~= nil, "no mirror paths" )
    
    local update -- flag
    
    if tab:is( self.mirrorPaths ) then -- it's been initialized before
        local s, m = dirChgApp:getPresence( 7, "Background" )
        if s then
            logSkip = logSkip + 1
            if logSkip > ( 2 * self.oneSecTicks ) then -- every so often, output verbose assurance to log. not sure why this isn't happening more on time ###2.
                app:logV( "Dir/File Change Notification App continues to serve auto-mirroring of folders." )
                logSkip = 0
            end
        else
            if m == 'offline' then -- it's been given a few chances
                app:logW( "*** dir-chg app is offline - will attempt to re-initialize and re-scan - to assure no changes were lost." )
                self.mirrorPaths = {} -- this is sufficient for current folders to be re-added, so they will be auto-imported below.
                update = true
            else -- uncertain..
                app:logV( "dir-chg app presence: ^1", m )
            end
        end
    else -- needs to be initialized/computed (or no dirs fit the pattern, despite mode being enabled..).
        update = true
    end

    local upd = self:_prepareForUpdate() -- assure requisite data is init for update.
    update = update or upd -- do update if warranted based on presence detection or data change.
    if not update then return end
    logSkip = 0

    -- update is warranted - compute or update mirror paths, and try to send to app.

    local recs = {}
    local removed = {} -- set
    local added = {} -- lookup
    local temp, perm = ottomanic.tempPaths, ottomanic.permPaths
    local incl, excl = self.mirrorFolderInclExcl.incl, self.mirrorFolderInclExcl.excl -- ottomanic:getAutoMirrorInclExcl()
    
    Debug.lognpp( self.mirrorFolderInclExcl )
    
    local inclSet = {} -- set of folders to be auto-mirrored (online and fit pattern).
    
    local yc = 0
    local function considerFolder( path, f )
        yc = app:yield( yc )
        app:logV( "Considering folder: ^1", path )
        if str:includedAndNotExcluded( path, incl, excl ) then -- specified for mirroring.
            app:logV( "Included: ^1", path )
            if self:_isAutoImportingAdHoc( path ) then -- there is an ad-hoc auto-importing folder in tree under consideration for auto-mirroring - refrain from auto-mirroring.
                if self.mirrorPaths[path] then -- it's being mirrored.
                    self.mirrorPaths[path] = nil
                    -- note: not removed since temp or perm still needs events - not sure, it seems possible to have multiple listeners now, so they should be independent.
                    -- in other words, *this* entity should be removed from list, even if temp or perm is still on a list.
                    removed[path] = true -- another idea is just to register for mirroring events despite temp or perm auto-importing, and then ignore them if not applicable.
                    -- I probably need the logic to ignore anyway, as cheap insurance, but perhaps both is not such a bad idea - I mean permanent auto-importing folders will never be mirrored so..
                    recs[#recs + 1] = { dir=path, events=noEvents, notifyAddr=backgroundAddr, recursive=true } -- notify-addr is still required, since other entities can also listen to same dir / events..
                    app:logV( "Already auto-importing ad-hoc, removing/unregistering: ^1", path )
                    -- reminder: these are being removed from bg notify addr, temp or perm may still receive notifications, at different address.
                -- else
                    -- dbgf( "Auto-importing ad-hoc, but not being mirrored: ^1", path )
                end
            else -- to be included and not importing ad-hoc.
                if not self.mirrorPaths[path] then -- not already.
                    -- make it so:
                    if fso:existsAsDir( path ) then
                        self.mirrorPaths[path] = self.mirrorSpec
                        added[path] = f
                        recs[#recs + 1] = { dir=path, events=events, notifyAddr=backgroundAddr, recursive=true }
                        app:logV( "Adding/registering: ^1", path )
                        inclSet[path] = true
                    else
                        app:logW( "Dir is included for auto-mirroring, but is offline: ^1", path )
                    end
                else -- is to be and is..
                    -- dbgf( "Already scheduled for auto-mirroring: ^1", path )
                    app:logV( "Already registered, maintaining: ^1", path )
                    inclSet[path] = true
                end
            end
        else -- not to be auto-mirrored
            app:logV( "Excluded: ^1", path )
            if self.mirrorPaths[path] then -- was to be auto-mirrored.
                -- revoke..
                self.mirrorPaths[path] = nil
                removed[path] = true
                recs[#recs + 1] = { dir=path, events=noEvents, notifyAddr=backgroundAddr, recursive=true } -- notify-addr is still required, since other entities can also listen to same dir / events..
                app:logV( "Was registered, now excluded, removing/unregistering: ^1", path )
            -- else -- not to be, and isn't..
            end
        end
    end
    local function considerFolderAndChildren( p, f )
        considerFolder( p, f )
        if not inclSet[p] then -- no need to consider children once parent included (recursion is implied when auto-mirroring).
            for i, childFolder in ipairs( f:getChildren() ) do
                --if LrFileUtils.exists( ent ) == 'directory' then
                considerFolderAndChildren( cat:getFolderPath( childFolder ), childFolder )
                --end
            end
        end
    end
    for p, f in pairs( self.catFolderSet ) do -- in catalog, online.
        considerFolderAndChildren( p, f )
    end
    if tab:isEmpty( inclSet ) then
        Debug.pause( "No folders are included and not excluded for mirroring." )
        app:logW( "No folders are included and not excluded for mirroring." )
        self:displayErrorX( { id="noMirrorFolders", immediate=true, prompt=true }, "No mirrored folders - either disable mirroring or define.." )
        app:sleep( 1 ) -- reminder: display-error does not include a holdoff delay.
        if shutdown then return end
        -- note: there may still be upd-recs.
    else
        --Debug.pause( cnt )
        self:clearError( "noMirrorFolders" )
        app:logV( "^1 are included (and not excluded).", str:nItems( tab:countItems( inclSet ), "mirroring folders" ) )
    end
    
    if #recs == 0 then -- no update records for dir-chg app.
        if not noDirChgMsgLogged then
            app:logV( "Mirrored folders holding steady (no updates for dir-chg app)." )
            noDirChgMsgLogged = true
        end
        return
    else
        app:log( "Got ^1 to register/un-register.", str:nItems( #recs, "folders" ) )
        --Debug.lognpp( recs )
        noDirChgMsgLogged = false
    end

    --Debug.pause( #recs, recs )
    
    app:log( backgroundAddr ) -- notifications go to this address.
    for i, v in ipairs( recs ) do
        if v.events ~= 0 then
            app:log( "Registering for file-system updates: ^1", v.dir )
        else
            app:log( "Unregistering for file-system updates: ^1", v.dir )
        end
    end

    -- reminder: recs exist at this point, but may consist of a combo of reg and un-reg records.
    -- note: when mirroring, force-scan is contingent upon registration, when ad-hoc it's not. I think it's OK, but it's different.
    -- it assures lengthier (or so was the design/intent anyway) mirror scans are not repeated when mirroring is repeatedly failing,
    -- but instead displays error - I dunno..: I can argue either side...
    local s, m = dirChgApp:register( recs, 10, "Background" ) -- package as message and send to notify app, 10-sec tmo (same as default).
    if s then
        self:clearError( "UnableToRegister" )
        app:log( "Registered background task for dir-changes to support auto-mirroring." )
        -- do a baseline scan of added folders: (essentially wherever we have positive registration for changes, it should be followed by a baseline scan).
        if tab:is( added ) then
            local spec = tab:copy( self.mirrorSpec ) -- mirror-spec is expected to stay with folder=nil for now, so make shallow copy for auto-importing (baseline scan) here.
            -- note: we don't want background task to be cancelable, so do force-scan in a separate context
            app:pcall{ name="Auto-mirror Baseline Scan", async=false, progress=true, function( icall ) -- note: this scan will interfere with auto-import upon folder-sel,
                -- which I'm not too crazy about - really they should be separate tasks, instead of shared task (but my background object is a shared task - hmm..).
                -- beware - making it async will be a problem unless I protect critical data structure: 'added' table.
                -- note: I could use modal progress scope, so user doesn't select folders and wonder why they're not auto-importing - but yuck.
                for path, folder in pairs( added ) do
                    spec.folder = folder -- affects scan, but not mirror-spec
                    spec.call = icall -- auto-mirror upon folder sel will be held up, but at least not without some clue in the p.scope.
                    local s, m = LrTasks.pcall( OttomanicImporter._autoImport, ottomanic, spec ) -- synchronous.
                    if spec.call:isQuit() then break end
                    if s then
                        app:log( "Baseline scan (auto-mirror) of folder '^1' completed successfully.", path )
                    else
                        app:logW( "Baseline scan (auto-mirror) of folder '^1' did NOT complete successfully - ^2.", path, m )
                    end
                end
            end }
        end
    else
        -- could just clear all, but other tasks are still looking at this structure to decide whether there is interference etc.
        app:logW( "Dirs not registered for background task (auto-mirroring) - ^1", m )
        self:displayErrorX( { id="UnableToRegister", immediate=false, prompt=true }, "Unable to register for dir-chg app notifications..." )
        -- remove those added
        for path, _t in pairs( added ) do
            self.mirrorPaths[path] = nil
        end
        -- re-add those removed:
        for path, _t in pairs( removed ) do
            self.mirrorPaths[path] = self.mirrorSpec
        end
        -- mirror paths should be same now as last time successfully registered, if ever that had happened.
    end

end



--- Background processing method.
--
--  @usage for auto-import *selected folder(s)* (including interval emulation), and maintaining mirror path/specs registration, and initial auto-mirror force scan.
--
--  @param      call object - usually not needed, but its got the name, and context... just in case.
--              <br>    this is the original background call passed to init function which never changes
--              <br>    also available as background table member.
--
function ExtendedBackground:process( call )

    if not app:getGlobalPref( 'autoImportEnable' ) then
        return
    end
    
    assert( self.call and call == self.call, "call mixup" )

    if app:getPref( 'autoMirrorFolders' ) then -- change this to auto-import
        self:_autoMirrorFolders() -- side effects: updates self.mirrorPaths
    end

    if app:getPref( 'autoImportSelFolder' ) then
        self:_autoImportSelFolder() -- gives priority to auto-mirroring, or other auto-importing, if defined.
    end

    
end
    


return ExtendedBackground
