#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle ])"
#! nix-shell -p imagemagick

-- Regenerates the brand images in public/ and brand/ from the pencil sketches
-- in brand/. Scanned paper becomes true white (#fff) by levelling; the pencil
-- stays gray. Run from the repository root:
--
--   ./scripts/brand-assets.hs

{-# LANGUAGE OverloadedStrings #-}

import Control.Monad (forM_, unless)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, getFileSize, getTemporaryDirectory)
import System.FilePath ((</>))
import Turtle hiding (FilePath, (</>))

magick :: [Text] -> IO ()
magick args = procs "magick" args empty

-- Gray, with paper levelled to white.
levelled :: FilePath -> [Text]
levelled src = [T.pack src, "-colorspace", "Gray", "-level", "35%,90%"]

main :: IO ()
main = do
  ok <- doesDirectoryExist "brand"
  unless ok $ die "Run from the repository root (no brand/ directory here)."
  tmp <- getTemporaryDirectory
  with (mktempdir tmp "brand") $ \dir -> do
    let logoFull = T.pack (dir </> "logo-full.png")
        markFull = T.pack (dir </> "mark-full.png")

    -- Wide logo: trimmed, with a little air. The white box paints out a stray
    -- speck in the scan.
    magick $ levelled "brand/logo-source.png"
      <> [ "-fill", "white", "-draw", "rectangle 1320,760 1360,800"
         , "-fuzz", "12%", "-trim", "+repage", "-bordercolor", "white", "-border", "40"
         , "-strip", logoFull ]
    magick [logoFull, "-resize", "1200x", "-strip", "public/logo.png"]

    -- Square mark: trimmed and centred on a white square.
    magick $ levelled "brand/mark-source.png"
      <> [ "-fuzz", "12%", "-trim", "+repage", "-bordercolor", "white", "-border", "24"
         , "-background", "white", "-gravity", "center"
         , "-extent", "%[fx:max(w,h)]x%[fx:max(w,h)]", "-strip", markFull ]
    magick [markFull, "-resize", "512x512", "-strip", "public/mark-512.png"]
    magick [markFull, "-resize", "180x180", "-strip", "public/apple-touch-icon.png"]

    -- Tiny sizes: thicken the pencil so it survives downscaling.
    forM_ [16, 32, 48 :: Int] $ \size -> do
      let px = T.pack (show size)
      magick [ markFull, "-morphology", "Erode", "Disk:5", "-resize", px <> "x" <> px
             , "-level", "0%,85%", "-strip", "public/favicon-" <> px <> ".png" ]
    magick ["public/favicon-16.png", "public/favicon-32.png", "public/favicon-48.png", "public/favicon.ico"]

    -- Large exports (upscaled; the sketches are about 1200px native), each
    -- under 512 KB. Not served by the site.
    magick [logoFull, "-filter", "Lanczos", "-resize", "2400x", "-colors", "128", "-depth", "8", "-strip", "PNG8:brand/logo-large.png"]
    magick [markFull, "-filter", "Lanczos", "-resize", "2048x2048", "-colors", "128", "-depth", "8", "-strip", "PNG8:brand/mark-large.png"]
    forM_ ["brand/logo-large.png", "brand/mark-large.png"] $ \f -> do
      size <- getFileSize f
      unless (size < 512 * 1024) $ die (T.pack f <> " is over 512 KB")

  -- 1200x630 social preview.
  magick [ "-size", "1200x630", "xc:white", "(", "public/logo.png", "-resize", "x540", ")"
         , "-gravity", "center", "-composite", "-depth", "8", "-colorspace", "Gray", "-strip"
         , "public/og-image.png" ]
