-- Server-side rendering for the storefront. Every export is `record -> String`,
-- called from server/index.js. Node does all IO and formatting and passes flat,
-- JS-friendly records; these modules touch no browser types.
module Server.Render
  ( productPage
  , cartPage
  , cartFragment
  , deliveryPage
  , checkoutPage
  , confirmationPage
  , waitlistFragment
  , module Server.Admin
  ) where

import Prelude
import Data.Array (null)
import Html (Attr(..), Html, cls, el, elVoid, empty, render, text, whenH)
import Server.Admin (adminOrdersPage, adminPickupPage)
import Server.Layout (Chrome, cartLinkEl, layout)

type WaitlistFields r =
  ( wlState :: String        -- "editing" | "joined" | "error"
  , wlMessage :: String      -- error text, or the joined quantity
  , wlEmail :: String
  , wlQuantity :: String
  , wlPostalCode :: String
  , authEnabled :: Boolean
  , signUpUrl :: String
  | r
  )

type ProductVM =
  { | Chrome
      ( WaitlistFields
          ( open :: Boolean
          , shipBy :: String
          , remaining :: Int
          , priceEach :: String
          , maxQuantity :: Int
          )
      )
  }

type CartVM =
  { | Chrome ( lineTotal :: String, subtotal :: String, shipBy :: String, maxQuantity :: Int ) }

type Slot = { id :: Int, location :: String, details :: String, time :: String, selected :: Boolean }

type DeliveryVM =
  { | Chrome ( quantity :: Int, total :: String, error :: String, slots :: Array Slot ) }

type CheckoutVM =
  { | Chrome ( quantity :: Int, subtotal :: String, total :: String, pickupLabel :: String, email :: String ) }

type OrderVM =
  { | Chrome
      ( status :: String
      , message :: String
      , number :: String
      , date :: String
      , items :: String
      , total :: String
      , email :: String
      , shipTo :: Array String
      , shipBy :: String
      , quantity :: Int
      , fulfillment :: String
      , pickupLabel :: String
      )
  }

type WaitlistVM = { | WaitlistFields ( signedIn :: Boolean, accountLabel :: String ) }

-- ---------------------------------------------------------------- product

productPage :: ProductVM -> String
productPage vm =
  layout vm $
    el "div" []
      [ el "section" [ cls "product", A "aria-labelledby" "product-title" ]
          [ productMedia
          , el "div" [ cls "product-details" ]
              [ el "h1" [ A "id" "product-title" ] [ text "Bluebird House" ]
              , el "p" [ cls "price" ] [ text (vm.priceEach <> " each") ]
              , whenH (vm.shipBy /= "") (el "p" [ cls "preorder-note" ] [ text ("Pre-order · ships by " <> vm.shipBy) ])
              , el "p" [ cls "description" ] [ text "A simple home for backyard bluebirds." ]
              , if vm.open then purchase vm else soldOut vm
              ]
          ]
      , featureSection
      , specSection
      , trustStrip
      , faqSection
      ]

productMedia :: Html
productMedia =
  el "div" [ cls "product-media" ]
    [ el "figure" [ cls "product-figure" ]
        [ elVoid "img" [ cls "product-illustration", A "src" "/product-illustration.svg", A "alt" "Illustration of a bluebird house" ]
        , el "figcaption" [ cls "product-figcaption" ] [ text "Illustration — product photos coming soon." ]
        ]
    ]

purchase :: ProductVM -> Html
purchase vm =
  el "div" []
    [ whenH (vm.remaining >= 0) (el "p" [ cls "stock-note" ] [ text ("Only " <> show vm.remaining <> " left in this batch") ])
    , el "form" [ cls "add-form", A "method" "post", A "action" "/cart/add" ]
        [ el "div" [ cls "quantity-field" ]
            [ el "label" [ A "for" "qty" ] [ text "Quantity" ]
            , elVoid "input" [ A "id" "qty", A "name" "quantity", A "type" "number", A "min" "1", A "max" (show vm.maxQuantity), A "value" "1", B "required" ]
            ]
        , el "button" [ cls "buy-button", A "type" "submit" ]
            [ text (if vm.cartQty > 0 then "Add to cart (" <> show vm.cartQty <> " in cart)" else "Add to cart") ]
        ]
    , el "p" [ cls "fine-print" ]
        [ text ((if vm.shipBy == "" then "" else "Pre-order: you're charged today and your house ships by " <> vm.shipBy <> ". Full refund any time before it ships, or if we miss that date. ") <> "Local pick-up only for now — shipping coming soon. Taxes not included.") ]
    , el "details" [ cls "waitlist-inline" ]
        [ el "summary" [ cls "text-button" ] [ text "Need more? Join the waitlist" ]
        , el "p" [ cls "description" ] [ text "Need more than this batch has? Tell us how many and we'll email you when we can build them." ]
        , waitlistView (toWaitlist vm)
        ]
    ]

soldOut :: ProductVM -> Html
soldOut vm =
  el "div" [ cls "sold-out" ]
    [ el "h2" [] [ text (if vm.reason == "closed" then "Pre-orders have closed" else "This batch is sold out") ]
    , el "p" [ cls "description" ] [ text "Join the waitlist and we'll email you first when we can build more. No payment needed." ]
    , waitlistView (toWaitlist vm)
    ]

toWaitlist :: ProductVM -> WaitlistVM
toWaitlist vm =
  { wlState: vm.wlState, wlMessage: vm.wlMessage, wlEmail: vm.wlEmail, wlQuantity: vm.wlQuantity, wlPostalCode: vm.wlPostalCode
  , authEnabled: vm.authEnabled, signUpUrl: vm.signUpUrl, signedIn: vm.signedIn, accountLabel: vm.accountLabel
  }

featureSection :: Html
featureSection =
  el "section" [ cls "info", A "aria-label" "Features" ]
    [ sectionTitle "Built for bluebirds"
    , el "ul" [ cls "feature-list" ]
        [ feature false "1½-inch entrance hole" "Sized to the North American Bluebird Society standard: the right fit for bluebirds, too small for starlings. No perch, which predators would use."
        , feature true "Ventilation" "[Describe the vents that keep the box cool in summer.]"
        , feature true "Drainage" "[Describe the floor drainage that keeps the nest dry.]"
        , feature true "Easy cleanout" "[Describe the hinged or sliding panel for seasonal cleaning.]"
        , feature true "Simple mounting" "[Describe how it mounts — pole, post or screws — and the recommended height.]"
        , feature true "Built to last" "[Describe the wood and hardware — e.g. rot-resistant cedar, rust-resistant screws, no nails.]"
        ]
    ]

feature :: Boolean -> String -> String -> Html
feature pending title desc =
  el "li" [ cls "feature" ]
    [ el "span" [ cls "feature-check", A "aria-hidden" "true" ] [ text "✓" ]
    , el "div" []
        [ el "p" [ cls "feature-title" ] [ text title ]
        , el "p" [ cls (if pending then "feature-desc spec-todo" else "feature-desc") ] [ text desc ]
        ]
    ]

specSection :: Html
specSection =
  el "section" [ cls "info", A "aria-label" "Specifications" ]
    [ sectionTitle "Specifications"
    , el "dl" [ cls "spec-list" ]
        ( specRow true "Material" "[Wood species and grade — e.g. kiln-dried red cedar]"
            <> specRow true "Dimensions" "[Height × width × depth]"
            <> specRow true "Weight" "[Shipping weight]"
            <> specRow false "Entrance hole" "1½ in, about 6 in above the floor"
            <> specRow true "Base footprint" "[Interior floor, width × depth]"
            <> specRow true "Hardware" "[e.g. rust-resistant screws, no nails]"
            <> specRow true "Made in" "[Origin]"
        )
    ]

specRow :: Boolean -> String -> String -> Array Html
specRow pending label value =
  [ el "dt" [] [ text label ]
  , el "dd" (if pending then [ cls "spec-todo" ] else []) [ text value ]
  ]

trustStrip :: Html
trustStrip =
  el "section" [ cls "trust-strip", A "aria-label" "What to expect" ]
    [ trustItem true "Satisfaction guarantee" "[Your returns or guarantee policy.]"
    , trustItem true "Shipping" "[Shipping cost and delivery time.]"
    , trustItem false "Secure checkout" "Payments are processed by Stripe."
    ]

trustItem :: Boolean -> String -> String -> Html
trustItem pending title desc =
  el "div" [ cls "trust-item" ]
    [ el "h3" [] [ text title ]
    , el "p" (if pending then [ cls "spec-todo" ] else []) [ text desc ]
    ]

faqSection :: Html
faqSection =
  el "section" [ cls "info", A "aria-label" "Questions" ]
    [ sectionTitle "Questions"
    , el "div" [ cls "faq-list" ]
        [ faqItem "How do I mount it, and how high?" "[Your mounting guidance. Bluebird houses usually sit 5–6 feet up, in the open, away from heavy foot traffic.]"
        , faqItem "How do I keep sparrows and predators out?" "[The 1½-inch hole already blocks starlings. Add any guidance on house sparrows, baffles or predator guards.]"
        , faqItem "How do I clean it?" "[Your cleaning instructions, and how the box opens for it.]"
        , faqItem "Does it come assembled?" "[Assembled or flat-pack, and what's in the box.]"
        , faqItem "When will it ship?" "[Shipping timing — for a pre-order, tie this to the current batch's ship-by date.]"
        ]
    ]

faqItem :: String -> String -> Html
faqItem question answer =
  el "details" [ cls "faq-item" ]
    [ el "summary" [] [ text question ]
    , el "p" [ cls "faq-answer spec-todo" ] [ text answer ]
    ]

sectionTitle :: String -> Html
sectionTitle t = el "h2" [ cls "section-title" ] [ text t ]

-- ---------------------------------------------------------------- cart

cartPage :: CartVM -> String
cartPage vm =
  layout vm $
    el "section" [ cls "cart-screen", A "aria-labelledby" "cart-title" ]
      [ el "h1" [ A "id" "cart-title" ] [ text "Your cart" ]
      , cartBox vm
      , el "a" [ cls "buy-button", A "href" "/checkout" ] [ text "Proceed to checkout" ]
      , el "a" [ cls "text-button", A "href" "/" ] [ text "Continue shopping" ]
      , el "p" [ cls "fine-print" ]
          [ text ((if vm.shipBy == "" then "" else "Pre-order: you're charged today and your house ships by " <> vm.shipBy <> ". Full refund any time before it ships, or if we miss that date. ") <> "Local pick-up only for now — shipping coming soon. Taxes not included.") ]
      ]

-- The #cart box, re-rendered in place by the HTMX stepper.
cartBox :: CartVM -> Html
cartBox vm =
  el "div" [ A "id" "cart", cls "cart" ]
    [ el "div" [ cls "cart-line" ]
        [ el "span" [] [ text "Bluebird House" ]
        , el "span" [] [ text vm.lineTotal ]
        ]
    , stepper vm.cartQty vm.maxQuantity
    , el "p" [ cls "cart-total" ] [ text ("Subtotal · " <> vm.subtotal) ]
    ]

-- Returned by POST /cart/update: the swapped #cart plus an out-of-band update
-- of the header cart count.
cartFragment :: CartVM -> String
cartFragment vm = render (cartBox vm <> cartLinkEl true vm.cartQty)

stepper :: Int -> Int -> Html
stepper qty maxQ =
  el "div" [ cls "quantity-control", A "aria-label" "Quantity" ]
    [ stepButton (qty - 1) (qty <= 1) "Decrease quantity" "−"
    , el "span" [ A "aria-live" "polite", A "aria-atomic" "true" ] [ text (show qty) ]
    , stepButton (qty + 1) (qty >= maxQ) "Increase quantity" "+"
    ]

stepButton :: Int -> Boolean -> String -> String -> Html
stepButton target disabled label symbol =
  el "button"
    ( [ cls "quantity-button", A "type" "button"
      , A "hx-post" "/cart/update"
      , A "hx-vals" ("{\"quantity\": " <> show target <> "}")
      , A "hx-target" "#cart", A "hx-swap" "outerHTML"
      , A "aria-label" label
      ] <> (if disabled then [ B "disabled" ] else [])
    )
    [ text symbol ]

-- ---------------------------------------------------------------- checkout

-- Step 1: delivery. Shipping is listed but disabled until USPS pricing exists.
deliveryPage :: DeliveryVM -> String
deliveryPage vm =
  layout vm $
    el "section" [ cls "checkout", A "aria-labelledby" "delivery-title" ]
      [ el "h2" [ A "id" "delivery-title" ] [ text "Delivery" ]
      , el "p" [ cls "checkout-total" ] [ text (show vm.quantity <> " × Bluebird House · " <> vm.total) ]
      , el "form" [ cls "delivery-form", A "method" "post", A "action" "/checkout/delivery" ]
          ( [ el "label" [ cls "delivery-option delivery-option-disabled" ]
                [ elVoid "input" [ A "type" "radio", A "name" "method", A "value" "ship", B "disabled" ]
                , el "span" [] [ el "strong" [] [ text "Shipping" ], text " — coming soon" ]
                ]
            , el "p" [ cls "delivery-heading" ] [ el "strong" [] [ text "Local pick-up" ], text " — free. Choose a time:" ]
            , whenH (vm.error /= "") (el "p" [ cls "waitlist-error", A "role" "alert" ] [ text vm.error ])
            ]
              <>
                if null vm.slots then
                  [ el "p" [ cls "description" ] [ text "No pick-up times are open right now — check back soon." ] ]
                else
                  map slotOption vm.slots
                    <> [ el "button" [ cls "buy-button", A "type" "submit" ] [ text "Continue to payment" ] ]
          )
      , el "div" [ cls "checkout-actions" ]
          [ el "a" [ cls "text-button", A "href" "/cart" ] [ text "Back to cart" ] ]
      ]

slotOption :: Slot -> Html
slotOption slot =
  el "label" [ cls "delivery-option" ]
    [ elVoid "input" ([ A "type" "radio", A "name" "slot", A "value" (show slot.id), B "required" ] <> (if slot.selected then [ B "checked" ] else []))
    , el "span" []
        [ el "strong" [] [ text slot.location ]
        , text (" — " <> slot.time)
        , whenH (slot.details /= "") (el "span" [ cls "delivery-details" ] [ text slot.details ])
        ]
    ]

-- Step 2: pay. Pick-up needs no address, so only the Payment Element mounts.
checkoutPage :: CheckoutVM -> String
checkoutPage vm =
  layout vm $
    el "section" [ A "id" "checkout", cls "checkout", A "aria-labelledby" "checkout-title", A "data-quantity" (show vm.quantity) ]
      [ el "h2" [ A "id" "checkout-title" ] [ text "Checkout" ]
      , el "dl" [ cls "order-summary checkout-breakdown" ]
          [ el "dt" [] [ text (show vm.quantity <> " × Bluebird House") ], el "dd" [] [ text vm.subtotal ]
          , el "dt" [] [ text "Pick-up" ], el "dd" [] [ text (vm.pickupLabel <> " — free") ]
          , el "dt" [] [ text "Total" ], el "dd" [] [ text vm.total ]
          ]
      , el "p" [ cls "fine-print" ] [ el "a" [ cls "text-link", A "href" "/checkout" ] [ text "Change pick-up time" ] ]
      , el "form" [ A "id" "payment-form" ]
          [ el "label" [ A "for" "email" ] [ text "Email for receipt" ]
          , elVoid "input" [ A "id" "email", A "name" "email", A "type" "email", B "required", A "placeholder" "you@example.com", A "value" vm.email ]
          , el "div" [ A "id" "payment-element" ] []
          , el "div" [ A "id" "payment-message", A "role" "alert", A "aria-live" "polite" ] []
          , el "button" [ A "id" "submit-payment", cls "buy-button" ] [ text ("Pay " <> vm.total) ]
          ]
      , el "div" [ cls "checkout-actions" ]
          [ el "a" [ cls "text-button", A "href" "/cart" ] [ text "Back to cart" ]
          , el "p" [ cls "fine-print" ] [ text "Secure payment by Stripe." ]
          ]
      ]

-- ---------------------------------------------------------------- confirmation

confirmationPage :: OrderVM -> String
confirmationPage vm =
  layout vm $
    el "section"
      [ A "id" "payment-success", cls "confirmation", A "aria-live" "polite"
      , A "data-order-status" vm.status, A "data-order-quantity" (show vm.quantity)
      ]
      (confirmationBody vm)

confirmationBody :: OrderVM -> Array Html
confirmationBody vm = case vm.status of
  "succeeded" ->
    [ el "h1" [] [ text (if vm.shipBy == "" then "Thank you for your order" else "Thank you for your pre-order") ]
    , el "p" [ cls "confirmation-lede" ]
        [ text (succeededLede vm) ]
    , orderSummary vm
    , receiptNote vm "A receipt has been sent to "
    , backToStore "Back to the store"
    ]
  "processing" ->
    [ el "h1" [] [ text "Your payment is processing" ]
    , el "p" [ cls "confirmation-lede" ] [ text "We've received your order. Your bank is still confirming the payment, which usually takes a moment." ]
    , orderSummary vm
    , receiptNote vm "We'll send a receipt to "
    , backToStore "Back to the store"
    ]
  "failed" ->
    [ el "h1" [] [ text "Your payment didn't go through" ]
    , el "p" [ cls "confirmation-lede" ] [ text (if vm.message == "" then "You have not been charged." else vm.message <> " You have not been charged.") ]
    , backToStore "Return to the store to try again"
    ]
  _ ->
    [ el "h1" [] [ text "Thank you for your order" ]
    , el "p" [ cls "confirmation-lede" ] [ text "We couldn't load your order details right now. If your payment went through, a receipt is on its way to your email." ]
    , backToStore "Back to the store"
    ]

succeededLede :: OrderVM -> String
succeededLede vm
  | vm.fulfillment == "pickup" = "Your payment went through. Your bluebird house will be ready for pick-up: " <> vm.pickupLabel <> "."
  | vm.shipBy == "" = "Your payment went through and your bluebird house is on its way to the workshop."
  | otherwise = "Your payment went through. Your bluebird house is on the workshop's list and will ship by " <> vm.shipBy <> "."

orderSummary :: OrderVM -> Html
orderSummary vm =
  el "dl" [ cls "order-summary" ]
    ( [ el "dt" [] [ text "Order" ], el "dd" [] [ text vm.number ]
      , el "dt" [] [ text "Date" ], el "dd" [] [ text vm.date ]
      , el "dt" [] [ text "Items" ], el "dd" [] [ text vm.items ]
      , el "dt" [] [ text "Total" ], el "dd" [] [ text vm.total ]
      ] <> (if vm.fulfillment == "pickup" then pickupRows vm.pickupLabel else shipToRows vm.shipTo)
    )

pickupRows :: String -> Array Html
pickupRows "" = []
pickupRows label = [ el "dt" [] [ text "Pick-up" ], el "dd" [] [ text label ] ]

shipToRows :: Array String -> Array Html
shipToRows [] = []
shipToRows lines =
  [ el "dt" [] [ text "Ship to" ]
  , el "dd" [ cls "ship-to" ] (map (\line -> el "span" [] [ text line ]) lines)
  ]

receiptNote :: OrderVM -> String -> Html
receiptNote vm prefix =
  if vm.email == "" then empty
  else el "p" [ cls "fine-print" ] [ text prefix, el "strong" [] [ text vm.email ], text "." ]

backToStore :: String -> Html
backToStore label = el "a" [ cls "text-link", A "href" "/" ] [ text label ]

-- ---------------------------------------------------------------- waitlist

waitlistFragment :: WaitlistVM -> String
waitlistFragment = render <<< waitlistView

waitlistView :: WaitlistVM -> Html
waitlistView vm =
  el "div" [ A "id" "waitlist", cls "waitlist" ]
    [ case vm.wlState of
        "joined" ->
          el "p" [ cls "waitlist-joined", A "role" "status", A "data-waitlist-joined" "true" ]
            [ text ("You're on the waitlist for " <> vm.wlQuantity <> ". We'll email " <> joinedEmail <> " when we can build more.") ]
        _
          | vm.signedIn -> memberForm
          | vm.authEnabled -> signUpCta
          | otherwise -> guestForm
    ]
  where
  joinedEmail = if vm.signedIn && vm.accountLabel /= "" then vm.accountLabel else vm.wlEmail
  signUpHref = if vm.signUpUrl == "" then "/api/auth/login?next=/" else vm.signUpUrl

  wlForm kids =
    el "form"
      [ cls "waitlist-form", A "method" "post", A "action" "/waitlist"
      , A "hx-post" "/waitlist", A "hx-target" "#waitlist", A "hx-swap" "outerHTML"
      ] kids

  quantityZip =
    el "div" [ cls "waitlist-row" ]
      [ el "div" []
          [ el "label" [ A "for" "waitlist-quantity" ] [ text "How many" ]
          , elVoid "input" [ A "id" "waitlist-quantity", A "name" "quantity", A "type" "number", B "required", A "min" "1", A "max" "99", A "value" (if vm.wlQuantity == "" then "1" else vm.wlQuantity) ]
          ]
      , el "div" []
          [ el "label" [ A "for" "waitlist-zip" ] [ text "ZIP code (optional)" ]
          , elVoid "input" [ A "id" "waitlist-zip", A "name" "postalCode", A "type" "text", A "autocomplete" "postal-code", A "value" vm.wlPostalCode ]
          ]
      ]

  errorLine =
    if vm.wlState == "error"
      then el "p" [ cls "waitlist-error", A "role" "alert" ] [ text vm.wlMessage ]
      else empty

  submitButton = el "button" [ cls "buy-button" ] [ text "Join the waitlist" ]

  memberForm =
    wlForm
      [ el "p" [ cls "fine-print" ] [ text ("Signed in as " <> vm.accountLabel <> ". We'll email you there.") ]
      , quantityZip
      , errorLine
      , submitButton
      ]

  guestForm =
    wlForm
      [ el "label" [ A "for" "waitlist-email" ] [ text "Email" ]
      , elVoid "input" [ A "id" "waitlist-email", A "name" "email", A "type" "email", B "required", A "placeholder" "you@example.com", A "value" vm.wlEmail ]
      , quantityZip
      , errorLine
      , submitButton
      ]

  signUpCta =
    el "div" [ cls "waitlist-signup" ]
      [ el "p" [ cls "description" ] [ text "Create a free account to join the waitlist, so we can reach you when we build more." ]
      , el "a" [ cls "buy-button", A "href" signUpHref ] [ text "Create an account" ]
      , el "p" [ cls "fine-print" ]
          [ text "Already have one? "
          , el "a" [ cls "text-link", A "href" "/api/auth/login?next=/" ] [ text "Sign in" ]
          ]
      ]
