-- Server-side rendering for the storefront. Every export is `record -> String`,
-- called from server/index.js. Node does all IO and formatting and passes flat,
-- JS-friendly records; these modules touch no browser types.
module Server.Render
  ( productPage
  , cartPage
  , cartFragment
  , checkoutPage
  , confirmationPage
  , waitlistFragment
  ) where

import Prelude
import Html (Attr(..), Html, cls, el, elVoid, empty, render, text, whenH)

-- Fields shared by every full page (header + <head> asset links + analytics).
type Chrome r =
  ( css :: String
  , js :: String
  , accountId :: String
  , accountLabel :: String
  , signedIn :: Boolean
  , cartQty :: Int
  , reason :: String
  | r
  )

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

type CheckoutVM =
  { | Chrome ( quantity :: Int, total :: String ) }

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
      )
  }

type WaitlistVM = { | WaitlistFields ( signedIn :: Boolean, accountLabel :: String ) }

-- ---------------------------------------------------------------- layout

layout :: forall r. { | Chrome r } -> Html -> String
layout c content =
  "<!doctype html>" <> render
    ( el "html" [ A "lang" "en" ]
        [ el "head" []
            [ elVoid "meta" [ A "charset" "UTF-8" ]
            , elVoid "meta" [ A "name" "viewport", A "content" "width=device-width, initial-scale=1.0" ]
            , elVoid "meta" [ A "name" "description", A "content" "A handcrafted bluebird house from Birdhaus." ]
            , elVoid "meta" [ A "name" "theme-color", A "content" "#ffffff" ]
            , elVoid "meta" [ A "property" "og:title", A "content" "Birdhaus — Bluebird House" ]
            , elVoid "meta" [ A "property" "og:description", A "content" "A handcrafted bluebird house from Birdhaus." ]
            , elVoid "meta" [ A "property" "og:type", A "content" "website" ]
            , elVoid "meta" [ A "property" "og:image", A "content" "https://birdhaus.store/og-image.png" ]
            , elVoid "meta" [ A "name" "twitter:card", A "content" "summary_large_image" ]
            , elVoid "link" [ A "rel" "icon", A "href" "/favicon.ico", A "sizes" "48x48" ]
            , elVoid "link" [ A "rel" "icon", A "type" "image/png", A "sizes" "32x32", A "href" "/favicon-32.png" ]
            , elVoid "link" [ A "rel" "apple-touch-icon", A "href" "/apple-touch-icon.png" ]
            , elVoid "link" [ A "rel" "preconnect", A "href" "https://fonts.googleapis.com" ]
            , elVoid "link" [ A "rel" "preconnect", A "href" "https://fonts.gstatic.com", B "crossorigin" ]
            , elVoid "link" [ A "rel" "stylesheet", A "href" "https://fonts.googleapis.com/css2?family=Architects+Daughter&display=swap" ]
            , whenH (c.css /= "") (elVoid "link" [ A "rel" "stylesheet", A "href" c.css ])
            , el "title" [] [ text "Birdhaus — Bluebird House" ]
            -- Umami analytics (umami/deploy.hs); data-domains keeps dev out of stats.
            , el "script"
                [ B "defer", A "src" "https://stats.birdhaus.store/t.js"
                , A "data-website-id" "51956e06-bdef-4268-babc-69b667a56dc5"
                , A "data-domains" "birdhaus.store"
                ] []
            , whenH (c.js /= "") (el "script" [ A "type" "module", A "src" c.js ] [])
            ]
        , el "body" [ A "data-account-id" c.accountId, A "data-batch-reason" c.reason ]
            [ header c
            , el "main" [] [ content ]
            ]
        ]
    )

header :: forall r. { | Chrome r } -> Html
header c =
  el "header" [ cls "site-header" ]
    [ el "a" [ cls "wordmark", A "href" "/" ]
        [ elVoid "img" [ cls "wordmark-mark", A "src" "/mark-512.png", A "alt" "" ]
        , text "birdhaus"
        ]
    , el "div" [ cls "header-actions" ]
        [ whenH (c.cartQty > 0) (cartLinkEl false c.cartQty)
        , el "nav" [ cls "account-nav" ]
            ( if c.signedIn then
                [ el "span" [ cls "account-email" ] [ text c.accountLabel ]
                , el "a" [ cls "text-button", A "href" "/api/auth/logout", B "data-signout" ] [ text "Sign out" ]
                ]
              else
                [ el "a" [ cls "text-link", A "href" "/api/auth/login?next=/" ] [ text "Sign in" ] ]
            )
        ]
    ]

cartLinkEl :: Boolean -> Int -> Html
cartLinkEl oob qty =
  el "a"
    ([ A "id" "cart-link", cls "cart-link", A "href" "/cart" ] <> (if oob then [ A "hx-swap-oob" "true" ] else []))
    [ text ("Cart · " <> show qty) ]

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
        [ text ((if vm.shipBy == "" then "" else "Pre-order: you're charged today and your house ships by " <> vm.shipBy <> ". Full refund any time before it ships, or if we miss that date. ") <> "Shipping and taxes are not included.") ]
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
          [ text ((if vm.shipBy == "" then "" else "Pre-order: you're charged today and your house ships by " <> vm.shipBy <> ". Full refund any time before it ships, or if we miss that date. ") <> "Shipping and taxes are not included.") ]
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

checkoutPage :: CheckoutVM -> String
checkoutPage vm =
  layout vm $
    el "section" [ A "id" "checkout", cls "checkout", A "aria-labelledby" "checkout-title", A "data-quantity" (show vm.quantity) ]
      [ el "h2" [ A "id" "checkout-title" ] [ text "Checkout" ]
      , el "p" [ cls "checkout-total" ] [ text (show vm.quantity <> " × Bluebird House · " <> vm.total) ]
      , el "form" [ A "id" "payment-form" ]
          [ el "label" [ A "for" "email" ] [ text "Email for receipt" ]
          , elVoid "input" [ A "id" "email", A "name" "email", A "type" "email", B "required", A "placeholder" "you@example.com" ]
          , el "label" [] [ text "Shipping address" ]
          , el "div" [ A "id" "shipping-address" ] []
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
        [ text (if vm.shipBy == "" then "Your payment went through and your bluebird house is on its way to the workshop."
                else "Your payment went through. Your bluebird house is on the workshop's list and will ship by " <> vm.shipBy <> ".") ]
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

orderSummary :: OrderVM -> Html
orderSummary vm =
  el "dl" [ cls "order-summary" ]
    ( [ el "dt" [] [ text "Order" ], el "dd" [] [ text vm.number ]
      , el "dt" [] [ text "Date" ], el "dd" [] [ text vm.date ]
      , el "dt" [] [ text "Items" ], el "dd" [] [ text vm.items ]
      , el "dt" [] [ text "Total" ], el "dd" [] [ text vm.total ]
      ] <> shipToRows vm.shipTo
    )

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
