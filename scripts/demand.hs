#!/usr/bin/env nix-shell
#! nix-shell -i runghc -p "haskellPackages.ghcWithPackages (pkgs: [ pkgs.turtle pkgs.base64-bytestring ])"

-- Pre-order demand report: paid units by week and by day, refunds, the
-- waitlist, and the 7-day sell rate with a projected sell-out date.
--
-- Read-only. The SQL runs inside the Postgres instance through
-- `datumctl compute exec`; it is sent base64-encoded so no shell quoting
-- reaches it. Pass the batch's --cap to get remaining units and a projection.

{-# LANGUAGE OverloadedStrings #-}

import qualified Data.ByteString.Base64 as Base64
import Data.Foldable (for_)
import Data.Maybe (fromMaybe)
import Data.Optional (Optional (Specific))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Turtle

data Opts = Opts
  { session :: Maybe Text
  , project :: Text
  , instanceName :: Text
  , batch :: Text
  , cap :: Maybe Text
  }

parser :: Parser Opts
parser =
  Opts
    <$> optional (optText "session" 's' "datumctl session (default: the active session)")
    <*> optText "project" 'p' "Datum Cloud project"
    <*> opt "instance" 'i' "birdhaus-pg-default-us-east-1-0" "Postgres instance"
    <*> opt "batch" 'B' "xmas-2026" "Pre-order batch ID"
    <*> optional (optText "cap" 'c' "The batch's cap, for remaining units and a projection")
  where
    opt n short def help =
      optText n short (Specific (HelpMessage (help <> " (default: " <> def <> ")"))) <|> pure def

main :: IO ()
main = do
  o <- options "Report pre-order demand" parser
  for_ (session o) (export "DATUM_SESSION")
  export "DATUM_PROJECT" (project o)
  let safe t = T.all (\c -> c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9'] || c == '-') t && not (T.null t)
  unless (safe (batch o)) $ die "--batch may only contain a-z, 0-9 and -"
  for_ (cap o) $ \c -> unless (T.all (`elem` ['0' .. '9']) c && not (T.null c)) $ die "--cap must be a whole number"
  let sql = report (batch o) (fromMaybe "" (cap o))
      encoded = T.decodeUtf8 (Base64.encode (T.encodeUtf8 sql))
      command = "echo " <> encoded <> " | base64 -d | gosu postgres psql -X -q -v ON_ERROR_STOP=1 -d birdhaus"
  -- `compute exec` needs the command wrapped in sh -c, and no --project.
  procs "datumctl" ["compute", "exec", instanceName o, "--", "sh", "-c", command] empty

report :: Text -> Text -> Text
report b c =
  T.unlines
    [ "\\set batch '" <> b <> "'"
    , "\\set cap '" <> c <> "'"
    , "\\pset footer off"
    , "\\echo"
    , "\\echo 'Batch " <> b <> "'"
    , "\\echo"
    , "\\echo 'Totals'"
    , "with paid as (select * from orders where batch = :'batch' and status = 'paid'),"
    , "     rate as (select coalesce(sum(quantity), 0) as units from paid where created_at > now() - interval '7 days')"
    , "select"
    , "  (select coalesce(sum(quantity), 0) from paid) as paid_units,"
    , "  (select count(*) from paid) as orders,"
    , "  (select to_char(coalesce(sum(amount), 0) / 100.0, 'FM$999,990.00') from paid) as revenue,"
    , "  (select coalesce(sum(quantity), 0) from orders where batch = :'batch' and status = 'refunded') as refunded_units,"
    , "  (select count(*) from waitlist where batch = :'batch') as waitlist_people,"
    , "  (select coalesce(sum(quantity), 0) from waitlist where batch = :'batch') as waitlist_units,"
    , "  (select units from rate) as units_last_7_days,"
    , "  nullif(:'cap', '')::int as cap,"
    , "  nullif(:'cap', '')::int - (select coalesce(sum(quantity), 0) from paid) as remaining,"
    , "  case when (select units from rate) > 0 and nullif(:'cap', '') is not null"
    , "    then to_char(now() + (greatest(nullif(:'cap', '')::int - (select coalesce(sum(quantity), 0) from paid), 0)::numeric"
    , "      / (select units from rate) * 7) * interval '1 day', 'YYYY-MM-DD')"
    , "  end as projected_sell_out;"
    , "\\echo 'Paid units by week (weeks start Monday, US Central)'"
    , "select to_char(date_trunc('week', created_at at time zone 'America/Chicago'), 'YYYY-MM-DD') as week_of,"
    , "       count(*) as orders, sum(quantity) as units,"
    , "       to_char(sum(amount) / 100.0, 'FM$999,990.00') as revenue"
    , "from orders where batch = :'batch' and status = 'paid' group by 1 order by 1;"
    , "\\echo 'Paid units, last 14 days'"
    , "select to_char(d, 'YYYY-MM-DD Dy') as day, coalesce(sum(o.quantity), 0) as units"
    , "from generate_series((now() at time zone 'America/Chicago')::date - 13, (now() at time zone 'America/Chicago')::date, interval '1 day') d"
    , "left join orders o on o.batch = :'batch' and o.status = 'paid' and (o.created_at at time zone 'America/Chicago')::date = d::date"
    , "group by d order by d;"
    , "\\echo 'Waitlist by quantity'"
    , "select quantity, count(*) as people from waitlist where batch = :'batch' group by 1 order by 1;"
    ]
