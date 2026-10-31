#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.aeson ])"
#! nix-shell -p curl unzip

-- Regenerate server/data/zcta-centroids.json, the ZIP code centroids the local
-- delivery radius uses when only a ZIP is known (a wallet sheet hides the
-- street until the buyer confirms). The source is the Census Gazetteer ZCTA
-- file; run this when Census publishes a new year, then commit the output.
-- Run from the repo root: ./scripts/zcta-centroids.hs [--year 2025]

{-# LANGUAGE OverloadedStrings #-}

import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.ByteString.Lazy as BL
import Data.Optional (Optional (Specific))
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Turtle

main :: IO ()
main = do
  year <- options "Regenerate the ZIP code centroids for local delivery" $
    optText "year" 'y' (Specific "Gazetteer year (default: 2025)") <|> pure "2025"
  let url = "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/" <> year <> "_Gazetteer/" <> year <> "_Gaz_zcta_national.zip"
      out = "server/data/zcta-centroids.json" :: FilePath
  with (mktempdir "/tmp" "zcta") $ \dir -> do
    let zipFile = dir </> "zcta.zip"
    procs "curl" ["-fsSL", "-o", T.pack zipFile, url] empty
    (_, txt) <- procStrict "unzip" ["-p", T.pack zipFile] empty
    let rows = map (T.splitOn "|") (T.lines txt)
    case rows of
      [] -> die "The Gazetteer file is empty"
      header : body -> do
        let column name = maybe (die ("No " <> name <> " column")) pure (lookup name (zip (map T.strip header) [0 :: Int ..]))
        geoid <- column "GEOID"
        lat <- column "INTPTLAT"
        lon <- column "INTPTLONG"
        let entries =
              [ K.fromText (r !! geoid) A..= [round4 a, round4 b]
              | r <- body
              , length r > max geoid (max lat lon)
              , Right (a, _) <- [TR.signed TR.double (T.strip (r !! lat))]
              , Right (b, _) <- [TR.signed TR.double (T.strip (r !! lon))]
              ]
        when (length entries < 30000) $ die ("Only " <> repr (length entries) <> " ZIP codes parsed; refusing to write")
        mktree "server/data"
        liftIO (BL.writeFile out (A.encode (A.object entries)))
        printf ("Wrote " % d % " ZIP code centroids to " % fp % "\n") (length entries) out
  where
    -- About 11 m of precision, plenty for a radius in miles; keeps the file small.
    round4 :: Double -> Double
    round4 x = fromIntegral (round (x * 10000) :: Integer) / 10000
