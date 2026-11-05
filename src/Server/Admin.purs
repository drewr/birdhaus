-- The store admin portal (/admin), for members of the Rauthy admin group: recent
-- orders; users; inventory; pick-up locations, slots and schedule; local delivery
-- settings, slots and schedule; page copy. Plain tables and POST forms; writes
-- redirect back.
module Server.Admin
  ( adminOrdersPage
  , adminUsersPage
  , adminPickupPage
  , adminDeliveryPage
  , adminCopyPage
  , adminInventoryPage
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

-- waiting lists the products this person is waiting to hear are back.
type User = { email :: String, name :: String, since :: String, orders :: Int, spent :: String, lastOrder :: String, waiting :: String }

-- filter is the name of the product the list is narrowed to, or empty.
type UsersVM = { | Chrome ( error :: String, filter :: String, users :: Array User ) }

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

-- available is meaningless when untracked; below 0 means oversold. price is
-- dollars, like "40.00". A change is to the count or the price; from is "—"
-- for the starting count.
type Change = { at :: String, from :: String, to :: String, reason :: String }

type Stock =
  { slug :: String, name :: String, tracked :: Boolean, available :: Int, price :: String, sold :: Int, waiting :: Int, changes :: Array Change }

type InventoryVM = { | Chrome ( error :: String, notice :: String, products :: Array Stock ) }

type PickupVM =
  { | Chrome ( error :: String, locations :: Array Location, slots :: Array Slot, schedule :: Array Pickup ) }

adminNav :: String -> Html
adminNav current =
  el "nav" [ cls "admin-nav" ]
    [ link "/admin" "Orders"
    , link "/admin/users" "Users"
    , link "/admin/inventory" "Inventory"
    , link "/admin/pickup" "Pick-up"
    , link "/admin/delivery" "Delivery"
    , link "/admin/site" "Page copy"
    ]
  where
  link href label = el "a" [ cls (if href == current then "text-link admin-current" else "text-link"), A "href" href ] [ text label ]

errorLine :: String -> Html
errorLine message = whenH (message /= "") (el "p" [ cls "waitlist-error ui-status ui-status--danger", A "role" "alert" ] [ text message ])

table :: Array String -> Array (Array Html) -> Html
table headings rows =
  -- Scrolls sideways on its own when wider than a phone, not the page.
  el "div" [ cls "admin-table ui-table-scroll" ]
    [ el "table" [ cls "ui-table ui-table--mist" ]
        [ el "thead" [] [ el "tr" [] (map (\h -> el "th" [] [ text h ]) headings) ]
        , el "tbody" [] (map (\cells -> el "tr" [] (map (\c -> el "td" [] [ c ]) cells)) rows)
        ]
    ]

-- A one-button form flipping an active flag.
toggle :: String -> Boolean -> Html
toggle action active =
  el "form" [ cls "admin-inline", A "method" "post", A "action" action ]
    [ elVoid "input" [ A "type" "hidden", A "name" "active", A "value" (if active then "false" else "true") ]
    , el "button" [ cls "text-button ui-button ui-button--link", A "type" "submit" ] [ text (if active then "Disable" else "Enable") ]
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

-- ---------------------------------------------------------------- users

adminUsersPage :: UsersVM -> String
adminUsersPage vm =
  layout vm $
    el "section" [ cls "admin" ]
      [ el "h1" [ cls "page-title" ] [ text "Admin" ]
      , adminNav "/admin/users"
      , if vm.filter == "" then el "h2" [ cls "section-title" ] [ text "Users" ]
        else el "h2" [ cls "section-title" ] [ text ("Waiting for " <> vm.filter) ]
      , whenH (vm.filter /= "") $
          el "p" [ cls "fine-print" ] [ text "Oldest request first. ", el "a" [ cls "text-link", A "href" "/admin/users" ] [ text "Show everyone" ] ]
      , errorLine vm.error
      , if null vm.users then el "p" [ cls "description" ] [ text (if vm.filter == "" then "Nobody yet." else "Nobody is waiting.") ]
        else
          table [ "Email", "Name", "Since", "Orders", "Spent", "Last order", "Waiting for" ]
            (map (\u -> [ text u.email, text u.name, text u.since, text (show u.orders), text u.spent, text u.lastOrder, text u.waiting ]) vm.users)
      ]

-- ---------------------------------------------------------------- inventory

adminInventoryPage :: InventoryVM -> String
adminInventoryPage vm =
  layout vm $
    el "section" [ cls "admin" ]
      ( [ el "h1" [ cls "page-title" ] [ text "Admin" ]
        , adminNav "/admin/inventory"
        , el "h2" [ cls "section-title" ] [ text "Inventory" ]
        , el "p" [ cls "description" ] [ text "The price of each product and how many shoppers can buy. Each paid order counts down; refunds don't add back. A new price applies from the next checkout." ]
        , errorLine vm.error
        , whenH (vm.notice /= "") (el "p" [ cls "admin-notice ui-alert ui-alert--success", A "role" "status" ] [ text vm.notice ])
        ]
          <> map stockForm vm.products
      )

stockForm :: Stock -> Html
stockForm p =
  el "div" [ cls "admin-form admin-stock" ]
    ( [ el "h3" [] [ text p.name ]
      , whenH (p.tracked && p.available < 0)
          (el "p" [ cls "admin-oversold ui-alert ui-alert--danger", A "role" "alert" ] [ text ("Oversold by " <> show (negate p.available) <> ". Refund an order or make more, then set the count.") ])
      , el "div" [ cls "admin-row" ]
          [ el "form" [ A "method" "post", A "action" ("/admin/inventory/" <> p.slug <> "/price") ]
              [ el "label" [ A "for" ("price-" <> p.slug) ] [ text "Price ($)" ]
              , elVoid "input" [ A "id" ("price-" <> p.slug), A "name" "price", A "type" "number", A "min" "0.50", A "max" "1000", A "step" "0.01", A "value" p.price, B "required" ]
              , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Save price" ]
              ]
          , if not p.tracked then el "p" [ cls "fine-print" ] [ text "Stock not tracked: always available." ]
            else
              el "form" [ A "method" "post", A "action" ("/admin/inventory/" <> p.slug) ]
                [ elVoid "input" [ A "type" "hidden", A "name" "expected", A "value" (show p.available) ]
                , el "label" [ A "for" ("stock-" <> p.slug) ] [ text "Available" ]
                , elVoid "input" [ A "id" ("stock-" <> p.slug), A "name" "available", A "type" "number", A "min" "0", A "max" "999999", A "step" "1", A "value" (show (max 0 p.available)), B "required" ]
                , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Save count" ]
                ]
          ]
      ]
        <>
          ( if not p.tracked then []
            else
              [ el "p" [ cls "fine-print" ] ([ text (show p.sold <> " sold in all. ") ] <> waitingLine)
              , whenH (p.waiting > 0 && p.available > 0) $
                  el "form" [ cls "admin-inline", A "method" "post", A "action" ("/admin/inventory/" <> p.slug <> "/notify") ]
                    [ el "button" [ cls "text-button ui-button ui-button--link", A "type" "submit" ] [ text ("Email " <> people p.waiting <> " that it's back") ] ]
              ]
          )
        <>
          [ whenH (not (null p.changes)) $
              el "details" [ cls "admin-history" ]
                [ el "summary" [ cls "text-button ui-button ui-button--link" ] [ text "Recent changes" ]
                , table [ "When", "From", "To", "Why" ] (map (\c -> [ text c.at, text c.from, text c.to, text c.reason ]) p.changes)
                ]
          ]
    )
  where
  people n = if n == 1 then "1 person" else show n <> " people"
  waitingLine
    | p.waiting == 0 = [ text "Nobody is waiting to hear it's back." ]
    | p.available > 0 = [ waitingLink, text " waiting to hear it's back." ]
    | otherwise = [ waitingLink, text " waiting to hear it's back; raise the count to email them." ]
  waitingLink = el "a" [ cls "text-link", A "href" ("/admin/users?waiting=" <> p.slug) ] [ text (people p.waiting) ]

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
      , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Add slot" ]
      ]

newLocationForm :: Html
newLocationForm =
  el "form" [ cls "admin-form", A "method" "post", A "action" "/admin/pickup/locations" ]
    [ el "h3" [] [ text "Add a location" ]
    , el "label" [ A "for" "location-name" ] [ text "Name" ]
    , elVoid "input" [ A "id" "location-name", A "name" "name", A "type" "text", A "maxlength" "120", B "required" ]
    , el "label" [ A "for" "location-details" ] [ text "Address and instructions (shown to buyers)" ]
    , el "textarea" [ A "id" "location-details", A "name" "details", A "maxlength" "500", A "rows" "3" ] []
    , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Add location" ]
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
    , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Save settings" ]
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
    , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Add slot" ]
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
    , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Save" ]
    ]
