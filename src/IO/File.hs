{--
HSFM, a filemanager written in Haskell.
Copyright (C) 2015 Julian Ospald

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

{-# OPTIONS_HADDOCK ignore-exports #-}

-- |This module provides all the atomic IO related file operations like
-- copy, delete, move and so on. It operates only on FilePaths and reads
-- all necessary file information manually in order to stay atomic and not
-- rely on the state of passed objects.
--
-- It would be nicer to pass states around, but the filesystem state changes
-- too quickly and cannot be relied upon. Lazy implementations of filesystem
-- trees have been tried as well, but they can introduce subtle bugs.
module IO.File where


import Control.Applicative
  (
    (<$>)
  )
import Control.Exception
  (
    throw
  )
import Control.Monad
  (
    unless
  , void
  )
import Data.DirTree
import Data.Foldable
  (
    for_
  )
import IO.Error
import IO.Utils
import System.Directory
  (
    canonicalizePath
  , createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , executable
  , removeDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.FilePath
  (
    equalFilePath
  , isAbsolute
  , takeFileName
  , takeDirectory
  , (</>)
  )
import System.Posix.Files
  (
    createSymbolicLink
  , readSymbolicLink
  , fileAccess
  , getFileStatus
  , groupReadMode
  , groupWriteMode
  , otherReadMode
  , otherWriteMode
  , ownerReadMode
  , ownerWriteMode
  , rename
  , touchFile
  , unionFileModes
  )
import System.Posix.IO
  (
    closeFd
  , createFile
  )
import System.Process
  (
    spawnProcess
  , ProcessHandle
  )

import qualified System.Directory as SD

import qualified System.Posix.Files as PF


-- TODO: file operations should be threaded and not block the UI


-- |Data type describing an actual file operation that can be
-- carried out via `doFile`. Useful to build up a list of operations
-- or delay operations.
data FileOperation = FCopy    Copy
                   | FMove    Move
                   | FDelete  (AnchoredFile FileInfo)
                   | FOpen    (AnchoredFile FileInfo)
                   | FExecute (AnchoredFile FileInfo) [String]
                   | None


-- |Data type describing partial or complete file copy operation.
-- CC stands for a complete operation and can be used for `runFileOp`.
data Copy = CP1 (AnchoredFile FileInfo)
          | CP2 (AnchoredFile FileInfo)
                (AnchoredFile FileInfo)
          | CC  (AnchoredFile FileInfo)
                (AnchoredFile FileInfo)
                DirCopyMode


-- |Data type describing partial or complete file move operation.
-- MC stands for a complete operation and can be used for `runFileOp`.
data Move = MP1 (AnchoredFile FileInfo)
          | MC  (AnchoredFile FileInfo)
                (AnchoredFile FileInfo)


-- |Directory copy modes.
data DirCopyMode = Strict  -- ^ fail if the target directory already exists
                 | Merge   -- ^ overwrite files if necessary
                 | Replace -- ^ remove target directory before copying


-- |Run a given FileOperation. If the FileOperation is partial, it will
-- be returned.
runFileOp :: FileOperation -> IO (Maybe FileOperation)
runFileOp (FCopy (CC from to cm)) = easyCopy cm from to >> return Nothing
runFileOp (FCopy fo)              = return              $ Just $ FCopy fo
runFileOp (FMove (MC from to))    = easyMove from to    >> return Nothing
runFileOp (FMove fo)              = return              $ Just $ FMove fo
runFileOp (FDelete fp)            = easyDelete fp       >> return Nothing
runFileOp (FOpen fp)              = openFile fp         >> return Nothing
runFileOp (FExecute fp args)      = executeFile fp args >> return Nothing
runFileOp _                       = return Nothing



    --------------------
    --[ File Copying ]--
    --------------------


-- TODO: allow renaming
-- |Copies a directory to the given destination with the specified
-- `DirCopyMode`. Excludes symlinks.
copyDir :: DirCopyMode
        -> AnchoredFile FileInfo  -- ^ source dir
        -> AnchoredFile FileInfo  -- ^ destination dir
        -> IO ()
copyDir cm (_ :/ SymLink {}) _ = return ()
copyDir cm from@(_ :/ Dir fromn _)
             to@(_ :/ Dir {})
  = do
    let fromp    = fullPath from
        top      = fullPath to
        destdirp = fullPath to </> fromn
    throwDestinationInSource fromp destdirp
    throwSameFile fromp destdirp

    createDestdir destdirp
    destdir <- Data.DirTree.readFile destdirp

    contents <- readDirectory' (fullPath from)

    for_ contents $ \f ->
      case f of
        (_ :/ SymLink {})  -> recreateSymlink f destdir
        (_ :/ Dir {}) -> copyDir cm f destdir
        (_ :/ RegFile {}) -> copyFileToDir f destdir
        _                 -> return ()
  where
    createDestdir destdir =
      case cm of
        Merge   ->
          createDirectoryIfMissing False destdir
        Strict  -> do
          throwDirDoesExist destdir
          createDirectory destdir
        Replace -> do
          whenM (doesDirectoryExist destdir) (removeDirectoryRecursive destdir)
          createDirectory destdir
    recreateSymlink' f destdir = do
      let destfilep = fullPath destdir </> (name . file $ f)
      destfile <- Data.DirTree.readFile destfilep

      _ <- case cm of
        -- delete old file/dir to be able to create symlink
        Merge -> easyDelete destfile
        _     -> return ()

      recreateSymlink f destdir
copyDir _ _ _ = return ()


-- |Recreate a symlink.
recreateSymlink :: AnchoredFile FileInfo  -- ^ the old symlink file
                -> AnchoredFile FileInfo  -- ^ destination dir of the
                                                   --   new symlink file
                -> IO ()
recreateSymlink symf@(_ :/ SymLink {})
                symdest@(_ :/ Dir {})
  = do
    symname <- readSymbolicLink (fullPath symf)
    createSymbolicLink symname (fullPath symdest </> (name . file $ symf))
recreateSymlink _ _ = return ()


-- |Copies the given file to the given file destination.
-- Excludes symlinks.
copyFile :: AnchoredFile FileInfo  -- ^ source file
         -> AnchoredFile FileInfo  -- ^ destination file
         -> IO ()
copyFile (_ :/ SymLink {}) _ = return ()
copyFile from@(_ :/ RegFile {}) to@(_ :/ RegFile {}) = do
  let from' = fullPath from
      to'   = fullPath to
  throwSameFile from' to'
  SD.copyFile from' to'
copyFile _ _ = return ()


-- |Copies the given file to the given dir with the same filename.
-- Excludes symlinks.
copyFileToDir :: AnchoredFile FileInfo
              -> AnchoredFile FileInfo
              -> IO ()
copyFileToDir (_ :/ SymLink {}) _ = return ()
copyFileToDir from@(_ :/ RegFile fn _)
                to@(_ :/ Dir {}) =
  do
    let from' = fullPath from
        to'   = fullPath to </> fn
    SD.copyFile from' to'
copyFileToDir _ _ = return ()


-- |Copies a file, directory or symlink. In case of a symlink, it is just
-- recreated, even if it points to a directory.
easyCopy :: DirCopyMode
         -> AnchoredFile FileInfo
         -> AnchoredFile FileInfo
         -> IO ()
easyCopy _ from@(_ :/ SymLink {}) to@(_ :/ Dir {}) = recreateSymlink from to
easyCopy _ from@(_ :/ RegFile fn _)
             to@(_ :/ Dir {})
  = copyFileToDir from to
easyCopy _ from@(_ :/ RegFile fn _)
             to@(_ :/ RegFile {})
  = copyFile from to
easyCopy cm from@(_ :/ Dir fn _)
              to@(_ :/ Dir {})
  = copyDir cm from to
easyCopy _ _ _ = return ()




    -------------------
    --[ File Moving ]--
    -------------------


-- |Move a given file to the given target directory.
-- Includes symlinks, which are treated as files and the symlink is not
-- followed.
moveFile :: AnchoredFile FileInfo -- ^ file to move
         -> AnchoredFile FileInfo -- ^ base target directory
         -> IO ()
moveFile from@SARegFile to@(_ :/ Dir {}) = do
  let from' = fullPath from
      to'   = fullPath to </> (name . file $ from)
  throwSameFile from' to'
  SD.renameFile from' to'
moveFile _ _ = return ()


-- |Move a given directory to the given target directory.
-- Excludes symlinks.
moveDir :: AnchoredFile FileInfo -- ^ dir to move
        -> AnchoredFile FileInfo -- ^ base target directory
        -> IO ()
moveDir (_ :/ SymLink {}) _ = return ()
moveDir from@(_ :/ Dir n _) to@(_ :/ Dir {}) = do
  let from' = fullPath from
      to'   = fullPath to </> n
  throwSameFile from' to'
  SD.renameDirectory from' to'
moveDir _ _ = return ()


-- |Moves a file, directory or symlink. In case of a symlink, it is
-- treated as a file and the symlink is not being followed.
easyMove :: AnchoredFile FileInfo    -- ^ source
         -> AnchoredFile FileInfo    -- ^ base target directory
         -> IO ()
easyMove from@(_ :/ SymLink {}) to@(_ :/ Dir {})       = moveFile from to
easyMove from@(_ :/ RegFile _ _) to@(_ :/ Dir {}) = moveFile from to
easyMove from@(_ :/ Dir _ _) to@(_ :/ Dir {})     = moveDir from to
easyMove _ _ = return ()



    ---------------------
    --[ File Deletion ]--
    ---------------------


-- |Deletes a symlink, which can either point to a file or directory.
deleteSymlink :: AnchoredFile FileInfo -> IO ()
deleteSymlink f@(_ :/ SymLink {})
  = removeFile (fullPath f)
deleteSymlink _
  = return ()


-- |Deletes the given file, never symlinks.
deleteFile :: AnchoredFile FileInfo -> IO ()
deleteFile   (_ :/ SymLink {}) = return ()
deleteFile f@(_ :/ RegFile {})
  = removeFile (fullPath f)
deleteFile _
  = return ()


-- |Deletes the given directory, never symlinks.
deleteDir :: AnchoredFile FileInfo -> IO ()
deleteDir   (_ :/ SymLink {}) = return ()
deleteDir f@(_ :/ Dir {})
  = removeDirectory (fullPath f)
deleteDir _ = return ()


-- |Deletes the given directory recursively, never symlinks.
deleteDirRecursive :: AnchoredFile FileInfo -> IO ()
deleteDirRecursive   (_ :/ SymLink {}) = return ()
deleteDirRecursive f@(_ :/ Dir {})
  = removeDirectoryRecursive (fullPath f)
deleteDirRecursive _ = return ()


-- |Deletes a file, directory or symlink, whatever it may be.
-- In case of directory, performs recursive deletion. In case of
-- a symlink, the symlink file is deleted.
easyDelete :: AnchoredFile FileInfo -> IO ()
easyDelete f@(_ :/ SymLink {}) = deleteSymlink f
easyDelete f@(_ :/ RegFile {})
  = deleteFile f
easyDelete f@(_ :/ Dir {})
  = deleteDirRecursive f
easyDelete _
  = return ()




    --------------------
    --[ File Opening ]--
    --------------------


-- |Opens a file appropriately by invoking xdg-open.
openFile :: AnchoredFile a
         -> IO ProcessHandle
openFile f = spawnProcess "xdg-open" [fullPath f]


-- |Executes a program with the given arguments.
executeFile :: AnchoredFile FileInfo  -- ^ program
            -> [String]               -- ^ arguments
            -> IO (Maybe ProcessHandle)
executeFile prog@(_ :/ RegFile {}) args
  = Just <$> spawnProcess (fullPath prog) args
executeFile _ _      = return Nothing




    ---------------------
    --[ File Creation ]--
    ---------------------


createFile :: AnchoredFile FileInfo -> FileName -> IO ()
createFile _ "."  = return ()
createFile _ ".." = return ()
createFile (SADir td) fn = do
  let fullp = fullPath td </> fn
  throwFileDoesExist fullp
  let uf   = unionFileModes
      mode =      ownerWriteMode
             `uf` ownerReadMode
             `uf` groupWriteMode
             `uf` groupReadMode
             `uf` otherWriteMode
             `uf` otherReadMode
  fd <- System.Posix.IO.createFile fullp mode
  closeFd fd




    ---------------------
    --[ File Renaming ]--
    ---------------------


renameFile :: AnchoredFile FileInfo -> FileName -> IO ()
renameFile (_ :/ Failed {}) _ = return ()
renameFile _ "."              = return ()
renameFile _ ".."             = return ()
renameFile af fn = do
  let fromf = fullPath af
      tof   = anchor af </> fn
  throwFileDoesExist tof
  throwSameFile fromf tof
  rename fromf tof
