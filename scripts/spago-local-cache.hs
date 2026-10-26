#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle ])"
#! nix-shell -p nodejs_22

-- Runs the project's spago with its macOS cache redirected into .cache/, so
-- builds never touch ~/Library/Caches. Run from the repository root:
--
--   ./scripts/spago-local-cache.hs build
--
-- node's os.homedir() honours $HOME, so pointing HOME at the project-local
-- directory moves the cache without patching node.

{-# LANGUAGE OverloadedStrings #-}

import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import System.FilePath ((</>))
import Turtle hiding (FilePath, (</>))

main :: IO ()
main = do
  args <- arguments
  here <- pwd
  let home = here </> ".cache" </> "spago-home"
      bin = here </> "node_modules" </> ".bin"
  mktree home
  oldPath <- fromMaybe "" <$> need "PATH"
  export "HOME" (T.pack home)
  export "PATH" (T.pack bin <> ":" <> oldPath)
  code <- proc "node" ("node_modules/spago/bin/bundle.js" : args) empty
  exit code
