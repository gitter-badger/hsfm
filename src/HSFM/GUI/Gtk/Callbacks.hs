{--
HSFM, a filemanager written in Haskell.
Copyright (C) 2016 Julian Ospald

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
version 2 as published by the Free Software Foundation.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
--}

{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_HADDOCK ignore-exports #-}

module HSFM.GUI.Gtk.Callbacks where


import Control.Concurrent.STM
  (
    readTVarIO
  )
import Control.Exception
  (
    throw
  )
import Control.Monad
  (
    void
  , forM_
  )
import Control.Monad.IO.Class
  (
    liftIO
  )
import Data.Foldable
  (
    for_
  )
import Graphics.UI.Gtk
import qualified HPath as P
import HPath
    (
      Abs
    , Path
    )
import HSFM.FileSystem.Errors
import HSFM.FileSystem.FileOperations
import HSFM.FileSystem.FileType
import HSFM.GUI.Gtk.Data
import HSFM.GUI.Gtk.Dialogs
import HSFM.GUI.Gtk.MyView
import HSFM.GUI.Gtk.Utils
import HSFM.Utils.IO
import Prelude hiding(readFile)
import System.Glib.UTFString
  (
    glibToString
  )





    -----------------
    --[ Callbacks ]--
    -----------------


-- |Set callbacks, on hotkeys, events and stuff.
setCallbacks :: MyGUI -> MyView -> IO ()
setCallbacks mygui myview = do
  view' <- readTVarIO $ view myview
  case view' of
    fmv@(FMTreeView treeView) -> do
      _ <- treeView `on` rowActivated
             $ (\_ _ -> withItems mygui myview open)
      commonGuiEvents fmv
      return ()
    fmv@(FMIconView iconView) -> do
      _ <- iconView `on` itemActivated
             $ (\_ -> withItems mygui myview open)
      commonGuiEvents fmv
      return ()
  menubarCallbacks
  where
    menubarCallbacks = do
      -- menubar-file
      _ <- menubarFileQuit mygui `on` menuItemActivated $ mainQuit
      _ <- menubarFileOpen mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview open
      _ <- menubarFileExecute mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview execute
      _ <- menubarFileNew mygui `on` menuItemActivated $
        liftIO $ newFile mygui myview

      -- menubar-edit
      _ <- menubarEditCut mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview moveInit
      _ <- menubarEditCopy mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview copyInit
      _ <- menubarEditRename mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview renameF
      _ <- menubarEditPaste mygui `on` menuItemActivated $
        liftIO $ operationFinal mygui myview
      _ <- menubarEditDelete mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview del

      -- mewnubar-view
      _ <- menubarViewIcon mygui `on` menuItemActivated $
        liftIO $ switchView mygui myview createIconView
      _ <- menubarViewTree mygui `on` menuItemActivated $
        liftIO $ switchView mygui myview createTreeView

      -- menubar-help
      _ <- menubarHelpAbout mygui `on` menuItemActivated $
        liftIO showAboutDialog
      return ()
    commonGuiEvents fmv = do
      let view = fmViewToContainer fmv

      -- GUI events
      _ <- urlBar mygui `on` entryActivated $ urlGoTo mygui myview

      _ <- refreshViewB mygui `on` buttonActivated $ do
           cdir <- liftIO $ getCurrentDir myview
           refreshView' mygui myview cdir
      _ <- clearStatusBar mygui `on` buttonActivated $ do
           popStatusbar mygui
           writeTVarIO (operationBuffer myview) None

      -- key events
      _ <- rootWin mygui `on` keyPressEvent $ tryEvent $ do
        [Control] <- eventModifier
        "q"       <- fmap glibToString eventKeyName
        liftIO mainQuit
      _ <- view `on` keyPressEvent $ tryEvent $ do
        [Control] <- eventModifier
        "h"       <- fmap glibToString eventKeyName
        cdir <- liftIO $ getCurrentDir myview
        liftIO $ modifyTVarIO (settings mygui)
                              (\x -> x { showHidden = not . showHidden $ x})
                 >> refreshView' mygui myview cdir
      _ <- view `on` keyPressEvent $ tryEvent $ do
        [Alt] <- eventModifier
        "Up"  <- fmap glibToString eventKeyName
        liftIO $ upDir mygui myview
      _ <- view `on` keyPressEvent $ tryEvent $ do
        "Delete"  <- fmap glibToString eventKeyName
        liftIO $ withItems mygui myview del
      _ <- view `on` keyPressEvent $ tryEvent $ do
        []            <- eventModifier
        "Return"      <- fmap glibToString eventKeyName
        liftIO $ withItems mygui myview open
      _ <- view `on` keyPressEvent $ tryEvent $ do
        [Control] <- eventModifier
        "c"       <- fmap glibToString eventKeyName
        liftIO $ withItems mygui myview copyInit
      _ <- view `on` keyPressEvent $ tryEvent $ do
        [Control] <- eventModifier
        "x"       <- fmap glibToString eventKeyName
        liftIO $ withItems mygui myview moveInit
      _ <- view `on` keyPressEvent $ tryEvent $ do
        [Control] <- eventModifier
        "v"       <- fmap glibToString eventKeyName
        liftIO $ operationFinal mygui myview

      -- righ-click
      _ <- view `on` buttonPressEvent $ do
        eb <- eventButton
        t  <- eventTime
        case eb of
          RightButton -> do
              _ <- liftIO $ menuPopup (rcMenu mygui)
                          $ Just (RightButton, t)
              -- this is just to not screw with current selection
              -- on right-click
              -- TODO: this misbehaves under IconView
              (x, y) <- eventCoordinates
              mpath  <- liftIO $ getPathAtPos fmv (x, y)
              case mpath of
                -- item under the cursor, only pass on the signal
                -- if the item under the cursor is not within the current
                -- selection
                (Just tp) -> do
                  selectedTps <- liftIO $ getSelectedTreePaths mygui myview
                  return $ elem tp selectedTps
                -- no item under the cursor, pass on the signal
                Nothing -> return False
          -- not right-click, so pass on the signal
          _ -> return False
      _ <- rcFileOpen mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview open
      _ <- rcFileExecute mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview execute
      _ <- rcFileNew mygui `on` menuItemActivated $
        liftIO $ newFile mygui myview
      _ <- rcFileCopy mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview copyInit
      _ <- rcFileRename mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview renameF
      _ <- rcFilePaste mygui `on` menuItemActivated $
        liftIO $ operationFinal mygui myview
      _ <- rcFileDelete mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview del
      _ <- rcFileCut mygui `on` menuItemActivated $
        liftIO $ withItems mygui myview moveInit
      return ()
    getPathAtPos fmv (x, y) =
      case fmv of
        FMTreeView treeView -> do
          mp <- treeViewGetPathAtPos treeView (round x, round y)
          return $ fmap (\(p, _, _) -> p) mp
        FMIconView iconView ->
           fmap (\tp -> if null tp then Nothing else Just tp)
                  $ iconViewGetPathAtPos iconView (round x) (round y)



-- |Go to the url given at the 'urlBar' and visualize it in the given
-- treeView.
--
-- If the url is invalid, does nothing.
urlGoTo :: MyGUI -> MyView -> IO ()
urlGoTo mygui myview = withErrorDialog $ do
  fp <- entryGetText (urlBar mygui)
  forM_ (P.parseAbs fp :: Maybe (Path Abs)) $ \fp' ->
      refreshView mygui myview (Just fp')


-- |Supposed to be used with 'withRows'. Opens a file or directory.
open :: [Item] -> MyGUI -> MyView -> IO ()
open [item] mygui myview = withErrorDialog $
  case item of
    DirOrSym r -> do
      nv <- readFile getFileInfo $ fullPath r
      refreshView' mygui myview nv
    r ->
      void $ openFile r
-- this throws on the first error that occurs
open (FileLikeList fs) _ _ = withErrorDialog $
  forM_ fs $ \f -> void $ openFile f
open _ _ _ = withErrorDialog
               . throw $ InvalidOperation
                         "Operation not supported on multiple files"


-- |Execute a given file.
execute :: [Item] -> MyGUI -> MyView -> IO ()
execute [item] _ _ = withErrorDialog $
  void $ executeFile item []
execute _ _ _ = withErrorDialog
                  . throw $ InvalidOperation
                            "Operation not supported on multiple files"


-- |Supposed to be used with 'withRows'. Deletes a file or directory.
del :: [Item] -> MyGUI -> MyView -> IO ()
del [item] _ _ = withErrorDialog $ do
  let cmsg  = "Really delete \"" ++ P.fpToString (fullPathS item) ++ "\"?"
  withConfirmationDialog cmsg
    $ easyDelete item
-- this throws on the first error that occurs
del items@(_:_) _ _ = withErrorDialog $ do
  let cmsg  = "Really delete " ++ show (length items) ++ " files?"
  withConfirmationDialog cmsg
    $ forM_ items $ \item -> easyDelete item
del _ _ _ = withErrorDialog
              . throw $ InvalidOperation
                        "Operation not supported on multiple files"


-- |Initializes a file move operation.
moveInit :: [Item] -> MyGUI -> MyView -> IO ()
moveInit items@(_:_) mygui myview = do
  writeTVarIO (operationBuffer myview) (FMove . MP1 . map fullPath $ items)
  let sbmsg = case items of
              (item:[]) -> "Move buffer: " ++ P.fpToString (fullPathS item)
              _         -> "Move buffer: " ++ (show . length $ items)
                                           ++ " items"
  popStatusbar mygui
  void $ pushStatusBar mygui sbmsg
moveInit _ _ _ = withErrorDialog
                   . throw $ InvalidOperation
                             "No file selected!"

-- |Supposed to be used with 'withRows'. Initializes a file copy operation.
copyInit :: [Item] -> MyGUI -> MyView -> IO ()
copyInit items@(_:_) mygui myview = do
  writeTVarIO (operationBuffer myview) (FCopy . CP1 . map fullPath $ items)
  let sbmsg = case items of
              (item:[]) -> "Copy buffer: " ++ P.fpToString (fullPathS item)
              _         -> "Copy buffer: " ++ (show . length $ items)
                                           ++ " items"
  popStatusbar mygui
  void $ pushStatusBar mygui sbmsg
copyInit _ _ _ = withErrorDialog
                   . throw $ InvalidOperation
                             "No file selected!"


-- |Finalizes a file operation, such as copy or move.
operationFinal :: MyGUI -> MyView -> IO ()
operationFinal _ myview = withErrorDialog $ do
  op <- readTVarIO (operationBuffer myview)
  cdir <- fullPath <$> getCurrentDir myview
  case op of
    FMove (MP1 s) -> do
      let cmsg = "Really move " ++ imsg s
                  ++ " to \"" ++ P.fpToString (P.fromAbs cdir)
                  ++ "\"?"
      withConfirmationDialog cmsg . withCopyModeDialog
        $ \cm -> void $ runFileOp (FMove . MC s cdir $ cm)
      return ()
    FCopy (CP1 s) -> do
      let cmsg = "Really copy " ++ imsg s
                 ++ " to \"" ++ P.fpToString (P.fromAbs cdir)
                 ++ "\"?"
      withConfirmationDialog cmsg . withCopyModeDialog
        $ \cm -> void $ runFileOp (FCopy . CC s cdir $ cm)
      return ()
    _ -> return ()
  where
    imsg s = case s of
               (item:[]) -> "\"" ++ P.fpToString (P.fromAbs item) ++ "\""
               items     -> (show . length $ items) ++ " items"


-- |Go up one directory and visualize it in the treeView.
upDir :: MyGUI -> MyView -> IO ()
upDir mygui myview = withErrorDialog $ do
  cdir <- getCurrentDir myview
  nv <- goUp cdir
  refreshView' mygui myview nv


-- |Go up one directory and visualize it in the treeView.
newFile :: MyGUI -> MyView -> IO ()
newFile _ myview = withErrorDialog $ do
  mfn   <- textInputDialog "Enter file name"
  let pmfn = P.parseFn =<< P.userStringToFP <$> mfn
  for_ pmfn $ \fn -> do
    cdir  <- getCurrentDir myview
    createFile cdir fn


renameF :: [Item] -> MyGUI -> MyView -> IO ()
renameF [item] _ _ = withErrorDialog $ do
  mfn  <- textInputDialog "Enter new file name"
  let pmfn = P.parseFn =<< P.userStringToFP <$> mfn
  for_ pmfn $ \fn -> do
    let cmsg = "Really rename \"" ++ P.fpToString (fullPathS item)
               ++ "\"" ++ " to \""
               ++ P.fpToString (P.fromAbs $ (P.dirname . path $ item)
                                             P.</> fn) ++ "\"?"
    withConfirmationDialog cmsg $
      HSFM.FileSystem.FileOperations.renameFile item fn
renameF _ _ _ = withErrorDialog
                  . throw $ InvalidOperation
                            "Operation not supported on multiple files"
