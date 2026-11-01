#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle ])"
#! nix-shell -p imagemagick coreutils

-- Turns a product's original photos into the web sizes the store serves, in
-- public/photos/<slug>/, and lists them in server/data/photos/<slug>.json.
-- Each photo is cropped square, stripped of all metadata (camera, GPS) and
-- written as WebP at every width in `widths`; the file names carry a content
-- hash, so the server can cache them forever. The originals aren't committed.
-- Run from the repository root, naming each photo as in server/products.js:
--
--   ./scripts/product-photos.hs bluebird-house front=/tmp/bluebird-front.jpg \
--     back=/tmp/bluebird-back.jpg interior=/tmp/bluebird-interior.jpg
--
-- Every run replaces the product's photos, so name all of them each time.

{-# LANGUAGE OverloadedStrings #-}

import Control.Monad (forM, unless, when)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, removePathForcibly, renameFile)
import System.FilePath ((</>))
import Turtle hiding (FilePath, (</>))

-- 160 is the detail page's thumbnail; the rest feed srcset on the listing and
-- detail pages, up to a large phone at 3x.
widths :: [Int]
widths = [160, 480, 800, 1200]

parser :: Parser (Text, [Text])
parser = (,) <$> argText "slug" "Product slug, as in server/products.js" <*> some (argText "name=path" "A photo: its name and the original file")

main :: IO ()
main = do
  (slug, specs) <- options "Generate a product's web photos" parser
  ok <- doesDirectoryExist "public"
  unless ok $ die "Run from the repository root (no public/ directory here)."
  let safe t = not (T.null t) && T.all (\c -> c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c == '-') t
  unless (safe slug) $ die "The slug may only contain a-z, 0-9 and -"
  photos <- forM specs $ \spec -> do
    let (name, rest) = T.breakOn "=" spec
        source = T.unpack (T.drop 1 rest)
    when (T.null rest || not (safe name)) $ die ("Expected name=path with a name of a-z, 0-9 and -, got: " <> spec)
    found <- doesFileExist source
    unless found $ die ("No such file: " <> T.pack source)
    pure (name, source)

  let outDir = "public/photos" </> T.unpack slug
  removePathForcibly outDir
  createDirectoryIfMissing True outDir
  createDirectoryIfMissing True "server/data/photos"
  tmp <- getTemporaryDirectory
  entries <- with (mktempdir tmp "photos") $ \dir ->
    forM photos $ \(name, source) -> do
      files <- forM widths $ \w -> do
        let px = T.pack (show w)
            scratch = dir </> "out.webp"
        procs "magick"
          [ T.pack source, "-auto-orient", "-strip"
          , "-resize", px <> "x" <> px <> "^", "-gravity", "center", "-extent", px <> "x" <> px
          , "-unsharp", "0x0.75+0.75+0.008", "-quality", "76", "-define", "webp:method=6"
          , T.pack scratch ]
          empty
        sums <- strict (inproc "sha256sum" [T.pack scratch] empty)
        let file = T.unpack name <> "-" <> show w <> "." <> T.unpack (T.take 10 sums) <> ".webp"
        renameFile scratch (outDir </> file)
        pure ("\"" <> px <> "\": \"/photos/" <> slug <> "/" <> T.pack file <> "\"")
      pure ("  \"" <> name <> "\": { " <> T.intercalate ", " files <> " }")
  T.writeFile ("server/data/photos" </> T.unpack slug <> ".json") ("{\n" <> T.intercalate ",\n" entries <> "\n}\n")
  echo (unsafeTextToLine ("Wrote " <> T.pack (show (length photos)) <> " photos to " <> T.pack outDir))
