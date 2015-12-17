{-# OPTIONS_HADDOCK ignore-exports #-}

module GUI.Gtk.Gui (startMainWindow) where


import Control.Applicative
  (
    (<$>)
  , (<*>)
  )
import Control.Concurrent
  (
    forkIO
  )
import Control.Concurrent.STM
  (
    TVar
  , newTVarIO
  , readTVarIO
  )
import Control.Exception
  (
    try
  , Exception
  , SomeException
  )
import Control.Monad
  (
    when
  , void
  )
import Control.Monad.IO.Class
  (
    liftIO
  )
import Data.DirTree
import Data.DirTree.Zipper
import Data.Foldable
  (
    for_
  )
import Data.List
  (
    sort
  , isPrefixOf
  )
import Data.Maybe
  (
    fromJust
  , catMaybes
  )
import Graphics.UI.Gtk
import Graphics.UI.Gtk.Abstract.Box
import Graphics.UI.Gtk.Builder
import Graphics.UI.Gtk.ModelView
import GUI.Gtk.Icons
import IO.Error
import IO.File
import IO.Utils
import System.Directory
  (
    executable
  , doesFileExist
  , doesDirectoryExist
  )
import System.Environment
  (
    getArgs
  )
import System.FilePath.Posix
  (
    isAbsolute
  )
import System.Glib.UTFString
  (
    glibToString
  )
import System.IO.Unsafe
  (
    unsafePerformIO
  )
import System.Process
  (
    spawnProcess
  )


-- TODO: simplify where we modify the TVars
-- TODO: double check garbage collection/gtk ref counting
-- TODO: file watching, when and what to reread


-- |Monolithic object passed to various GUI functions in order
-- to keep the API stable and not alter the parameters too much.
-- This only holds GUI widgets that are needed to be read during
-- runtime.
data MyGUI = MkMyGUI {
  -- |main Window
    rootWin  :: Window
  , menubarFileQuit :: ImageMenuItem
  , menubarFileOpen :: ImageMenuItem
  , menubarFileCut :: ImageMenuItem
  , menubarFileCopy :: ImageMenuItem
  , menubarFilePaste :: ImageMenuItem
  , menubarFileDelete :: ImageMenuItem
  , menubarHelpAbout :: ImageMenuItem
  , urlBar :: Entry
  , statusBar :: Statusbar
  -- |tree view
  , treeView :: TreeView
  -- |first column
  , cF :: TreeViewColumn
  -- |second column
  , cMD :: TreeViewColumn
  -- |renderer used for the treeView
  , renderTxt :: CellRendererText
  , renderPix :: CellRendererPixbuf
  , settings :: TVar FMSettings
  , folderPix :: Pixbuf
  , filePix :: Pixbuf
  , errorPix :: Pixbuf
}


-- |FM-wide settings.
data FMSettings = MkFMSettings {
    showHidden :: Bool
  , isLazy :: Bool
}


-- |This describes the contents of the treeView and is separated from MyGUI,
-- because we might want to have multiple views.
data MyView = MkMyView {
  -- |raw model with unsorted data
    rawModel :: TVar (ListStore (DTZipper DirTreeInfo DirTreeInfo))
  -- |sorted proxy model
  , sortedModel :: TVar (TypedTreeModelSort
                          (DTZipper DirTreeInfo DirTreeInfo))
  -- |filtered proxy model
  , filteredModel :: TVar (TypedTreeModelFilter
                            (DTZipper DirTreeInfo DirTreeInfo))
  , fsState :: TVar (DTZipper DirTreeInfo DirTreeInfo)
}


-- |Set hotkeys.
setBindings :: MyGUI -> MyView -> IO ()
setBindings mygui myview = do
  _ <- rootWin mygui `on` keyPressEvent $ tryEvent $ do
    [Control] <- eventModifier
    "q"       <- fmap glibToString eventKeyName
    liftIO mainQuit
  _ <- rootWin mygui `on` keyPressEvent $ tryEvent $ do
    [Control] <- eventModifier
    "h"       <- fmap glibToString eventKeyName
    liftIO $ modifyTVarIO (settings mygui)
                          (\x -> x { showHidden = not . showHidden $ x})
             >> updateTreeView mygui myview
  _ <- rootWin mygui `on` keyPressEvent $ tryEvent $ do
    [Alt] <- eventModifier
    "Up"  <- fmap glibToString eventKeyName
    liftIO $ upDir mygui myview
  _ <- treeView mygui `on` rowActivated $ openRow mygui myview
  _ <- menubarFileQuit mygui `on` menuItemActivated $ mainQuit
  _ <- urlBar mygui `on` entryActivated $ urlGoTo mygui myview
  return ()


-- |Go the the url given at the `urlBar` and visualize it in the given
-- treeView.
--
-- This might update the TVar `rawModel`.
urlGoTo :: MyGUI -> MyView -> IO ()
urlGoTo mygui myview = do
  fp <- entryGetText (urlBar mygui)
  let abs = isAbsolute fp
  exists <- (||) <$> doesDirectoryExist fp <*> doesFileExist fp
  -- TODO: more explicit error handling?
  when (abs && exists) $ do
    newFsState  <- readPath' fp
    newRawModel <- fileListStore newFsState myview
    writeTVarIO (rawModel myview) newRawModel
    updateTreeView mygui myview


-- |Enter a subdirectory and visualize it in the treeView or
-- open a file.
--
-- This might update the TVar `rawModel`.
openRow :: MyGUI -> MyView -> TreePath -> TreeViewColumn -> IO ()
openRow mygui myview tp tvc = do
  rawModel'      <- readTVarIO $ rawModel myview
  sortedModel'   <- readTVarIO $ sortedModel myview
  filteredModel' <- readTVarIO $ filteredModel myview
  miter          <- treeModelGetIter sortedModel' tp
  for_ miter $ \iter -> do
    cIter' <- treeModelSortConvertIterToChildIter sortedModel' iter
    cIter  <- treeModelFilterConvertIterToChildIter filteredModel' cIter'
    row    <- treeModelGetRow rawModel' cIter
    case row of
      (Dir _ _ _, _) -> do
        newRawModel <- fileListStore row myview
        rm <- readTVarIO (rawModel myview)
        writeTVarIO (rawModel myview) newRawModel
        updateTreeView mygui myview
      dz@(File _ _, _) ->
        withErrorDialog $ openFile (getFullPath dz)
      _ -> return ()


-- |Go up one directory and visualize it in the treeView.
--
-- This will update the TVar `rawModel`.
upDir :: MyGUI -> MyView -> IO ()
upDir mygui myview = do
  rawModel'    <- readTVarIO $ rawModel myview
  sortedModel' <- readTVarIO $ sortedModel myview
  fS           <- readTVarIO $ fsState myview
  newRawModel  <- fileListStore (goUp fS) myview
  writeTVarIO (rawModel myview) newRawModel
  updateTreeView mygui myview


-- |Create the `ListStore` of files/directories from the current directory.
-- This is the function which maps the Data.DirTree data structures
-- into the GTK+ data structures.
--
-- This also updates the TVar `fsState` inside the given view.
fileListStore :: DTZipper DirTreeInfo DirTreeInfo  -- ^ current dir
              -> MyView
              -> IO (ListStore (DTZipper DirTreeInfo DirTreeInfo))
fileListStore dtz myview = do
  writeTVarIO (fsState myview) dtz
  listStoreNew (goAllDown dtz)


-- TODO: make this function more slim so only the most necessary parts are
-- called
-- |Updates the visible TreeView with the current underlying mutable models,
-- which are retrieved from `MyGUI`.
--
-- This also updates the TVars `filteredModel` and `sortedModel` in the process.
updateTreeView :: MyGUI
               -> MyView
               -> IO ()
updateTreeView mygui myview = do
  let treeView' = treeView mygui
      cF' = cF mygui
      cMD' = cMD mygui
      render' = renderTxt mygui

  -- update urlBar, this will break laziness slightly, probably
  fsState <- readTVarIO $ fsState myview
  let urlpath = getFullPath fsState
  entrySetText (urlBar mygui) urlpath

  rawModel' <- readTVarIO $ rawModel myview

  -- filtering
  filteredModel' <- treeModelFilterNew rawModel' []
  writeTVarIO (filteredModel myview) filteredModel'
  treeModelFilterSetVisibleFunc filteredModel' $ \iter -> do
     hidden <- showHidden <$> readTVarIO (settings mygui)
     row    <- treeModelGetRow rawModel' iter
     if hidden
       then return True
       else return $ not ("." `isPrefixOf` (name . unZip $ row))

  -- sorting
  sortedModel' <- treeModelSortNewWithModel filteredModel'
  writeTVarIO (sortedModel myview) sortedModel'
  treeSortableSetSortFunc sortedModel' 1 $ \iter1 iter2 -> do
      cIter1 <- treeModelFilterConvertIterToChildIter filteredModel' iter1
      cIter2 <- treeModelFilterConvertIterToChildIter filteredModel' iter2
      row1   <- treeModelGetRow rawModel' cIter1
      row2   <- treeModelGetRow rawModel' cIter2
      return $ compare (unZip row1) (unZip row2)
  treeSortableSetSortColumnId sortedModel' 1 SortAscending

  -- set values
  treeModelSetColumn rawModel' (makeColumnIdPixbuf 0)
                               (dirtreePix . unZip)
  treeModelSetColumn rawModel' (makeColumnIdString 1)
                               (name . unZip)
  treeModelSetColumn rawModel' (makeColumnIdString 2)
                               (packModTime . unZip)
  treeModelSetColumn rawModel' (makeColumnIdString 3)
                               (packPermissions . unZip)

  -- update treeview model
  treeViewSetModel treeView' sortedModel'

  return ()
  where
    dirtreePix (Dir {})    = folderPix mygui
    dirtreePix (File {})   = filePix mygui
    dirtreePix (Failed {}) = errorPix mygui


pushStatusBar :: MyGUI -> String -> IO (ContextId, MessageId)
pushStatusBar mygui str = do
  let sb = statusBar mygui
  cid <- statusbarGetContextId sb "FM Status"
  mid <- statusbarPush sb cid str
  return (cid, mid)


-- |Pops up an error Dialog with the given String.
showErrorDialog :: String -> IO ()
showErrorDialog str = do
  errorDialog <- messageDialogNew Nothing
                                  [DialogDestroyWithParent]
                                  MessageError
                                  ButtonsClose
                                  str
  _ <- dialogRun errorDialog
  widgetDestroy errorDialog


-- |Execute the given IO action. If the action throws exceptions,
-- visualize them via `showErrorDialog`.
withErrorDialog :: IO a -> IO ()
withErrorDialog io = do
  r <- try io
  either (\e -> showErrorDialog $ show (e :: SomeException))
         (\_ -> return ())
         r


-- |Set up the GUI.
startMainWindow :: IO ()
startMainWindow = do

  settings <- newTVarIO (MkFMSettings False True)

  -- get the icons
  iT        <- iconThemeGetDefault
  folderPix <- getIcon IFolder 24
  filePix   <- getIcon IFile 24
  errorPix  <- getIcon IError 24

  fsState <- readPath "/" >>= (newTVarIO . baseZipper . dirTree)

  builder <- builderNew
  builderAddFromFile builder "data/Gtk/builder.xml"

  -- get the pre-defined gui widgets
  rootWin           <- builderGetObject builder castToWindow
                       "rootWin"
  scroll            <- builderGetObject builder castToScrolledWindow
                       "mainScroll"
  menubarFileQuit   <- builderGetObject builder castToImageMenuItem
                       "menubarFileQuit"
  menubarFileOpen   <- builderGetObject builder castToImageMenuItem
                       "menubarFileOpen"
  menubarFileCut    <- builderGetObject builder castToImageMenuItem
                       "menubarFileCut"
  menubarFileCopy   <- builderGetObject builder castToImageMenuItem
                       "menubarFileCopy"
  menubarFilePaste  <- builderGetObject builder castToImageMenuItem
                       "menubarFilePaste"
  menubarFileDelete <- builderGetObject builder castToImageMenuItem
                      "menubarFileDelete"
  menubarHelpAbout  <- builderGetObject builder castToImageMenuItem
                      "menubarHelpAbout"
  urlBar            <- builderGetObject builder castToEntry
                       "urlBar"
  statusBar         <- builderGetObject builder castToStatusbar
                       "statusBar"

  -- create initial list store model with unsorted data
  rawModel <- newTVarIO =<< listStoreNew . goAllDown =<< readTVarIO fsState

  filteredModel <- newTVarIO =<< (\x -> treeModelFilterNew x [])
                           =<< readTVarIO rawModel

  -- create an initial sorting proxy model
  sortedModel <- newTVarIO =<< treeModelSortNewWithModel
                           =<< readTVarIO filteredModel

  -- create the final view
  treeView <- treeViewNew

  -- create final tree model columns
  renderTxt <- cellRendererTextNew
  renderPix <- cellRendererPixbufNew
  let ct = cellText   :: (CellRendererTextClass cr) => Attr cr String
      cp = cellPixbuf :: (CellRendererPixbufClass self) => Attr self Pixbuf

  -- filename column
  cF <- treeViewColumnNew
  treeViewColumnSetTitle        cF "Filename"
  treeViewColumnSetResizable    cF True
  treeViewColumnSetClickable    cF True
  treeViewColumnSetSortColumnId cF 1
  cellLayoutPackStart cF renderPix False
  cellLayoutPackStart cF renderTxt True
  _ <- treeViewAppendColumn treeView cF
  cellLayoutAddColumnAttribute cF renderPix cp $ makeColumnIdPixbuf 0
  cellLayoutAddColumnAttribute cF renderTxt ct $ makeColumnIdString 1

  -- date column
  cMD <- treeViewColumnNew
  treeViewColumnSetTitle        cMD "Date"
  treeViewColumnSetResizable    cMD True
  treeViewColumnSetClickable    cMD True
  treeViewColumnSetSortColumnId cMD 2
  cellLayoutPackStart cMD renderTxt True
  _ <- treeViewAppendColumn treeView cMD
  cellLayoutAddColumnAttribute cMD renderTxt ct $ makeColumnIdString 2

  -- permissions column
  cP <- treeViewColumnNew
  treeViewColumnSetTitle        cP "Permission"
  treeViewColumnSetResizable    cP True
  treeViewColumnSetClickable    cP True
  treeViewColumnSetSortColumnId cP 3
  cellLayoutPackStart cP renderTxt True
  _ <- treeViewAppendColumn treeView cP
  cellLayoutAddColumnAttribute cP renderTxt ct $ makeColumnIdString 3

  -- construct the gui object
  let mygui  = MkMyGUI {..}
  let myview = MkMyView {..}

  -- create the tree model with its contents
  updateTreeView mygui myview

  -- set the bindings
  setBindings mygui myview

  -- add the treeview to the scroll container
  containerAdd scroll treeView

  widgetShowAll rootWin
