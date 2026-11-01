-- The store admin portal (/admin), for members of the Rauthy admin group: recent
-- orders; pick-up locations, slots and schedule; local delivery settings, slots
-- and schedule; page copy. Plain tables and POST forms; writes redirect back.
module Server.Admin
  ( adminOrdersPage
  , adminPickupPage
  , adminDeliveryPage
  , adminCopyPage
  ) where

import Prelude
import Data.Array (filter, null)
import Html (Attr(..), Html, cls, el, elVoid, text, whenH)
import Server.Layout (Chrome, layout)

type Order =
  { number :: String, date :: String, email :: String, product :: String, quantity :: Int, total :: String, status :: String, method :: String }

type Location = { id :: Int, name :: String, details :: String, active :: Boolean }

type Slot = { id :: Int, location :: String, time :: String, active :: Boolean, past :: Boolean }

type Pickup = { slot :: String, email :: String, product :: String, quantity :: Int, number :: String }

type OrdersVM = { | Chrome ( error :: String, orders :: Array Order ) }

type DeliverySlot = { id :: Int, time :: String, active :: Boolean, past :: Boolean }

-- check is how the radius was verified: exact, zip, mismatch or none.
type Delivery =
  { slot :: String, number :: String, name :: String, phone :: String, address :: String, product :: String, quantity :: Int, check :: String }

type DeliveryVM =
  { | Chrome
      ( error :: String
      , enabled :: Boolean
      , fee :: String
      , radius :: String
      , baseAddress :: String
      , baseFound :: String
      , slots :: Array DeliverySlot
      , schedule :: Array Delivery
      )
  }

-- body is the section's source (saved or built-in); saved says which.
type CopySection = { key :: String, label :: String, page :: String, body :: String, saved :: String }

type CopyVM = { | Chrome ( error :: String, sections :: Array CopySection ) }

type PickupVM =
  { | Chrome ( error :: String, locations :: Array Location, slots :: Array Slot, schedule :: Array Pickup ) }

adminNav :: String -> Html
adminNav current =
  el "nav" [ cls "admin-nav" ]
    [ link "/admin" "Orders"
    , link "/admin/pickup" "Pick-up"
    , link "/admin/delivery" "Delivery"
    , link "/admin/site" "Page copy"
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
      [ el "h1" [ cls "page-title" ] [ text "Admin" ]
      , adminNav "/admin"
      , el "h2" [ cls "section-title" ] [ text "Recent orders" ]
      , errorLine vm.error
      , if null vm.orders then el "p" [ cls "description" ] [ text "No orders yet." ]
        else
          table [ "Order", "Date", "Email", "Product", "Qty", "Total", "Status", "Delivery" ]
            (map (\o -> [ text o.number, text o.date, text o.email, text o.product, text (show o.quantity), text o.total, text o.status, text o.method ]) vm.orders)
      ]

-- ---------------------------------------------------------------- pick-up

adminPickupPage :: PickupVM -> String
adminPickupPage vm =
  layout vm $
    el "section" [ cls "admin" ]
      [ el "h1" [ cls "page-title" ] [ text "Admin" ]
      , adminNav "/admin/pickup"
      , errorLine vm.error
      , el "h2" [ cls "section-title" ] [ text "Pick-up schedule" ]
      , if null vm.schedule then el "p" [ cls "description" ] [ text "No paid pick-up orders yet." ]
        else table [ "Slot", "Order", "Email", "Product", "Qty" ] (map (\p -> [ text p.slot, text p.number, text p.email, text p.product, text (show p.quantity) ]) vm.schedule)
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
          [ inputField "slot-date" "Date" "date" "date"
          , inputField "slot-start" "Starts" "start" "time"
          , inputField "slot-end" "Ends" "end" "time"
          ]
      , el "button" [ cls "buy-button", A "type" "submit" ] [ text "Add slot" ]
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

-- ---------------------------------------------------------------- delivery

adminDeliveryPage :: DeliveryVM -> String
adminDeliveryPage vm =
  layout vm $
    el "section" [ cls "admin" ]
      [ el "h1" [ cls "page-title" ] [ text "Admin" ]
      , adminNav "/admin/delivery"
      , errorLine vm.error
      , el "h2" [ cls "section-title" ] [ text "Delivery schedule" ]
      , if null vm.schedule then el "p" [ cls "description" ] [ text "No paid delivery orders yet." ]
        else
          table [ "Slot", "Order", "Name", "Phone", "Address", "Product", "Qty", "Address check" ]
            ( map
                (\d -> [ text d.slot, text d.number, text d.name, text d.phone, text d.address, text d.product, text (show d.quantity), text (checkLabel d.check) ])
                vm.schedule
            )
      , el "h2" [ cls "section-title" ] [ text "Settings" ]
      , settingsForm vm
      , el "h2" [ cls "section-title" ] [ text "Delivery slots" ]
      , if null vm.slots then el "p" [ cls "description" ] [ text "No slots yet." ]
        else
          table [ "Time", "Status", "" ]
            ( map
                (\d -> [ text d.time, text (if d.past then "Past" else status d.active), toggle ("/admin/delivery/slots/" <> show d.id <> "/active") d.active ])
                vm.slots
            )
      , newDeliverySlotForm
      ]

-- Orders that weren't checked against the exact street address need a look.
checkLabel :: String -> String
checkLabel = case _ of
  "exact" -> "Street address"
  "zip" -> "ZIP only — check distance"
  "mismatch" -> "Changed after check — verify"
  _ -> "Not checked — verify"

settingsForm :: DeliveryVM -> Html
settingsForm vm =
  el "form" [ cls "admin-form", A "method" "post", A "action" "/admin/delivery/settings" ]
    [ el "label" [ cls "admin-check" ]
        [ elVoid "input" ([ A "type" "checkbox", A "name" "enabled" ] <> (if vm.enabled then [ B "checked" ] else []))
        , text " Offer local delivery at checkout"
        ]
    , el "div" [ cls "admin-row" ]
        [ el "div" []
            [ el "label" [ A "for" "delivery-fee" ] [ text "Fee per order ($)" ]
            , elVoid "input" [ A "id" "delivery-fee", A "name" "fee", A "type" "number", A "min" "0", A "step" "0.01", A "value" vm.fee, B "required" ]
            ]
        , el "div" []
            [ el "label" [ A "for" "delivery-radius" ] [ text "Radius (miles)" ]
            , elVoid "input" [ A "id" "delivery-radius", A "name" "radius", A "type" "number", A "min" "0.1", A "step" "0.1", A "value" vm.radius, B "required" ]
            ]
        ]
    , el "label" [ A "for" "delivery-base" ] [ text "Home base (street, city, state ZIP)" ]
    , elVoid "input" [ A "id" "delivery-base", A "name" "baseAddress", A "type" "text", A "maxlength" "300", A "value" vm.baseAddress, A "placeholder" "1100 Congress Ave, Austin, TX 78701", B "required" ]
    , el "p" [ cls "fine-print" ]
        [ text (if vm.baseFound == "" then "Not located yet; saving looks the address up with the US Census geocoder." else "Located at " <> vm.baseFound <> ". Distances are measured from here.") ]
    , el "button" [ cls "buy-button", A "type" "submit" ] [ text "Save settings" ]
    ]

newDeliverySlotForm :: Html
newDeliverySlotForm =
  el "form" [ cls "admin-form", A "method" "post", A "action" "/admin/delivery/slots" ]
    [ el "h3" [] [ text "Add a delivery slot (US Central)" ]
    , el "div" [ cls "admin-row" ]
        [ inputField "dslot-date" "Date" "date" "date"
        , inputField "dslot-start" "Starts" "start" "time"
        , inputField "dslot-end" "Ends" "end" "time"
        ]
    , el "button" [ cls "buy-button", A "type" "submit" ] [ text "Add slot" ]
    ]

-- A labelled required input for the slot forms.
inputField :: String -> String -> String -> String -> Html
inputField id label name kind =
  el "div" []
    [ el "label" [ A "for" id ] [ text label ]
    , elVoid "input" [ A "id" id, A "name" name, A "type" kind, B "required" ]
    ]

-- ---------------------------------------------------------------- page copy

adminCopyPage :: CopyVM -> String
adminCopyPage vm =
  layout vm $
    el "section" [ cls "admin" ]
      ( [ el "h1" [ cls "page-title" ] [ text "Admin" ]
        , adminNav "/admin/site"
        , el "h2" [ cls "section-title" ] [ text "Page copy" ]
        , el "p" [ cls "description" ] [ text "Write in Markdown or HTML. Scripts and styles are removed. Leave a section empty to go back to its built-in text." ]
        , errorLine vm.error
        ]
          <> map copyForm vm.sections
      )

copyForm :: CopySection -> Html
copyForm s =
  el "form" [ cls "admin-form admin-copy", A "method" "post", A "action" ("/admin/site/" <> s.key) ]
    [ el "h3" [] [ text s.label ]
    , el "p" [ cls "fine-print" ] [ text (s.saved <> " "), el "a" [ cls "text-link", A "href" s.page ] [ text "View page" ] ]
    , el "label" [ A "for" ("copy-" <> s.key) ] [ text "Text" ]
    , el "textarea" [ A "id" ("copy-" <> s.key), A "name" "body", A "rows" "14", A "maxlength" "20000" ] [ text s.body ]
    , el "button" [ cls "buy-button", A "type" "submit" ] [ text "Save" ]
    ]
