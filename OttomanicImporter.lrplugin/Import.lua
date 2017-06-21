--[[
        Import.lua
--]]


local Import, dbg, dbgf = Object:newClass{ className="Import", register=true }



--- Constructor for extending class.
--
function Import:newClass( t )
    return Object.newClass( self, t )
end



--- Constructor for new instance.
--
function Import:new( t )
    local o = Object.new( self, t )
    -- auto may be specified, but is optional when import only needed to support UI (no real importing to be done with it).
    o.spec = { auto=false } -- cheap insurance, to keep self-log from croaking.
    o:initImportExt( o.importExt )
    return o
end



-- assure logger is not overrun when continuously auto-importing without benefit of dir-chg app, i.e. auto-import upon folder sel.
function Import:log( fmt, ... )
    if self.spec.auto and self.spec.auto=="Auto-import Selected Folder" and app:getPref( 'autoImportSelFolderCont' ) and ( app:getPref( 'autoImportSelFolderInterval' ) > 0 ) and not app:isAdvDbgEna() then
        return
    else -- manual mode, or adv dbg ena.
        app:log( fmt, ... )
    end
end
function Import:logv( fmt, ... )
    if self.spec.auto and self.spec.auto=="Auto-import Selected Folder" and app:getPref( 'autoImportSelFolderCont' ) and ( app:getPref( 'autoImportSelFolderInterval' ) > 0 ) and not app:isAdvDbgEna() then
        return
    else -- manual mode, or adv dbg ena.
        --app:log( fmt, ... ) -- through 4.3.1
        app:logV( fmt, ... ) -- after 5/Jun/2014 7:26 (not yet released ### - probably won't be until v5.0)
    end
end
Import.logV = Import.logv



--  Initialize or refresh import extensions.
--  Call if possible that pref backing file has changed,
--  or import-ext not passed to constructor.
function Import:initImportExt( importExt )
    importExt = importExt or self.importExt or app:callingError( "no import ext" )
    local function getSet( tbl )
        if #tbl > 0 then -- old-style settings.
            return tab:createSet( tbl ) -- will have dead entries corresponding to lower case extensions, but that's ok.
        else -- new-style (better not try and mix styles ;-})
            return tbl
        end
    end
    if importExt then
        self.importExt = importExt
        self.rawImportExt = getSet( self.importExt.raw )
        self.rgbImportExt = getSet( self.importExt.rgb )
        self.videoImportExt = getSet( self.importExt.video )
    else
        self.rawImportExt = {}
        self.rgbImportExt = {}
        self.videoImportExt = {}
    end    
end



--- Get type of support configured for specified extension.
--
--  @usage requires import-ext init.
--
function Import:getSupportType( ext )
    assert( self.importExt, "not init" )
    if not str:is( ext ) then
        if ext == nil then
            app:callingError( "pass ext param" )
        else -- maybe file has no extension - treat same as un-registered extension.
            return nil
        end
    end
    local uext = LrStringUtils.upper( ext )
    if self.rawImportExt[uext] then
        return "raw", 1 -- Raw
    elseif self.rgbImportExt[uext] then
        if str:isEqualIgnoringCase( uext, 'JPG' ) then
            return "rgb", 2 -- Jpeg
        elseif str:isEqualIgnoringCase( uext, 'GIF' ) then
            return "rgb", false -- cheating-ish.
        else
            return "rgb", 3 -- Other
        end
    elseif self.videoImportExt[uext] then
        if type( self.videoImportExt[uext] ) == 'table' then
            return "video", self.videoImportExt[uext] -- custom transcoded video case.
        elseif type( self.videoImportExt[uext] ) == 'boolean' then -- true.
            return 'video' -- normal Lr video import case.
        else
            app:error( "invalid video import ext - should be boolean or table, not '^1'", type ( self.videoImportExt[uext] ) )
        end
    else
        --Debug.pause( "not supported ext", ext )
        return nil
    end
end



--- Called to initialize settings, once custom set has been determined, along with ctexts & start-num (generally from UI, or saved prefs...).
--
--  @param custom settings as read from prefs.
--  @param txt1 custom text value #1.
--  @param txt2 custom text value #2.
--  @param noLog (auto-importing, so will be called repetitively - log accordingly...).
--
--  @usage called when spec is created.
--  @usage keyword cache should be initialized before calling.
--  @usage One goal of this function is to check whether all members of structured settings are present, so they don't need to be rechecked ad-infinitum each photo that is imported.
--
function Import:initSettings( custom, txt1, txt2, noLog )
    assert( custom.customSetName, "no custom set name" )
    local c = { customSetName = custom.customSetName } -- settings out - to be returned.
    local seen = { customSetName = true } -- tracks which settings have been initialized by this function. If there are custom settings remaining that have not been seen, that fact will be logged, since it may represent a typo in the custom settings. It may also represent a setting only used internally, so no error necessarily...
    -- logging wrapper functions which may repress logs in case of repetitive auto-importing (selected folders), to keep from over-running the logger...
    local function log( fmt, ... )
        if not noLog then
            app:log( fmt, ... )
        end
    end
    local function logv( fmt, ... )
        if not noLog then
            app:logv( fmt, ... )
        end
    end
    log()
    log( "Import settings (^1)", custom.customSetName )
    log( "---------------" )
    -- Initializes one named setting - if present in custom settings, it is simply stored in output settings - if not, the default is stored instead - either way, it'll be considered seen.
    local function init( n, dflt )
        seen[n] = true
        if custom[n] == nil then
            if type( dflt ) == 'table' then
                log( "^1 not specified in custom settings, defaulting to a table of values...", n )
            else
                log( "^1 not specified in custom settings, defaulting to ^2", n, str:to( dflt ) )
            end
            c[n] = dflt
        else
            if type( custom[n] ) == 'table' then
                log( "^1: there are multiple values...", n ) -- ###3: room for improvement.
            elseif type( custom[n] ) == 'function' then
                log( "^1: a custom function will be providing...", n )
            else
                log( "^1: '^2'", n, str:to( custom[n] ) )
            end
            c[n] = custom[n]
        end
    end
    -- default for import destination subdir of user's home, for lack of a better place - at least one can try exporting before changing to a better location.
    local userDir = LrPathUtils.getStandardFilePath( 'home' )
    init( 'promptForCustomDirText', nil )
    init( 'initSession', nil )
    init( 'initSource', nil )
    init( 'initPhoto', nil )
    init( 'initFile', nil )
    init( 'initTarget', nil )
    init( 'endPhoto', nil )
    init( 'endSession', nil )
    init( "importExt", { raw={ ["NEF"]=true, ["CR2"]=true }, rgb={ ["JPG"]=true }, video = { ["MOV"]=true, ["AVI"]=true } } )
    init( "denyIfDupFilename", false )
    init( 'importCriteria', nil )
    init( "backups", nil )
    -- assure backup spec has name & folder, at a minimum (folder will be created on demand).
    for i, v in ipairs( c.backups or {} ) do
        app:assert( v.name, "no backup name" )
        app:assert( v.folder, "no backup folder" )
    end
    -- develop preset names do not use standard init function, since they require special handling (translation of preset-names into actual presets).
    if custom.developPresetNames ~= nil then
        seen["developPresetNames"] = true
        repeat
            local presets = {}
            if type( custom.developPresetNames ) == 'string' then
                presets = { custom.developPresetNames }
            elseif type( custom.developPresetNames ) == 'table' then
                presets = custom.developPresetNames
            else
                app:error( "dev preset names should be string or table" )
            end
            c.devPresets = {}
            c.devPresetLookup = {}
            for i, presetName in ipairs( presets ) do
                if type( presetName ) == 'string' then
                    local devPreset = developSettings:getUserPreset( presetName ) -- inits dev preset cache upon first use, but be sure to init earlier if need be.
                    if devPreset then
                        log( "Develop settings preset: ^1", devPreset:getName() )
                        c.devPresets[#c.devPresets + 1] = devPreset
                        c.devPresetLookup[presetName] = devPreset
                    else
                        app:error( "Develop settings preset does not exist: '^1' - you may need to refresh, or reload this plugin (or restart Lightroom)", presetName )
                    end
                elseif type( presetName ) == 'number' then
                    c.devPresets[#c.devPresets + 1] = presetName -- delay number in seconds (not much point in having it in the lookup).
                else
                    error( "bad preset spec type" )
                end
            end
        until true
    else
        log( "No develop preset specified." )
    end
    init( "emulateCameraSettings", nil ) -- don't emulate, unless user has explicitly enabled.
    init( "applyDevelopPresets", nil ) -- use default function for applying develop presets.
    init( "extCase", "Same Case" )
    init( "importType", "Copy" ) -- Copy - consider a different default for auto-imports ###3 problem is: "Add" would be a bad default for card import.
        -- really this shouldn't matter, since import-type should be provided in default config anyway.
    init( "importDestFolderPath", LrPathUtils.child( userDir, "Pictures Imported in Lightroom" ) )
    -- note: custom (input) keywords are strings, but output keywords are LrKeyword objects - cache initialized upon first use, if need be.
    init( "removeKeywords", nil )
    if custom.keywords then -- 
        seen["keywords"] = true
        local keywordStrings
        if type( custom.keywords ) == 'string' then
            keywordStrings = { custom.keywords }
        elseif type( custom.keywords ) == 'table' then
            keywordStrings = custom.keywords
        else
            app:error( "bad keywords" )
        end
        c.keywords = {}
        for i, ks in ipairs( keywordStrings ) do
            if str:is( ks ) then
                if str:getFirstChar( ks ) == "/" then -- ###2 use new keywords method if can figure out how to start/stop init.
                    local kw = keywords:getKeywordFromPath( ks, false ) -- although keywords are expected to exist, cache is also expected to have been reinitialized prior.
                    if kw then
                        c.keywords[#c.keywords + 1] = kw
                    else
                        app:error( "bad keyword: ^1", ks )
                    end
                else
                    app:error( "Keywords must be full path, begininning with '/' - '^1' needs to be corrected.", ks )
                end
            else
                app:error( "Blank keyword" )
            end
        end
    else
        log( "No keywords specified." )
    end
    init( "applyKeywords", nil )
    if custom.metadataPresetNames then
        repeat
            seen["metadataPresetNames"] = true
            local presetNames
            if type( custom.metadataPresetNames ) == 'string' then
                if custom.metadataPresetNames ~= "" then
                    presetNames = { custom.metadataPresetNames }
                end
            elseif type( custom.metadataPresetNames ) == 'table' then
                 presetNames = custom.metadataPresetNames
            else
                app:error( "bad metadata preset names" )
            end
            c.metadataPresetIds = {}
            if #presetNames == 0 then
                break
            end
            local metaPresets = LrApplication.metadataPresets()
            local lookup = {}
            for name, id in pairs( metaPresets ) do
                lookup[name] = id
            end
            for i, presetName in ipairs( presetNames ) do
                if lookup[presetName] then -- exists/found
                    c.metadataPresetIds[#c.metadataPresetIds + 1] = lookup[presetName]
                else
                    app:logError( "metadata preset does not exist: ^1", presetName )
                end
            end
            if #c.metadataPresetIds > 0 then
                if #c.metadataPresetIds == 1 then
                    log( "Metadata preset: ^1", c.metadataPresetIds[1] )
                else
                    log( "Metadata presets: ^1", #c.metadataPresetIds )
                end
            else
                app:error( "At least one metadata preset does not exist" )
            end
        until true
    else
        log( "No metadata preset specified." )
    end
    init( "applyMetadataPresets", nil ) -- use default function for applying metadata presets.
    if custom.exportPresetNames then
        repeat
            seen["exportPresetNames"] = true
            local presetNames
            if type( custom.exportPresetNames ) == 'string' then
                if custom.exportPresetNames ~= "" then
                    presetNames = { custom.exportPresetNames }
                end
            elseif type( custom.exportPresetNames ) == 'table' then
                 presetNames = custom.exportPresetNames
            else
                app:error( "bad export preset names" )
            end
            c.exportPresetFiles = {}
            if #presetNames == 0 then
                break
            end
            for i, presetName in ipairs( presetNames ) do
                if str:is( presetName ) then -- value exists on line
                    if LrFileUtils.exists( presetName ) then -- exists/found
                        c.exportPresetFiles[#c.exportPresetFiles + 1] = presetName -- misnomer: file-path, not preset name.
                    else
                        app:logError( "export preset does not exist: ^1", presetName )
                    end
                -- else ignore lines without an entry.
                end
            end
            if #c.exportPresetFiles > 0 then
                if #c.exportPresetFiles == 1 then
                    log( "Export preset: ^1", c.exportPresetFiles[1] )
                else
                    log( "Export presets: ^1", #c.exportPresetFiles )
                end
            else
                app:error( "At least one export preset does not exist" )
            end
        until true
    else
        log( "No export preset specified." )
    end
    c.customText_1 = txt1 or "" -- in settings
    c.customText_2 = txt2 or "" -- ditto.  ###3 if user really wants dynamic custom text, they can always implement it in config file.

    self:initDfltSeqNums()
    
    init( "verifyBackupFileContents", false )
    init( "verifyImportedFileContents", false )
    init( "utcOffsetInSeconds", nil )
    
    --[[ obs
    local dngSettings = custom.convertToDngAddlOptions
    seen["convertToDngAddlOptions"] = true
    if dngSettings == nil then
        c.dngOptions = { raw="" }
    elseif type( dngSettings ) == 'string' then
        c.dngOptions = { raw=dngSettings }
    elseif type( dngSettings ) == 'table' then
        c.dngOptions = dngSettings
    else
        error( "bad type" )
    end
    --]]

    -- new:    
    init( "convertToDngOptions", {{enableConv=false},{enableConv=false},{enableConv=false}} )
    if c.convertToDngOptions[2].enableConv then
        app:error( "Jpeg conversion to dng will be supported as soon as Adobe updates their dng converter documentation - sorry." )
    end
    if c.convertToDngOptions[3].enableConv then
        app:error( "Conversion of rgb files to dng will be supported as soon as Adobe updates their dng converter documentation - sorry." )
    end

    init( "importMoveToTrash", false )
    init( "exifToolSession", nil )
    init( "deleteCopiedFileSourcesAfterImport", 'no' )
    init( "ejectCards", false )
    
    --init( "getNewFilePath", nil )
    init( "foldernameSpec", nil )
    init( "filenameSpec", nil )
    init( "videoFoldernameSpec", nil )
    init( "videoFilenameSpec", nil )
    init( "getImportDestinationSubfolder", nil )
    init( "getNewFilename", nil )
    
    init( "importProtectedOnly", nil )
    init( "readOnlyFileAttribute", '' ) -- ignore
    init( "readOnlyPhotoMetadata", nil ) -- do not apply.
    
    init( "grandFinale", nil ) -- none.
       
    local unseen = 0
    for k, v in pairs( custom ) do
        if seen[k] then
            -- good
        else
            app:logv( "Unregistered configuration setting (being kept - assumed for use within advanced settings file only): '^1'", k )
            c[k] = v -- must be kept, otherwise users can't define stuff in settings for internal use.
            unseen = unseen + 1
        end
    end
    local uninit = 0
    for k, v in pairs( seen ) do
        if custom[k] ~= nil then
            -- good
        else
            app:logv( "Uninitialized (or initialized to nil) configuration setting: '^1'", k )
            uninit = uninit + 1
        end
    end
    log()
    if unseen > 0 then
        if app:isVerbose() and app:isAdvDbgEna() then
            app:logWarning( "There are ^1 unregistered settings in the configuration - please check and correct if need be...", unseen ) -- not kosher: user may want to add settings for internal use.
        end
        --app:error( "there are unregistered settings in the configuration - please check and correct..." ) -- not kosher: user may want to add settings for internal use.
    end        
    if uninit > 0 then
        if app:isVerbose() and app:isAdvDbgEna() then
            app:logv( "There are ^1 uninitialized (or initialized to nil) settings in the configuration.", uninit ) -- not kosher: user may want to add settings for internal use.
        end
        --app:error( "there are unregistered settings in the configuration - please check and correct..." ) -- not kosher: user may want to add settings for internal use.
    end        
    
    return c
end



--- Initializes an import session (run).
--
--  @usage presently called by otto when creating the import spec.
--  @usage presumes all other init's have been done already.
--  @usage possible this could be integrated with other init methods...
--
function Import:initSession( spec )
    if not self.importExt then
        app:callingError( "Init import ext" )
    end
    --Debug.lognpp( "initSession spec", spec ) -- lotsa juicy info here, but may also include huge binary ets response.
    local settings = spec.settings or error( "no settings in spec" )
    if settings.initSession then
        if type( settings.initSession ) == 'function' then
            settings.initSession( spec )
        else
            app:error( "bad init sesn" )
        end
    end
    assert( spec.auto ~= nil, "specify auto in spec" )
    self.spec = spec

    -- initialize explicitly all default sequence numbers for this session.
    self:setSeqNum( 'session', 'item', 1 )
    self:setSeqNum( 'session', 'photo', 1 )
    self:setSeqNum( 'session', 'video', 1 )
    self:setSeqNum( 'source', 'item', 1 )
    self:setSeqNum( 'source', 'photo', 1 )
    self:setSeqNum( 'source', 'video', 1 )
    self:setSeqNum( 'target', 'item', 1 )
    self:setSeqNum( 'target', 'photo', 1 )
    self:setSeqNum( 'target', 'video', 1 )
    local sessionName
    local returnExisting = false
    if spec.auto then
        if type( spec.auto ) == 'boolean' then -- ad-hoc temp/perm.
            sessionName = spec.folder:getName() -- name session after folder.
            app:logV( "Initializing new exif-tool session for folder: ^1", sessionName )
        else -- string name - auto-import sel-folder.
            sessionName = spec.auto
            self:logV( "Initializing new (or reusing existing) exif-tool session for service: ^1", sessionName )
            returnExisting = true
        end
    else
        app:logV( "Initializing new exif-tool session for manual import." )
        sessionName = "Manual Import"
    end
    if settings.exifToolSession then
        if returnExisting then
            self.ets = exifTool:openSession( sessionName, nil, returnExisting ) -- no config file (no need).
        else
            if exifTool:isSessionOpen( sessionName ) then
                return false, str:fmtx( "import already in-progress, session name: ^1", sessionName )
            else
                self.ets = exifTool:openSession( sessionName, nil, returnExisting ) -- no config file (no need).
            end
        end
    end
    self.sessionName = sessionName
    self.record = {}    
    spec.import = self
    self.stats = Call:newStats {
        -- slightly presumptuous, but those unused don't hurt and external context can always add specials..
        -- note: although importer will bump these stats, there is a different copy for each call: i.e. auto-import or manual "session".
        'considered',
        'imported',
        'alreadyInCatalog',
        'excluded',
    }
    return true
end



function Import:getSessionName()
    return self.sessionName or "no name - session not init"
end



--- Initialize for source change.
--
--  @usage called each time import shifts to a different card, or other location.
--  @usage can be used for card-specific or auto-importing folder-specific sequence numbers.
--  @usage could also be used to prompt for custom source-specific folder-naming text...
--
function Import:initSource( spec )
    self:setSeqNum( 'source', 'item', 1 )
    self:setSeqNum( 'source', 'photo', 1 )
    self:setSeqNum( 'source', 'video', 1 )
    local settings = spec.settings or error( "no settings" )
    if settings.initSource then
        if type( settings.initSource ) == 'function' then
            settings.initSource( spec )
        else
            app:error( "bad init source" )
        end
    end
end



--- Initialize for target change.
--
--  @usage called each time import shifts to a different destination location.
--  @usage can be used for card-specific or auto-importing folder-specific sequence numbers.
--
function Import:initTarget( spec )
    self:setSeqNum( 'target', 'item', 1 )
    self:setSeqNum( 'target', 'photo', 1 )
    self:setSeqNum( 'target', 'video', 1 )
    local settings = spec.settings or error( "no settings" )
    if settings.initTarget then
        if type( settings.initTarget ) == 'function' then
            settings.initTarget( spec )
        else
            app:error( "bad init target" )
        end
    end
end



--- Called at end of source - @12/Nov/2012 22:06 - not used.
--
function Import:endSource( spec )
end
--- Called at end of target - @12/Nov/2012 22:06 - not used.
--
function Import:endTarget( spec )
end



--- Called when import session is complete (manual import, or auto-import stopped or canceled.
--
--  @usage only purpose so far is to close exiftool session, but could be used to store continuing sequence numbers...
--
function Import:endSession( spec )
    --Debug.pause( "ending session" )
    exifTool:closeSession( self.ets )
    if spec == nil then -- this is possible when session ends abnormally.
        app:logv( "Ending session sans spec" )
        return
    end
    local settings = spec.settings
    if settings.endSession then
        if type( settings.endSession ) == 'function' then
            settings.endSession( spec )
        else
            app:error( "bad init target" )
        end
    --else nada
    end
end



function Import:considerGrandFinale( call, prompted )
    local spec = call.spec or error( "no spec in call" )
    local settings = spec.settings or error( "no settings in spec" )
    assert( prompted ~= nil, "prompted nil 4" )
    if settings.grandFinale then
        local s, m = settings.grandFinale {
            record = self.record,
            spec = spec,
            prompted = prompted,
        }
        if s then
            app:log( "Custom grand finale function returned affirmative status." )
        else
            app:logErr( m )
        end
    end    
end



--- Called when manual import session is nearing completion - to give user a chance to delete after importing...
--
function Import:considerDeletingSources( call )
    local spec = call.spec or error( "no spec in call" )
    local settings = spec.settings or error( "no settings in spec" )
    local prompt = settings.deleteCopiedFileSourcesAfterImport or 'ask'
    local prompted = false -- must not be nil.
    if spec.settings.importType == 'Copy' then
        if tab:isEmpty( self.record ) then
            app:log( "No files to delete." )
            return prompted
        end
        local del = {}
        if prompt == 'ask' then
            app:log()
            app:log()
            app:log( "Files being considered for deletion, subject to your approval: " )
            app:log( "-------------------------------------------------------------- " )
            for i, rec in ipairs( self.record ) do
                if fso:existsAsFile( rec.file ) and fso:existsAsFile( rec.newFile ) then
                    del[#del + 1] = rec.file
                    app:log( rec.file )
                end
            end
            app:initGlobalPref( 'fiddleTime', 3 ) -- I want this short as default, so user knows what's happening fairly quickly the first time - he/she can always increase.
            app:log()
            repeat
                call:setCaption( "Dialog box needs your attention..." )
                local button = app:show{ confirm="Delete ^1 (as shown in log file)?",
                    subs = str:nItems( #del, "imported files" ),
                    accItems = {
                        vf:push_button {
                            title = "Dismiss for",
                            action = function( button )
                                LrDialogs.stopModalWithResult( button, 'fiddle' )
                            end,
                            tooltip = "Click this button to dismiss this dialog box temporarily, so you can check integrity of imported photos in Lightroom (they should have no \"faulty rectangles\" in them) - make sure previews represent Lr's rendering of raw data, not just embedded previews.",
                        },
                        vf:edit_field {
                            bind_to_object = prefs,
                            value = app:getGlobalPrefBinding( 'fiddleTime' ),
                            width_in_digits = 2,
                            precision = 0,
                            min = 1,
                            max = 99,
                            tooltip = "Enter estimated time you will need to scroll through all the imported thumbs and check them.",
                        },
                        vf:static_text {
                            title = "seconds",
                        },
                        vf:spacer {
                            width = 5,
                        },
                    },
                    buttons = { dia:btn( "Yes - Delete Files", 'ok' ), dia:btn( "Show Log File", 'other' ), dia:btn( "No", 'cancel' ) },
                    -- actionPrefKey = "Delete files",
                }
                prompted = true
                if button == 'ok' then
                    break
                elseif button == 'other' then
                    app:showLogFile()
                elseif button == 'cancel' then
                    app:log( "*** Files NOT deleted." )
                    return prompted
                elseif button == 'fiddle' then
                    local remaining = app:getGlobalPref( 'fiddleTime' ) or 3
                    app:sleep( remaining, 1, function()
                        remaining = remaining - 1
                        call:setCaption( "Dialog will reappear in ^1", str:nItems( remaining, "seconds" ) )
                    end )
                    if shutdown then return prompted end
                else
                    app:error( "pgm fail" )
                end
            until false
        elseif prompt == 'no' then
            app:logv( "Not deleting sources despite import behavior being 'Copy'" )
            return prompted
        elseif prompt == 'yes' then
            -- just do it
            for i, rec in ipairs( self.record ) do
                if fso:existsAsFile( rec.file ) and fso:existsAsFile( rec.newFile ) then
                    del[#del + 1] = rec.file
                end
            end
        else
            app:logWarning( "Invalid value for 'deleteCopiedFileSourcesAfterImport' in customization set - files not deleted." )
            return prompted
        end
        assert( prompt == 'ask' or prompt == 'yes', "bad prompt" )
        call:setCaption( "Deleting files" )
        app:log()
        app:log()
        app:log( "Files deleted: " )
        app:log( "-------------" )
        local yc = 0
        for i, file in ipairs( del ) do
            call:setPortionComplete( i - 1, #del )
            yc = app:yield( yc )
            local s, m = fso:deleteFile( file )
            if s then
                app:log( file )
            else
                app:logWarning( m ) -- errm is complete.
            end
            if call:isQuit() then
                return prompted
            end
        end        
        app:log()
        call:setPortionComplete( 1 )
        call:setCaption( "" )
        
    else
        app:logv( "Not deleting sources since import behavior is not 'Copy'" )
    end
    assert( prompted ~= nil, "prompted nil" )
    return prompted
end



-- ###3 another thing: if user has "Treat jpeg next to raw separately" *un*-checked, then the jpegs may not be handled correctly.
-- Actually, what happens is: you get jpg and nef+jpg both. Not really a problem, per say, but not great either... I mean, user can control
-- by changing the Lr pref or custom set, but still - not great... (at *least* document). I could implement my own version of RAW+JPG handling.



--- Factory default import backup function.
--
--  @usage Called by default if not overridden in user config - can also be called from user config backup function.
--
function Import:backup( params )
    local backup = params.backup or error( "no backup" )
    local folder = backup.folder or error( "no folder" )
    local file = params.file or error( "no file" )
    local newFile = params.newFile or error( "no new file" )
    local spec = params.spec or error( "no spec" )
    local call = spec.call or error( "no call" )
    local settings = spec.settings or error( "no settings in spec" )
    local ext = LrPathUtils.extension( file )
    
    local supportType, other = self:getSupportType( ext )
    
    local filename = LrPathUtils.leafName( newFile ) -- backup as renamed: if user wants original name, they can provide custom backup function.
    if supportType == 'video' then
        if other then
            filename = LrPathUtils.replaceExtension( filename, ext ) -- ###3 @3/Sep/2013 3:19 - not sure why this isn't just always done (except for performance reasons).
        else -- for backup purposes, no special handling - source video to be backed up with new name and extension.
        end
    else -- photo
        if other then -- extension capable of supporting dng conversion.
            local dngOptions = settings.convertToDngOptions[other] or app:error( "no dng support for index ^1", other )
            app:assert( dngOptions.enableConv ~= nil, "enable-conv not init" )
            if dngOptions.enableConv then
                filename = LrPathUtils.replaceExtension( filename, ext ) -- renamed body, but original extension. Again, consider other options...
            else
                --Debug.pause( "dng not enabled", filename, ext )
            end
        elseif other ~= nil then -- false => gif.
            filename = LrPathUtils.replaceExtension( filename, ext )
        else
            -- ok as is
            --Debug.pause( "no dng support index", ext )
        end
    end
    
    local backupFile = LrPathUtils.child( folder, filename )
    --app:logv( "Backing up to: ^1", backupFile )

    local s, m = fso:copyFile( file, backupFile, true, true, false, nil, call, "Backing up" ) -- create dir if need be, overwrite without warning, update regardless, validation is a don't care.
    if s then -- explicit validation (copy-file only supports pre-check to avoid unncessary update, it does not support after-the-fact validation.
        if fso:isFileSame( file, backupFile, not settings.verifyBackupFileContents ) then -- if not verifying contents, then time-stamp is enough.
            app:log( "backup copy to '^1' - created & verified", backupFile ) -- source already logged.
        else
            app:error( "backup copy created, but does not match original - consider drive/reader has failed..." )
        end
    else
        app:error( "Unable to create backup copy - ^1", m )
    end
end



--  only called if settings-backups table is non-empty.
--  reminder: settings pre-checked upon init, no need here.
function Import:_backup( file, newFile, spec )
    local settings = spec.settings or error( "no settings" )
    for i, v in ipairs( settings.backups ) do
        app:log()
        app:log( "Doing backup '^1'", v.name or "unnamed" )
        local params = {
            backup = v,
            file = file,
            newFile = newFile,
            spec = spec,
        }
        if v.backupHandler then
            v.backupHandler( params )
        else
            self:backup( params )
        end
    end
end



--- Gets exiftool-powered metadata corresponding to importing photo.
--
--  @usage supports file naming and custom locations implemented in advanced settings.
--  @usage exif obtained via '-S' param, i.e. "name: value" text.
--  @usage some of the text values can be further parsed using exifTool object's parse methods, e.g. parseDateTime.
--  @usage sets and restores caption whilst getting metadata, if call object has a scope that is.
--
--  @return exif (table, or nil) exif table if any.
--  @return errm (string, or nil) errm if error occurred attempting to get exif metadata.
--
function Import:getExifMetadata( params )
    local exif, errm, cap
    app:callingAssert( params, "no params" )
    app:callingAssert( params.spec, "no spec in params" )
    app:callingAssert( params.spec.call, "no call in params spec" )
    app:pcall{ name="Import - Get Exif Metadata", main=function( call ) -- wrap just in case.
        cap = params.spec.call:setCaption( "Getting exif metadata: ^1", self.ets:getName() )
        local rslt, em
        if self.ets == nil then
            app:logv( "*** Using exiftool explicitly instead of an exif-tool session - it is more efficient, and therefore preferred to define exifToolSession in your import settings." ) -- purpose is to be able to check version and log...
            local sts, cmdOrMsg, data = exifTool:executeCommand( "-S", { params.file }, nil, 'del' )
            if sts then
                app:logv( "Got exif metadata via command: ^1", cmdOrMsg )
                rslt = data
            else
                error( cmdOrMsg )
            end
        else
            local file = params.file or error( "no file" )
            self.ets:addArg( "-S" )
            self.ets:addTarget( file )
            rslt, em = self.ets:execute() -- throws error? (presently ignoring other return values)
            if str:is( em ) then
                local ext = LrPathUtils.extension( file )
                if str:isEqualIgnoringCase( ext, "gif" ) then
                    app:logW( "Unable to get exif metadata for gif file (^1) - ^2", file, em )
                    return
                else
                    app:error( em )
                end
            elseif not str:is( rslt ) then
                --app:error( "No exif metadata" ) - not necessarily an error (although often is).
                Debug.pause( "There is no metadata in", file:sub( -80 ) ) -- was happening for a while due to closed exiftool session.
                return -- if ets returns no error message, then technically, there has been no error - there just isn't any metadata (it's possible).
            end
        end
        exif = exifTool:parseShorty( rslt ) -- -S format response.
        if tab:isNotEmpty( exif ) then
            app:logv( "Got exif metadata from '^1'.", params.file )
        else
            app:logWarning( "No exif metadata parsed." )
        end
    end, finale=function( call )
        if not call.status then
            errm = call.message
            exif = nil -- no doubt redundent...
        end
    end }
    if cap then
        params.spec.call:setCaption( cap )
    end
    return exif, errm
end



--- Get folder number from parent of importing photo.
--
--  @usage supports file naming and custom locations implemented in advanced settings.
--  @usage *** warning: only makes sense if file is in folder with number, i.e. camera card.
--
function Import:getFolderNumber( params )

    local file = params.file or error( "no file" )
    local folder = LrPathUtils.parent( file )
    local filename = LrPathUtils.leafName( folder )

    local folderNumStr
    local p1, p2 = filename:find( "[%d]+" )
    if p1 then
        folderNumStr = filename:sub( p1, p2 )
        p1,p2 = filename:find( "[%w]+", p2 + 1 )
        if p1 then
            local folderSuffix = filename:sub( p1, p2 ) -- write-only
            -- _debugTrace( "folder suffix ", folderSuffix )
        else
            -- _debugTrace( "no folder suffix" )
        end
    else
        -- _debugTrace( "no folder num-str" )
    end
        
    return num:getNumberFromString( folderNumStr ) -- may be nil
    
end



--- Parse image number from filename.
--
--  @usage legacy algorithm (until 16/May/2014 4:32): bypass non-numeric prefix, if present, then take next digits.
--      <br> such is fine for IMG_1234-2.JPG, for example, but for 2014-06-01_12-00-00_1234.NEF (OI default): not so much.
--
--  @usage improved algorithm (after 16/May/2014 4:32): take last digit-sequence greater than 3 digits, if any.
--      <br> if not, then take last smaller digit sequence, if any.
--      <br> if not, return nil.
--
--  @usage "new" algorithm (after 2/Jun/2014 2:06): take last digit-sequence which fits constraints (I suppose it could be set up to take first image number, e.g. if user had previously output a sequence number for purpose of ordering, but such is not supported, yet ###3).
--
--  @return number (not string) or nil if no image number parsed.
--
function Import:getFileNumber( params )
    local file = params.file or error( "no file" )
    local filename = LrPathUtils.leafName( file )
    if app:getPref( 'useNewFilenameNumberParsing' ) then -- option added 2/Jun/2014
        return tonumber( str:getImageNumStr( filename, app:getPref( 'filenameNumMinLen' ), app:getPref( 'filenameNumMaxLen' ), app:getPref( 'filenameNumAtFront' ) ) ) -- system settings.
    end
    -- handling prior to v4.3:
    local ddd = {}
    local dd = {}
    for d in filename:gmatch( "[%d]+" ) do
        if #d >= 3 then
            ddd[#ddd + 1] = d
        else
            dd[#dd + 1] = d
        end
    end
    if #ddd > 0 then -- take bigger sequence if available
        return tonumber( ddd[#ddd] )
    elseif #dd > 0 then
        return tonumber( dd[#dd] )
    else
        return nil
    end
end
--[[ uncomment if you need legacy file-number support - before v4.X(?)
function Import:getFileNumber( params )
    local file = params.file or error( "no file" )
    local filename = LrPathUtils.leafName( file )
    local fileNumStr
    local p1, p2 = filename:find( "[%a_]*" )
    if p1 then
        local filePrefix = filename:sub( p1, p2 ) -- writ-only
        -- _debugTrace( "filename prefix ", filePrefix )
    else
        -- _debugTrace( "no filename prefix" )
        p2 = 0
    end
    p1, p2 = filename:find( "[%d]+", p2 + 1 )
    if p1 then
        fileNumStr = filename:sub( p1, p2 )
    else
        -- _debugTrace( "no filename num-str" )
    end
    return num:getNumberFromString( fileNumStr ) -- may be nil.
end
--]]





function Import:_copyOrMove( file, newFile, spec, move )
    local call = spec.call or error( "no call" )
    local settings = spec.settings or error( "no settings" )
    if not move then
        app:log( "Copying ^1", file )
    else
        app:log( "Moving ^1", file )
    end

    assert( spec.card ~= nil, "no card spec" )
    assert( settings.importMoveToTrash ~= nil, "no trash spec" )
        
    local s, m = false, "No new file"
    if newFile then
        -- Disk:copyFile( sourcePath, destPath, createDestDirsIfNecessary, overwriteDestFileIfNecessary, avoidUnnecessaryUpdate, timeCheckIsEnough, call, captionPrefix )
        s, m = fso:copyFile( file, newFile, true, true, false, nil, call, nil ) -- make dirs, overwrite, copy-regardless, no verify, call w/progress-scope, default caption prefix.
        if s then -- explicit validation (copy-file only supports pre-check to avoid unncessary update, it does not support after-the-fact validation.
            app:logv( "copied" ) -- copy-file method now has big-file detection built in.
            if fso:isFileSame( file, newFile, not settings.verifyImportedFileContents ) then -- if not verifying contents, then time-stamp is enough.
                app:log( "File to be imported '^1' - created & verified", newFile ) -- source file already logged
                if move then
                    local trash
                    if settings.importMoveToTrash then
                        if spec.card then
                            app:logv( "Cards don't use trash." )
                            trash = false
                        else
                            trash = true
                        end
                    else
                        trash = false
                    end
                    local s, m
                    if trash then
                        s, m = fso:moveToTrash( file )
                        if s then
                            app:logv( "source moved to trash (maybe) after copy to import destination" )
                        end
                    else
                        s, m = fso:deleteFile( file )
                        if s then
                            app:logv( "deleted source after copy to import destination" )
                        end
                    end
                    if not s then
                        app:logWarning( "Unable to remove original in honor of moving - ^1", m ) -- not gonna blow the deal over it, but worth taking seriously...
                    end
                -- else nada
                end
                
            else
                return false, str:fmtx( "Import copy created, but does not match original - consider drive/reader has failed..." )
            end
        else
            return false, str:fmtx( "Unable to copy or move file - ^1", m )
        end
    end
    return s, m
end





function Import:applyDevelopPresets( params )
    local presets = params.spec.settings.devPresets
    if presets == nil or #presets == 0 then
        app:logv( "No develop presets to apply." )
        return
    end
    local photo = params.photo or error( "no photo" )
    for i, preset in ipairs( presets ) do
        if type( preset ) == 'table' then -- lr-develop-preset
            app:logv( "Applying develop preset" )
            photo:applyDevelopPreset( preset )
            app:log( "Applied develop preset: ^1", preset:getName() )
        elseif type( preset ) == 'number' then -- redundent - type=number pre-validated.
            app:logv( "pausing for ^1 seconds.", preset )
            app:sleep( preset )
            if shutdown then return end
        else
            error( "bad dev preset type" )
        end
    end
end



-- @7/Nov/2012 22:10 only called if settings-init-photo defined.
function Import:_initPhoto( photo, srcFile, newFile, spec, final )
    app:callingAssert( photo, "no photo" )
    local settings = spec.settings or error( "no settings" )
    local params = {
        photo = photo,
        file = newFile, -- for backward compat. (ideally, param member would also be new-file, and src-file would just be file - oh well...).
        srcFile = srcFile, -- added 21/May/2013 18:47.
        spec = spec,
        final = final, -- last phase.
    }
    if settings.initPhoto then
        return settings.initPhoto( params )
    else
        error( "pgm fail" )
    end
end
function Import:_initFile( file, spec )
    local settings = spec.settings or error( "no settings" )
    local params = {
        file = file,
        spec = spec,
    }
    if settings.initFile then
        settings.initFile( params )
    else
        error( "pgm fail" )
    end
end



--  called with catalog access, if dev-preset defined.
function Import:_applyDevelopPresets( photo, file, spec )
    local settings = spec.settings or error( "no settings" )
    local params = {
        photo = photo,
        file = file,
        spec = spec,
    }
    if settings.applyDevelopPresets then
        settings.applyDevelopPresets( params )
    else
        self:applyDevelopPresets( params )
    end
end



function Import:applyMetadataPresets( params )
    local presetIds = params.spec.settings.metadataPresetIds
    if presetIds == nil or #presetIds == 0 then
        app:logv( "No metadata presets to apply." )
        return
    end
    local photo = params.photo or error( "no photo" )
    for i, presetId in ipairs( presetIds ) do
        app:logv( "Applying metadata preset" ) --  to ^1", photo )
        photo:applyMetadataPreset( presetId )
        app:log( "Applied metadata preset" ) -- Beware: May be logged even if failure to occur upon commission of cat update method.
    end
end



--  called with catalog access, if meta-preset defined.
function Import:_applyMetadataPresets( photo, file, spec )
    local settings = spec.settings or error( "no settings" )
    -- assert( settings.metadataPresetIds, "no metadata preset ID" ) - no longer mandatory.
    local params = {
        photo = photo,
        file = file,
        spec = spec,
    }
    if settings.applyMetadataPresets then
        settings.applyMetadataPresets( params )
    else
        self:applyMetadataPresets( params )
    end
end



--- Apply keywords in default fashion.
--
--  @usage keywords (LrKeyword objects at this point) in settings will be applied to photo.
--
function Import:applyKeywords( params )

    local spec = params.spec or error( "no spec" )
    local photo = params.photo or error( "no photo" )
    local settings = spec.settings or error( "no settings" )
    
    if settings.keywords == nil or #settings.keywords == 0 then
        app:logv( "No keywords to apply." )
        return
    end

    app:logv( "Keyword assignments." ) --  to ^1", photo )
    for i, v in ipairs( settings.keywords ) do
        photo:addKeyword( v )
        app:logv( "Added ^1", v:getName() )
    end    
    -- better to look up keywords before embarking...

end


--  called with catalog access, if keywords defined.
function Import:_applyKeywords( photo, file, spec )
    local settings = spec.settings or error( "no settings" )
    local params = {
        photo = photo,
        file = file,
        spec = spec,
    }
    if settings.applyKeywords then
        settings.applyKeywords( params )
    else
        self:applyKeywords( params )
    end
end



--- Get extension for new file to be added to catalog.
--
--  @usage combines import-type with ext-case setting to come up with the answer.
--  @usage called even if adding in place, although usually it's ignored in that case.
--  @usage ext-case is ignored iff adding in place (import-type is add).
--
--  @return ext (string, always returned) else throws error.
--
function Import:getNewExtension( params )
    local file = params.file
    local spec = params.spec
    local settings = spec.settings or error( "no settings" )
    local ext = LrPathUtils.extension( file ) -- not the most efficient.
    local supportAs, other = self:getSupportType( ext )
    local convert
    local baseExt
    local function getExtInSpecifiedCase( newExt )
        if settings.extCase == 'Upper Case' then
            newExt = LrStringUtils.upper( newExt )
        elseif settings.extCase == 'Lower Case' then
            newExt = LrStringUtils.lower( newExt )
        elseif settings.extCase == 'Same Case' then
            -- same     
        else
            app:error( "bad newExt case" )
        end
        return newExt
    end
    if supportAs == 'video' then
        if other then -- it will be table - it's been pre-checked.
            if other.targExt then
                return getExtInSpecifiedCase( other.targExt )
            else
                app:error( "target extension must be in transcoder table" )
            end
        else
            -- normal Lr video support.
        end
    else -- photo
        if other then
            local dngOptions = settings.convertToDngOptions[other] or app:error( "no dng options for index ^1", other )
            app:assert( dngOptions.enableConv ~= nil, "uninit" )
            convert = dngOptions.enableConv
            baseExt = "DNG"
        elseif other ~= nil then -- false => gif.
            convert = true
            baseExt = "PNG"
        end
    end
    local newExt
    if convert then
        if settings.extCase == 'Upper Case' then
            newExt = LrStringUtils.upper( baseExt )
        elseif settings.extCase == 'Lower Case' then
            newExt = LrStringUtils.lower( baseExt )
        elseif settings.extCase == 'Same Case' then
            newExt = LrPathUtils.extension( file )
            if str:isAllUpperCaseAlphaNum( newExt ) then
                newExt = LrStringUtils.upper( baseExt )
            elseif str:isAllLowerCaseAlphaNum( newExt ) then
                newExt = LrStringUtils.lower( baseExt )
            else
                app:logWarning( "input file extension is mixed case - but new extension will be lower case (instead of same case)." )
                newExt = LrStringUtils.lower( baseExt )
            end
            -- return newExt - commented out 10/Jul/2013 14:35
        else
            app:error( "bad ext-case" )
        end
        return newExt -- added 10/Jul/2013 14:35
        -- seems to be a bug when importing DNG with upper/lower case explicitly, since new-ext would be overwritten below.
    end
    -- fall-through => no convert.
    if settings.importType == 'Add' then
        newExt = LrPathUtils.extension( file )
    else
        newExt = getExtInSpecifiedCase( LrPathUtils.extension( file ) )
    end
--    Debug.pause( newExt )
    assert( newExt, "no newExt" )
    return newExt
end



--  Internal function to get new extension - uses callback if defined, else default method.
function Import:_getNewExtension( file, spec )
    local settings = spec.settings or error( "no settings" )
    local params = { file=file, spec=spec }
    if settings.getNewExtension then
        return settings.getNewExtension( params )
    else
        return self:getNewExtension( params )
    end
end



--- Get path for file to be imported.
--
--  @param spec must include settings with getImportDestinationSubfolder, importDestFolderPath, getNewFilename - mandatory (no longer any defaults for them in this module).
--
--  @usage accomplished by getting extension, directory, and filename, then joining them together.
--
function Import:_getNewFilePath( file, spec, ext )
    local settings = spec.settings or error( "no settings" )
    local getImportDestinationSubfolder = settings.getImportDestinationSubfolder -- not mandatory: if no import destination getter is defined, then imported photos will just be put in root import folder.
    local importDestFolderPath = settings.importDestFolderPath or error( "importDestFolderPath must be defined in import settings" )
    local getNewFilename = settings.getNewFilename -- not: or error( "getNewFilename must be defined in import settings" )
    local params = {
        file=file,
        spec=spec,
        ext=ext
    }
    
    local dir
    if getImportDestinationSubfolder then
        dir = getImportDestinationSubfolder( params )
        if str:is( dir ) then
            -- got dir
        else
            app:logWarning( "getImportDestinationSubfolder did not return a directory path" )
            return nil
        end
        dir = LrPathUtils.child( importDestFolderPath, dir )
    else
        dir = importDestFolderPath
    end
    
    local basename
    --Debug.pause( settings.getNewFilename )
    if settings.getNewFilename then
        basename = settings.getNewFilename( params )
    else
        Debug.pause( "get-new-filename is not defined" )
        basename = LrPathUtils.removeExtension( LrPathUtils.leafName( file ) )
    end
    if str:is( basename ) then
        -- *** this is just a test:
        local _ext = LrPathUtils.extension( basename ) -- check if user inadvertently included an extension
        if _ext == ext then
            app:logWarning( "getNewFilename should return base of filename only - extension should not be appended: ^1", ext ) -- not an error necessarily, but probably.
        elseif str:is( _ext ) and self:getSupportType( _ext ) then
            app:logv( "getNewFilename should return base of filename only - no extension should be appended: ^1", _ext ) -- not an error necessarily, but probably.
        end
        local filename = LrPathUtils.addExtension( basename, ext )
        local path = LrPathUtils.child( dir, filename )
        return path
    else
        app:logWarning( "getNewFilename did not return a value." ) -- note: although it is not my vision for this to be a subpath, it could be, and it wouldn't break anything.
        return nil
    end
end



-- Reminder: disk--copy-file now has big-file detection w/progress-scope built in.
function Import:_transferFileToLibrary( file, newFile, spec )
    local settings = spec.settings
    local trouble
    local ext = LrPathUtils.extension( file )
    local supportAs, other = self:getSupportType( ext )
    if supportAs == 'video' then
        if other then -- transcoder table
            if other.transcoder then
                if type( other.transcoder ) == 'function' then
                    app:callingAssert( settings.importType ~= "Add", "Check for import-type 'Add' before calling" )
                    -- copy or move.
                    local s, m = LrTasks.pcall( other.transcoder, { -- usually, in effect, a copy operation, regardless of import spec - such is documented in QA.
                        file = file,
                        newFile = newFile,
                        spec = spec,
                        transcodeTable = other,
                    } )
                    if s then
                        app:logV( "Video was presumably transcoded by custom transcoder function." )
                        return newFile
                    else
                        return false, str:fmtx( "Unable to transcode video using custom transcoder due to error - ^1.", m )
                    end
                else
                    app:error( "transcoder must be function" )
                end
            else
                app:error( "specified transcoder object must be table" )
            end
        else
            -- normal Lr video support - fall through for copy/move.
        end
    else -- photo
        if other then -- ext supports dng conversion.
            local dngOptions = settings.convertToDngOptions[other] or app:error( "no dng options at support-index ^1", other )
            app:assert( dngOptions.enableConv ~= nil, "enable-conv not init" )
            if dngOptions.enableConv then -- convert to dng.
                local addlOptions = dngOptions.dngOptions
                if str:is( addlOptions ) then
                    app:logv( "Explicit DNG options: '^1'", addlOptions )
                else
                    app:logv( "No explicit DNG options, so defaults will prevail." )
                end
                local newFile2, message, content = dngConverter:convertToDng{
                    file = file,
                    dngPath = newFile,
                    addlOptions = addlOptions,
                }
                if newFile2 then
                    assert( newFile == newFile2, "path foul" )
                    app:logv( "Converted to DNG - ^1: ^2", file, newFile ) -- content is nil here.
                    
                    return newFile -- DO NOT FALL THROUGH
                    
                elseif message then
                    if str:is( content ) then -- may or may not be.
                        app:logv( "Dng converter response: ^1", str:limit( content, 500 ) ) -- not sure how long that response might be.
                    end
                    app:error( message )
                else
                    app:error( "program failure" )
                end
            else
                -- fall-through...
            end
        elseif other ~= nil then -- false => gif - notice: gif import only supported by "copy" or "move" (not "add").
            app:assert( LrStringUtils.lower( ext ) == 'gif', "not gif: '^1'", ext )
            local dir = LrPathUtils.parent( newFile )
            local s, m = fso:assureDir( dir )
            if s then
                local s, cmdOrMsg, c = convert:executeCommand (
                    '"' .. file .. '"', -- params (manual wrap)
                    { newFile } -- targets (auto-wrapped).
                )
                if s then
                    app:logv( "Converted GIF to PNG - '^1': '^2' - command: ^3", file, newFile, cmdOrMsg )
                    assert( fso:existsAsFile( newFile ), "Convert did not create output file: '^1' (input file was '^2')", newFile, file )
                    
                    return newFile -- DO NOT FALL THROUGH
                    
                elseif cmdOrMsg then
                    if str:is( c ) then
                        app:logv( "Convert response: ^1", str:limit( c, 500 ) ) -- not sure how long that response might be.
                    end
                    app:error( cmdOrMsg )
                else
                    app:error( "program failure" )
                end
            else
                app:logE( "Unable to create directory: ^1", dir )
            end
        end
    end
    if settings.importType == "Add" then -- Add
        --app:logv( "Adding in place" )
        --assert( file, "no file" )
        --newFile = file
        app:callingError( "Check for import-type 'Add' before calling" )
    elseif settings.importType == "Move" then -- Move
        local s, m = self:_copyOrMove( file, newFile, spec, true ) -- throw error if no can do.
        if not s then
            newFile = nil
            trouble = m
        end
    elseif settings.importType == 'Copy' then
        local s, m = self:_copyOrMove( file, newFile, spec, false ) -- throw error if no can do.
        if not s then
            newFile = nil
            trouble = m
        end
    else
        app:error( "Unsupported import type: ^1", settings.importType )
    end
    if not newFile then
        assert( trouble, "why no new file" )
    end
    return newFile, trouble
end



-- sets or clears read-only file attribute, depending on spec.
function Import:_handleReadOnly( file, newFile, readOnly, spec )
    local settings = spec.settings
    if str:is( settings.readOnlyFileAttribute ) or settings.readOnlyPhotoMetadata then
        local newReadOnly = fso:isReadOnly( newFile )
        if settings.readOnlyFileAttribute == 'clear' then
            local s, m = fso:makeReadWrite( newFile ) -- clear read-only
            if s then
                app:log( "cleared read-only" )
            else
                app:logErr( "Unable to make read-write - ^1", m )
            end
            -- Note: leave new-read-only set.
        elseif settings.readOnlyFileAttribute == 'set' then
            if not newReadOnly then
                local s, m = fso:makeReadOnly( newFile ) -- set read-only
                if s then
                    app:log( "set read-only" )
                    -- leave it cleared, since next phase is based on original attr.
                else
                    app:logErr( "Unable to make read-only - ^1", m )
                end
            else
                app:log( "new file already read-only" )
            end
        elseif settings.readOnlyFileAttribute == 'preserve' then
            local s, m
            if newReadOnly ~= readOnly then
                if readOnly then
                    s, m = fso:makeReadOnly( newFile )
                    if s then
                        --newReadOnly = true - dont care.
                        app:log( "Made new file read-only" )
                    else
                        app:logErr( m )
                    end
                else
                    s, m = fso:makeReadWrite( newFile )
                    if s then
                        --newReadOnly = false - n/a
                        app:log( "Made new file read-write" )
                    else
                        app:logErr( m )
                    end
                end
            else
                if settings.importType == 'Add' then
                    -- this is always the case, and in a more optimal implementation, would not even check...
                    -- *may* not be the case necessarily though if add-in-place ever supports renaming or dng conversion.
                else
                    app:log( "new file same - ^1", readOnly and "read-only" or "read-write" )
                end
            end
        end
    else
        --
    end
end



function Import:_removeKeywordsFromFile( file, newFile, spec )
    if not self.ets then
        app:logWarning( "Need exiftool session to remove keywords from file." )
        return
    end
    self.ets:addArg( "-keywords=" )
    self.ets:addArg( "-overwrite_original" )
    self.ets:addTarget( newFile )
    local rslt, errm = self.ets:execute()
    if str:is( errm ) then
        app:logErr( errm )
    else
        -- probably worked.
        app:logv( "Keywords removed from file" )
    end
end



function Import:_removeKeywordsFromPhoto( photo, newFile, spec )
    local keywords = photo:getRawMetadata( 'keywords' )
    if #keywords > 0 then
        for i, k in ipairs( keywords ) do
            photo:removeKeyword( k )
        end
        app:logv( "^1 removed from photo.", str:nItems( #keywords, "pre-existing keywords" ) )
    else
        app:logv( "No keywords to remove from photo." )
    end
end



function Import:_removeNewKeywordsFromPhoto( photo, newFile, spec )
    local keywords = photo:getRawMetadata( 'keywords' )
    local count = 0
    if #keywords > 0 then
        for i, k in ipairs( keywords ) do
            local photos = k:getPhotos()
            if #photos == 1 then
                assert( photos[1] == photo, "how can only one photo have it, and it not be me?" )
                photo:removeKeyword( k ) -- back to "zero" photos having it!
                count = count + 1
            else
                -- not a new keyword.
            end
        end
        app:logv( "^1 removed from photo.", str:nItems( count, "new keywords" ) )
    else
        app:logv( "No new keywords to remove from photo." )
    end
end



--  Called when importing and file has passed preliminary considerations, - it will be added to catalog, unless there is an error.
--
--  @param spec (table, default=nil) if nil, added in place, may have members:<br>
--             * lrImportPreset
--             * {tbd}
--
--  @return status (boolean, optional) nil => not imported. true => no error. false => error.
--  @return imported (boolean or string, optional) boolean -> imported. string -> error message.
--  @return alreadyInCatalog (boolean or string, optional). 
--
function Import:fileAsSpecified( file, spec, reportOnly, returnErrors )

    local imported
    local errm
    local alreadyInCatalog
    
    -- To be clear: returns from inner func here are not being propagated to calling context,
    -- so either throw an error, or set the return vars.
    local status, message = app:pcall{ name="Import File As Specified", async=false, main=function( call )
    
        assert( spec.auto ~= nil, "specify auto in spec" )
    
        -- announce general activity and target file,
        -- target file need not be reiterated in subsequent logs.
        if not reportOnly then
            self:log()
            self:log( "Considering import of file: ^1", file )
        end
        local origFilename = LrPathUtils.leafName( file )
        local origExt = LrPathUtils.extension( origFilename )
        local supportType, supportOther
        if str:is( origExt ) then
            supportType, supportOther = self:getSupportType( origExt ) -- other is not pertinent at this juncture.
            if not supportType then
                self.stats:incrStat( 'excluded' )
                if reportOnly then
                    self:log( "Excluded because of extension: ^1", file )
                else
                    self:log( "Extension being excluded from import: ^1", origExt )
                end
                return -- from inner func.
            end            
        else
            self:log( "Files without extensions are excluded from import." )
            return -- from inner func.
        end
        
        local settings = spec.settings or error( "no settings" )
                
        local readOnly
        if settings.importProtectedOnly or str:is( settings.readOnlyFileAttribute ) or settings.readOnlyPhotoMetadata then
            readOnly = fso:isReadOnly( file )
            if readOnly then
                self:logv( "read-only" )
            else
                if settings.importProtectedOnly then
                    self:log( "not marked protected/read-only - being ignored." )
                    return -- from internal function, so values returned to calling context will be: true, nil.
                end
            end
        end

        local newExt
        local newFile
        local newFilename -- *** only initialized if need be.
        if settings.importType ~= 'Add' then
            if settings.initFile then -- loads exif-metadata, and tokens.
                self:_initFile( file, spec )
            end
            newExt = self:_getNewExtension( file, spec ) -- @14/Nov/2012 3:39 one return value.
            newFile = self:_getNewFilePath( file, spec, newExt ) -- ditto.
        else -- add in place
            -- this makes no sense: if renaming is not supported when adding in place, then the original extension is the new extension, by definition.
            --[[ *** save, because it's possible to implement add in place with format conversion or renaming, just doesn't yet.
            newExt = self:_getNewExtension( file, spec )
            if self:getSupportType( newExt ) then
                newFile = file
            else
                self:logv( "Original extension '^1' is listed for import, but new extension '^2' is not - punting ( skipping import ).", origExt, ext )
                return
            end
            --]]
            -- Note: init-file is not being called because there will be no renaming, but actually, it (or something) may need to be called anyway to initialize
            -- exif metadata that may be used for things other than filenaming, like applying develop presets. ###3
            -- on the other hand, perhaps exif metadata can be initialized without all the filenaming tokens - hmm...
            -- reminder: if init-photo is called (it will be), it will just do an init-file anyway, so it's gonna happen anyeay as it stands 14/Nov/2012 3:39.
            -- note2: it does not hurt to initialize tokens too, just wastes a few cpu cycles.
            newExt = origExt
            newFile = file
        end
        
        if newFile == nil then -- file is to be skipped due to non-importable extension or such.
            self:log( "Skipping: ^1", file )
            return -- from inner func.
        end            

        alreadyInCatalog = catalog:findPhotoByPath( newFile )
        if alreadyInCatalog then
            self.stats:incrStat( "alreadyInCatalog" )
            self:log( "Already in catalog: ^1", newFile ) -- no-op if auto-import mode.
            return -- from inner func.
        end
        
        newFilename = LrPathUtils.leafName( newFile )
        --Debug.pause( settings.denyIfDupFilename, Import.fnSet[newFilename] )
        if settings.denyIfDupFilename then
            assert( Import.fnSet, "no fn set" )
            if Import.fnSet[newFilename] then
                self:log( "Duplicate filename: ^1 (not importing)", newFilename ) -- no-op if auto-import mode.
                return -- from inner func.
            -- else proceed..
            end                
        end            

        if settings.importCriteria ~= nil then
            local params = {
                origFile = file,
                newFile = newFile,
                origExt = origExt,
                newExt = newExt,
                origFilename = origFilename,
                newFilename = newFilename,
                spec = spec,
            }
            local doImport, ifNotWhy = settings.importCriteria( params ) -- e.g. dup-checking.
            if not doImport then
                app:log( "Skipping import of '^1' because: ^2", file, ifNotWhy or "not sure..." )
                return -- from inner func.
            end
        end            

        if tab:hasItems( settings.backups ) then
            if not reportOnly then
                self:_backup( file, newFile, spec ) -- throw error if no can do.
            end
        end
        
        if settings.importType ~= 'Add' then
            local newFile, trouble = self:_transferFileToLibrary( file, newFile, spec ) -- where "library" means import destination.
            if newFile == nil then -- file could not be transfered due to trouble, presumably.
                app:log( "Skipping import of '^1', trouble: ^2", file, trouble or "not sure..." ) -- trouble assured if no new file.
                return -- from inner func.
            end
        else
            if supportType and ( supportOther == nil or type( supportOther ) == 'number' ) then -- supported by 'Add' and no need to convert format.
                if reportOnly then
                    self.stats:incrStat( 'imported' ) -- misnomer
                    imported = true -- just "pretending".
                    return -- from inner func.
                else
                    self:logv( "Adding in place." )
                end
            else
                app:log( "Skipping import of '^1' because: ^2", file, "it's not supported by 'Add'." )
                return -- from inner func.
            end
        end

        -- fall-through => All preconditions satisfied to add file to catalog and deal with added photo.
        if spec.auto then
            local tb
            local tb2
            local actionPrefKey -- separate apk for sel-folders and other auto-importing.
            if type( spec.auto ) == 'string' then -- mirror or sel-folder
                actionPrefKey = spec.auto
                tb2 = spec.auto
            else -- ad=hoc
                actionPrefKey = "ad-hoc auto-import confirmation"
                tb2 = "ad-hoc (temporary-or-permanent) auto-import"
            end
            if settings.importType == 'Add' then
                tb = " (add in place)"
            elseif settings.importType == 'Copy' then
                tb = str:fmtx( "\n \n(copy from '^1')", file )
            elseif settings.importType == 'Move' then
                tb = str:fmtx( "\n \n(move from '^1')", file )
            end
            local button = app:show{ confirm="OK to auto-import '^1' - in honor of '^3'?^2",
                subs = { newFile, tb, tb2 },
                buttons = { dia:btn( "Yes", 'ok' ), dia:btn( "No", 'other', false ), dia:btn( "Cancel", 'cancel' ) },
                actionPrefKey = actionPrefKey,
            }
            if button == 'ok' then -- Yes
                -- hopefully enough will be logged below.
            elseif button == 'other' then -- No
                app:log( "User chose not to auto-import file: ^1", newFile )
                return -- from inner func.
            elseif button == 'cancel' then
                spec.call:cancel() -- make sure this is being checked in calling context.
                return -- from inner func.
            else
                error( "bad btn" )
            end
        end

        if settings.removeKeywords == 'file' then
            self:_removeKeywordsFromFile( file, newFile, spec )
        else
            app:logv( "Not removing keywords from file prior to import." )
        end
        
        -- set or clear read-only file attribute of new file, based on spec (should work for add-in-place too).
        self:_handleReadOnly( file, newFile, readOnly, spec ) -- @6/Nov/2012 1:47 either succeeds or throws error.
        
        local added, photo = false
        -- add one photo:
        local tmo = spec.auto and -10 or 30 -- reminder: negative tmo means don't prompt if no go.
        local s, m = cat:update( tmo, "Importing", function( context, phase )
            if phase == 1 then
                if fso:existsAsFile( newFile ) then -- file *still* exists, and with no yield, hopefully it can be added:
                    app:logv( "Adding to catalog: ^1", newFile )
                    added, photo = LrTasks.pcall( catalog.addPhoto, catalog, newFile ) -- errors seem to sometimes not be caught by pcall: generate internal error message instead.
                    if added then
                        assert( photo, "no photo" )
                        return false -- odds are we'll need a 2nd phase, if not, it won't hurt too much.
                    else
                        --app:error( photo ) -- ###3 not propagating OK always.
                        errm = photo
                        return false -- give a chance to percolate.
                    end
                else
                    app:logv( "Disappeared before it could be added: ^1", newFile ) -- user deleted it using Lr, most probably.
                end
            elseif phase == 2 then
                local retVal
                if not added or not photo then -- supposedly not added, let's see about that:
                    photo = catalog:findPhotoByPath( newFile )
                    if photo then -- this isn't happening, just here as a reminder that there is a problem, mostly video import (just AVI?).
                        app:logv( "Supposedly not added, but is there now - presumably OK." ) -- this is happening frequently when adding multiple videos in a session.
                        added = true
                        errm = nil
                        -- fall through
                    else
                        app:logv( "Photo not added after check #^1 - ^2", phase - 1, errm )
                        app:sleep( .1 )
                        if shutdown then return true end
                        if phase > 5 then
                            errm = str:fmtx( "Unable to add photo to catalog - ^1", errm or "not sure why..." )
                            return true -- done
                        else
                            return true -- after 21/May/2014 5:21 - no reason to go-on if no photo - something not right about this logic.
                            -- return false -- until 21/May/2014 5:21 - will increment phase! (hmm..). 
                        end
                    end
                end
                if added and photo then
                    assert( newFilename, "no new filename" )
                    if app:getGlobalPref( 'origFilenameEna' ) then
                        if cat:isOriginalFilenamesInit() then
                            local s, m = cat:addOriginalFilename( photo, newFilename )
                            if s then
                                app:logV( "Original filename added to cache: ^1", newFilename )
                            else
                                app:logW( m )
                            end
                        -- else what can ya do?..
                        end
                    -- else might throw error or something.
                    end
                    Import.fnSet[newFilename] = true
                    local dto = photo:getRawMetadata( 'dateTimeOriginal' )
                    -- be sure to include edit to corresponding line in extended-background module (see 'allPhotos') when adding to or changing:
                    local rec = { sn=photo:getFormattedMetadata( 'cameraSerialNumber' ), model=photo:getFormattedMetadata( 'cameraModel' ), fn=newFilename, path=newFile, uuid=photo:getRawMetadata( 'uuid' ), dto=dto } -- dtoHi=nil.
                    Import.allPhotoRecs[photo] = rec
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
                    if spec.coll then
                        app:logv( "Adding to plugin import collection: ^1", spec.coll:getName() )
                        spec.coll:addPhotos{ photo }
                    else
                        app:logv( "No collection specified to add imported photo to." )
                    end
                else
                    --app:error( "photo not added" ) -- not propagating properly.
                    errm = "photo not added"
                    return -- done
                end
                
                if settings.initPhoto then
                    retVal = self:_initPhoto( photo, file, newFile, spec )
                end
                
                if settings.developPresetNames or settings.devPresets or settings.applyDevelopPresets then
                    self:_applyDevelopPresets( photo, newFile, spec )
                else
                    app:logv( "No develop preset" )
                end
                
                if settings.metadataPresetNames or settings.metadataPresetIds or settings.applyMetadataPresets then
                    self:_applyMetadataPresets( photo, newFile, spec )
                else
                    app:logv( "No metadata preset" )
                end
                
                if settings.removeKeywords == 'photo' then -- "all" is implied.
                    self:_removeKeywordsFromPhoto( photo, newFile, spec )
                elseif settings.removeKeywords == 'photoNew' then -- from photo, just "new" ones.
                    self:_removeNewKeywordsFromPhoto( photo, newFile, spec )
                else
                    app:logv( "Not removing keywords from catalog." )
                end
                
                if settings.keywords ~= nil then
                    self:_applyKeywords( photo, newFile, spec )
                else
                    app:logv( "No keywords to apply." )
                end
                
                if settings.readOnlyPhotoMetadata then
                    if readOnly then
                        local name = settings.readOnlyPhotoMetadata.name or error( "no name" )
                        local value = settings.readOnlyPhotoMetadata.value -- value could be boolean false or nil.
                        local s, m = LrTasks.pcall( photo.setRawMetadata, photo, name, value )
                        if s then
                            app:log( "set read-only metadata, '^1'='^2'", name, str:to( value ) )
                        else
                            app:logErr( "Unable to set read-only metadata - ^1", m )
                        end
                    else
                        app:log( "not setting read-only metadata" )
                    end
                -- else say no-mo'...
                end
                return retVal
            elseif phase == 3 then
                if photo == nil then
                    Debug.pause( "no photo" )
                    return
                end
                if settings.initPhoto then
                    self:_initPhoto( photo, file, newFile, spec, true ) -- ignore return value in final phase.
                end
            else
                Debug.pause( "phase overflow", phase )
            end
        end ) -- end of catalog update function.      
        
        if s then -- no catalog access error (does not, in and of itself, mean a photo was added..
            background:clearError( "CatalogAccessError" ) -- IDs can be anything, as long as unique within plugin.
            if added then
                imported = true
                app:log( "Imported and updated catalog." )
                self.stats:incrStat( "imported" )
                self:incrDfltSeqNums( supportType )
                local block = { file=file, newFile=newFile, photo=photo, spec=spec }
                self.record[#self.record + 1] = block
                if settings.endPhoto then
                    settings.endPhoto( block )
                else
                    -- Debug.pause( "no end-photo in settings" )
                end
            else
                app:logv( "Not added..." )
            end
        elseif spec.auto then -- auto-import: don't throw error
            if not returnErrors then -- force-scan
                m = m or "testing..." -- m will be present, except maybe when testing.
                app:log( "*** "..m ) -- send pseudo-warning message to log so user has something to see if he/she so-opts when prompted. - not a real warning/error since it may be cleared shortly.
                background:displayErrorX( { id="CatalogAccessError", immediate=true, promptWhenUserCancels=true }, m ) -- immediate=true means bypass default suppression. I'm kinda borrowing the background task's
                -- I wonder if I shouldn't just always return it and let calling context deal, hmm... ###2
            else -- return error, but do not log it.
                errm = m or "?"
            end
        else -- manual mode - it's an error if cant' access catalog.
            app:error( m ) -- results in error log which user will see in finale dialog box.
        end
            
    end, finale=function( call )
        if call.status then
            -- no otherwise uncaught error was thrown - but does not mean import succeeded.
        else
            app:logErr( call.message )
        end
    end }

    -- notes: status, & message are as returned from outer call wrapper, so s & m..
    -- in addition, errm could be set, which will convert a no-err (true) status to error (false).
    -- if status is true and no error messages, then 2nd param indicates whether file actually added to catalog (imported).
    -- already-in-catalog was tacked on later, and is somewhat independent of the rest..
    if errm then
        status = false
    end
    return status, message or errm or imported, alreadyInCatalog -- sorry this is so complicated.
end



--- init default sequence numbers, user's can create more sets, if desired, via config code.
function Import:initDfltSeqNums()
    self.seqNums = {}
    --self.seqNums.importNumber = app:getGlobalPref( 'importNumber' ) or 0
    self:assureSeqNum( 'session', { 'item', 'photo', 'video' } )
    self:assureSeqNum( 'source', { 'item', 'photo', 'video' } )
    self:assureSeqNum( 'target', { 'item', 'photo', 'video' } )
end



--- assure all names are in specified set (default to 1).
function Import:assureSeqNum( set, names )
    if type( names ) == 'string' then
        names = { names }
    end
    if self.seqNums == nil then
        --error( "sequence numbers have not been initialized" )
        self:initDfltSeqNums()
    end
    if not self.seqNums[set] then
        self.seqNums[set] = {}
    end
    for i, v in ipairs( names ) do
        if self.seqNums[set][v] == nil then
            self.seqNums[set][v] = 1 -- default value.
        end
    end
end



-- streamlined version for internal use.
function Import:_incrSeqNum( set, name )
    self.seqNums[set][name] = self.seqNums[set][name] + 1
end



--- Increment specified sequence number.
--
function Import:incrSeqNum( set, name )
    if self.seqNums == nil then
        error( "sequence numbers have not been initialized" )
    end
    if self.seqNums[set] == nil then
        app:error( "no sequence number set '^1'", set )
    end
    if self.seqNums[set][name] == nil then
        app:error( "no sequence number named '^1' in set '^2'", name, set )
    end
    self.seqNums[set][name] = self.seqNums[set][name] + 1
end



--- Increment default sequence numbers.
--
--  @usage called after successfully importing a photo - note: value for next time is not saved until end of import session.
--  @usage user may define additional sequence numbers, but is on his/her own as far as incrementing them, and putting them in the token cache...
--
function Import:incrDfltSeqNums( supportType )
    local name
    if supportType == 'video' then
        name = 'video'
    else
        name = 'photo'
    end
    --self.seqNums.importNumber = self.seqNums.importNumber + 1
    app:setGlobalPref( 'importNumber', self:getImportNumber() + 1 )
    self:_incrSeqNum( 'session', 'item' )
    self:_incrSeqNum( 'session', name )
    self:_incrSeqNum( 'source', 'item' )
    self:_incrSeqNum( 'source', name )
    self:_incrSeqNum( 'target', 'item' )
    self:_incrSeqNum( 'target', name )
end



--- Get the ever-increasing (item-based) "sequence" number.
--
function Import:getImportNumber()
    --return self.seqNums.importNumber or 0
    return app:getGlobalPref( 'importNumber' ) or 0 -- should always be init, but cheap insurance...
end



--- Get value of specified sequence number.
--
--  @usage can be used to support sequence number tokens in config.
--
--  @return num or nil
--  @return nil or errm.
--
function Import:getSeqNum( set, name )
    if self.seqNums then
        if self.seqNums[set] then
            if self.seqNums[set][name] then
                return self.seqNums[set][name]
            else
                Debug.pause()
                return nil, str:fmtx( "no sequence number named '^1' in set '^2'", name, set )
            end
        else
            Debug.pause()
            return nil, str:fmtx( "no sequence number set '^1'", set )
        end
    else
        error( "Sequence numbers have not been initialized." )
    end
end



--- Set sequence number explicitly.
--
function Import:setSeqNum( set, name, value )
    if self.seqNums == nil then
        --error( "sequence numbers have not been initialized" )
        self:initDfltSeqNums()
    end
    if self.seqNums[set] == nil then
        self.seqNems[set] = { [name] = value }
    else
        self.seqNums[set][name] = value
    end
end



return Import