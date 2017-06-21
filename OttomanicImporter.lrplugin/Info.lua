--[[
        Info.lua
--]]

return {
    appName = "Ottomanic Importer",
    shortAppName = "OI",
    author = "Rob Cole",
    authorsWebsite = "www.robcole.com",
    donateUrl = "http://www.robcole.com/Rob/Donate",
    platforms = { 'Windows', 'Mac' },
    pluginId = "com.robcole.lightroom.OttomanicImporter",
    xmlRpcUrl = "http://www.robcole.com/Rob/_common/cfpages/XmlRpc.cfm",
    LrPluginName = "rc Ottomanic Importer",
    LrSdkMinimumVersion = 3.0,
    LrSdkVersion = 5.0,
    LrPluginInfoUrl = "http://www.robcole.com/Rob/ProductsAndServices/OttomanicImporterLrPlugin",
    LrPluginInfoProvider = "ExtendedManager.lua",
    LrToolkitIdentifier = "com.robcole.OttomanicImporter",
    LrInitPlugin = "Init.lua",
    LrShutdownPlugin = "Shutdown.lua",
    LrMetadataTagsetFactory = "Tagsets.lua",
    LrHelpMenuItems = {
        {
            title = "General Help",
            file = "mHelp.lua",
        },
    },
    LrLibraryMenuItems = {
        {
            title = "&Add Folder to Catalog (no photos)",
            file = "mAddFolder.lua",
        },
        {
            title = "&Auto Import - Start",
            file = "mAutoImportStart.lua",
        },
        {
            title = "&Auto Import - Stop",
            file = "mAutoImportStop.lua",
        },
        {
            title = "&Auto Import - Show",
            file = "mAutoImportShow.lua",
        },
        {
            title = "&Manual Import",
            file = "mManualImport.lua",
        },
        {
            title = "&Import Folders or Files",
            file = "mImportFoldersOrFiles.lua",
        },
        {
            title = "&Hide n' Import...",
            file = "mHideAndImport.lua",
        },
        {
            title = "&Catalog Sync",
            file = "mCatalogSync.lua",
        },
        {
            title = "&Remove Deleted Photos",
            file = "mRemoveDeletedPhotos.lua",
        },
        {
            title = "&Find Missing and/or Empty Folders",
            file = "mFindMissingOrEmptyFolders.lua",
        },
    },
    VERSION = { display = "5.4    Build: 2015-01-05 14:41:38" },
}
