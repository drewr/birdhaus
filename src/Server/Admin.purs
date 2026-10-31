-- The store admin portal (/admin), for members of the Rauthy admin group: recent
-- orders, and pick-up locations, slots and the pick-up schedule. Plain tables
-- and POST forms; every write redirects back.
module Server.Admin
  ( adminOrdersPage
  , adminPickupPage
  ) where

import Prelude
import Data.Array (filter, null)
import Html (Attr(..), Html, cls, el, elVoid, text, whenH)
import Server.Layout (Chrome, layout)

type Order =
  { number :: String, date :: String, email :: String, quantity :: Int, total :: String, status :: String, method :: String }

type Location = { id :: Int, name :: String, details :: String, active :: Boolean }

type Slot = { id :: Int, location :: String, time :: String, active :: Boolean, past :: Boolean }

type Pickup = { slot :: String, email :: String, quantity :: Int, number :: String }

type OrdersVM = { | Chrome ( error :: String, orders :: Array Order ) }

type PickupVM =
  { | Chrome ( error :: String, locations :: Array Location, slots :: Array Slot, schedule :: Array Pickup ) }

adminNav :: String -> Html
adminNav current =
  el "nav" [ cls "admin-nav" ]
    [ link "/admin" "Orders"
    , link "/admin/pickup" "Pick-up"
    ]
  where
  link href label = el "a" [ cls (if href == current then "text-link admin-current" else "text-link"), A "href" href ] [ text label ]

errorLine :: String -> Html
errorLine message = whenH (message /= "") (el "p" [ cls "waitlist-error", A "role" "alert" ] [ text message ])

table :: Array String -> Array (Array Html) -> Html
table headings rows =
  el "table" [ cls "admin-table" ]
    [ el "thead" [] [ el "tr" [] (map (\h -> el "th" [] [ text h ]) headings) ]
    , el "tbody" [] (map (\cells -> el "tr" [] (map (\c -> el "td" [] [ c ]) cells)) rows)
    ]

-- A one-button form flipping an active flag.
toggle :: String -> Boolean -> Html
toggle action active =
  el "form" [ cls "admin-inline", A "method" "post", A "action" action ]
    [ elVoid "input" [ A "type" "hidden", A "name" "active", A "value" (if active then "false" else "true") ]
    , el "button" [ cls "text-button", A "type" "submit" ] [ text (if active then "Disable" else "Enable") ]
    ]

status :: Boolean -> String
status active = if active then "Active" else "Disabled"

-- ---------------------------------------------------------------- orders

adminOrdersPage :: OrdersVM -> String
adminOrdersPage vm =
  layout vm $
    el "section" [ cls "admin" ]
      [ el "h1" [] [ text "Admin" ]
      , adminNav "/admin"
      , el "h2" [ cls "section-title" ] [ text "Recent orders" ]
      , errorLine vm.error
      , if null vm.orders then el "p" [ cls "description" ] [ text "No orders yet." ]
        else
          table [ "Order", "Date", "Email", "Qty", "Total", "Status", "Delivery" ]
            (map (\o -> [ text o.number, text o.date, text o.email, text (show o.quantity), text o.total, text o.status, text o.method ]) vm.orders)
      ]

-- ---------------------------------------------------------------- pick-up

adminPickupPage :: PickupVM -> String
adminPickupPage vm =
  layout vm $
    el "section" [ cls "admin" ]
      [ el "h1" [] [ text "Admin" ]
      , adminNav "/admin/pickup"
      , errorLine vm.error
      , el "h2" [ cls "section-title" ] [ text "Pick-up schedule" ]
      , if null vm.schedule then el "p" [ cls "description" ] [ text "No paid pick-up orders yet." ]
        else table [ "Slot", "Order", "Email", "Qty" ] (map (\p -> [ text p.slot, text p.number, text p.email, text (show p.quantity) ]) vm.schedule)
      , el "h2" [ cls "section-title" ] [ text "Time slots" ]
      , if null vm.slots then el "p" [ cls "description" ] [ text "No slots yet." ]
        else
          table [ "Location", "Time", "Status", "" ]
            ( map
                ( \s ->
                    [ text s.location
                    , text s.time
                    , text (if s.past then "Past" else status s.active)
                    , toggle ("/admin/pickup/slots/" <> show s.id <> "/active") s.active
                    ]
                )
                vm.slots
            )
      , newSlotForm (filter _.active vm.locations)
      , el "h2" [ cls "section-title" ] [ text "Locations" ]
      , if null vm.locations then el "p" [ cls "description" ] [ text "No locations yet." ]
        else
          table [ "Name", "Details", "Status", "" ]
            (map (\l -> [ text l.name, text l.details, text (status l.active), toggle ("/admin/pickup/locations/" <> show l.id <> "/active") l.active ]) vm.locations)
      , newLocationForm
      ]

newSlotForm :: Array Location -> Html
newSlotForm locations =
  if null locations then el "p" [ cls "fine-print" ] [ text "Add an active location before adding time slots." ]
  else
    el "form" [ cls "admin-form", A "method" "post", A "action" "/admin/pickup/slots" ]
      [ el "h3" [] [ text "Add a time slot (US Central)" ]
      , el "label" [ A "for" "slot-location" ] [ text "Location" ]
      , el "select" [ A "id" "slot-location", A "name" "location", B "required" ]
          (map (\l -> el "option" [ A "value" (show l.id) ] [ text l.name ]) locations)
      , el "div" [ cls "admin-row" ]
          [ field "slot-date" "Date" "date" "date"
          , field "slot-start" "Starts" "start" "time"
          , field "slot-end" "Ends" "end" "time"
          ]
      , el "button" [ cls "buy-button", A "type" "submit" ] [ text "Add slot" ]
      ]
  where
  field id label name kind =
    el "div" []
      [ el "label" [ A "for" id ] [ text label ]
      , elVoid "input" [ A "id" id, A "name" name, A "type" kind, B "required" ]
      ]

newLocationForm :: Html
newLocationForm =
  el "form" [ cls "admin-form", A "method" "post", A "action" "/admin/pickup/locations" ]
    [ el "h3" [] [ text "Add a location" ]
    , el "label" [ A "for" "location-name" ] [ text "Name" ]
    , elVoid "input" [ A "id" "location-name", A "name" "name", A "type" "text", A "maxlength" "120", B "required" ]
    , el "label" [ A "for" "location-details" ] [ text "Address and instructions (shown to buyers)" ]
    , el "textarea" [ A "id" "location-details", A "name" "details", A "maxlength" "500", A "rows" "3" ] []
    , el "button" [ cls "buy-button", A "type" "submit" ] [ text "Add location" ]
    ]
