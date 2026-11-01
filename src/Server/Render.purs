-- Server-side rendering for the storefront. Every export is `record -> String`,
-- called from server/index.js. Node does all IO and formatting and passes flat,
-- JS-friendly records; these modules touch no browser types.
module Server.Render
  ( homePage
  , loginPage
  , codePage
  , productsPage
  , productPage
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
import Server.Admin (adminDeliveryPage, adminOrdersPage, adminPickupPage)
import Server.Layout (Chrome, cartLinkEl, layout, layoutWithHero)

type WaitlistFields r =
  ( wlState :: String        -- "editing" | "joined" | "error"
  , wlMessage :: String      -- error text, or the joined quantity
  , wlEmail :: String
  , wlQuantity :: String
  , wlPostalCode :: String
  , signInHref :: String
  , signUpHref :: String
  | r
  )

type HomeVM = { | Chrome () }

-- The server builds every href, so next is encoded once, in JavaScript.
type LoginVM =
  { | Chrome
      ( authEnabled :: Boolean
      , emailEnabled :: Boolean
      , next :: String
      , googleHref :: String
      , loginEmail :: String
      , loginError :: String
      , signupName :: String
      , signupEmail :: String
      , signupError :: String
      )
  }

-- signingUp only changes the wording; the server knows which it is.
type CodeVM = { | Chrome ( email :: String, signingUp :: Boolean, error :: String, notice :: String ) }

-- One listing card; price and availability are formatted by the server.
type ProductCard =
  { href :: String, name :: String, summary :: String, image :: String, imageAlt :: String, price :: String, availability :: String }

type ProductsVM = { | Chrome ( products :: Array ProductCard ) }

type ProductVM =
  { | Chrome
      ( WaitlistFields
          ( slug :: String
          , name :: String
          , summary :: String
          , image :: String
          , imageAlt :: String
          , open :: Boolean
          , batched :: Boolean -- sold through the pre-order batch, with its waitlist
          , details :: Boolean -- the Bluebird House's feature, spec and FAQ sections
          , inCart :: Int -- this product's quantity in the cart
          , shipBy :: String
          , remaining :: Int
          , priceEach :: String
          , maxQuantity :: Int
          , fulfillmentNote :: String
          )
      )
  }

type CartVM =
  { | Chrome ( productName :: String, lineTotal :: String, subtotal :: String, shipBy :: String, maxQuantity :: Int, fulfillmentNote :: String ) }

type Slot = { id :: Int, location :: String, details :: String, time :: String, selected :: Boolean }

type DeliverySlot = { id :: Int, time :: String, selected :: Boolean }

type DeliveryVM =
  { | Chrome
      ( quantity :: Int
      , productName :: String
      , total :: String
      , error :: String
      , slots :: Array Slot
      , deliveryFee :: String
      , deliveryRadius :: String
      , deliverySlots :: Array DeliverySlot
      )
  }

-- subtotalCents and feeCents only label the wallet sheet; the server sets the amount.
type CheckoutVM =
  { | Chrome
      ( quantity :: Int
      , productName :: String
      , subtotal :: String
      , total :: String
      , fulfillment :: String
      , choiceLabel :: String
      , fee :: String
      , subtotalCents :: Int
      , feeCents :: Int
      , email :: String
      )
  }

type OrderVM =
  { | Chrome
      ( status :: String
      , message :: String
      , number :: String
      , date :: String
      , items :: String
      , productName :: String
      , total :: String
      , email :: String
      , shipTo :: Array String
      , shipBy :: String
      , quantity :: Int
      , fulfillment :: String
      , pickupLabel :: String
      , deliveryLabel :: String
      )
  }

type WaitlistVM = { | WaitlistFields ( signedIn :: Boolean, accountLabel :: String ) }

-- ---------------------------------------------------------------- home

-- The copy and image are placeholders until the owner writes them.
homePage :: HomeVM -> String
homePage vm = layoutWithHero vm hero empty
  where
  hero =
    el "section" [ cls "hero", A "aria-label" "Welcome" ]
      [ el "div" [ cls "hero-inner" ]
          [ el "div" [ cls "hero-copy" ]
              [ el "p" [ cls "description" ]
                  [ text "Hi there! Haven't you wanted your own "
                  , el "strong" [] [ text "birdhouse" ]
                  , text " for Eastern Bluebirds?"
                  ]
              , el "p" [ cls "description" ] [ text "It's very ", el "em" [] [ text "easy" ], text ":" ]
              , el "ol" [ cls "description" ]
                  [ el "li" [] [ el "a" [ A "href" "/login#create" ] [ text "Sign up" ], text " to create your free account," ]
                  , el "li" [] [ el "a" [ A "href" "/products" ] [ text "Shop" ], text " to get yours today, and" ]
                  , el "li" [] [ text "Add yourself to the waiting list to get notified when new birdhouses are available" ]
                  ]
              ]
          , el "figure" [ cls "hero-figure" ]
              [ elVoid "img" [ cls "hero-image", A "src" "/hero-birdhaus.jpg", A "width" "1400", A "height" "1180", A "alt" "A Birdhaus bluebird house held up in a backyard" ] ]
          ]
      ]

-- ---------------------------------------------------------------- login

-- Two clear choices, log in or create an account, each with Google or an
-- emailed code. Everything happens here: Google passes through Rauthy without
-- stopping, and email accounts live in Rauthy behind the store's API calls.
loginPage :: LoginVM -> String
loginPage vm =
  layout vm $
    el "section" [ cls "login", A "aria-labelledby" "login-title" ]
      [ el "h1" [ cls "page-title", A "id" "login-title" ] [ text "Welcome to Birdhaus" ]
      , if vm.signedIn then signedInNote else if vm.authEnabled then panels else accountsOff
      ]
  where
  panels =
    el "div" [ cls "login-panels" ]
      [ el "div" [ cls "login-panel" ]
          [ el "h2" [ cls "login-heading" ] [ text "Log in" ]
          , el "a" [ cls "secondary-button", A "href" vm.googleHref ] [ text "Continue with Google" ]
          , whenH vm.emailEnabled $
              emailForm "/login/email" "login"
                [ field "login-email" "email" "Email" "email" vm.loginEmail ]
                vm.loginError
                "Email me a code"
          ]
      , el "p" [ cls "login-or", A "aria-hidden" "true" ] [ text "or" ]
      , el "div" [ cls "login-panel", A "id" "create" ]
          [ el "h2" [ cls "login-heading" ] [ text "Create your account" ]
          , el "p" [ cls "description" ] [ text "You'll need one to check out and to join the waitlist. It also keeps your orders in one place." ]
          , el "a" [ cls "secondary-button", A "href" vm.googleHref ] [ text "Sign up with Google" ]
          , whenH vm.emailEnabled $
              emailForm "/signup/email" "signup"
                [ field "signup-name" "name" "Name" "name" vm.signupName
                , field "signup-email" "email" "Email" "email" vm.signupEmail
                ]
                vm.signupError
                "Email me a code"
          ]
      ]

  emailForm action purpose fields error label =
    el "form" [ cls "login-email", A "method" "post", A "action" action ]
      ( [ elVoid "input" [ A "type" "hidden", A "name" "next", A "value" vm.next ] ]
          <> fields
          <> [ whenH (error /= "") (el "p" [ cls "waitlist-error", A "role" "alert", A "id" (purpose <> "-error") ] [ text error ])
             , el "button" [ cls "buy-button", A "type" "submit" ] [ text label ]
             , el "p" [ cls "fine-print" ] [ text "We'll email you a 6-digit code. No password needed." ]
             ]
      )

  field id name label kind value =
    el "div" []
      [ el "label" [ A "for" id ] [ text label ]
      , elVoid "input"
          ( [ A "id" id, A "name" name, A "type" (if kind == "email" then "email" else "text"), A "autocomplete" kind, B "required", A "value" value ]
              <> (if kind == "email" then [ A "placeholder" "you@example.com" ] else [ A "maxlength" "32" ])
          )
      ]

  signedInNote =
    el "div" [ cls "login-signed-in" ]
      [ el "p" [ cls "description" ] [ text ("You're signed in as " <> vm.accountLabel <> ".") ]
      , el "a" [ cls "buy-button", A "href" vm.next ] [ text "Continue" ]
      , el "a" [ cls "text-button", A "href" "/api/auth/logout", B "data-signout" ] [ text "Sign out" ]
      ]

  accountsOff =
    el "p" [ cls "description" ]
      [ text "Accounts aren't available right now. Please try again shortly, or "
      , el "a" [ cls "text-link", A "href" "/products" ] [ text "browse the products" ]
      , text "."
      ]

codePage :: CodeVM -> String
codePage vm =
  layout vm $
    el "section" [ cls "login login-code", A "aria-labelledby" "code-title" ]
      [ el "h1" [ cls "page-title", A "id" "code-title" ] [ text "Check your email" ]
      , el "p" [ cls "description" ]
          [ text "We sent a 6-digit code to ", el "strong" [] [ text vm.email ], text (if vm.signingUp then ". Enter it to create your account." else ". Enter it to log in.") ]
      , whenH (vm.notice /= "") (el "p" [ cls "login-notice", A "role" "status" ] [ text vm.notice ])
      , el "form" [ cls "login-email", A "method" "post", A "action" "/login/code" ]
          [ el "label" [ A "for" "login-code" ] [ text "Code" ]
          , elVoid "input"
              [ A "id" "login-code", A "name" "code", A "type" "text", A "inputmode" "numeric", A "pattern" "[0-9 ]*"
              , A "autocomplete" "one-time-code", A "maxlength" "7", B "required", B "autofocus"
              ]
          , whenH (vm.error /= "") (el "p" [ cls "waitlist-error", A "role" "alert" ] [ text vm.error ])
          , el "button" [ cls "buy-button", A "type" "submit" ] [ text (if vm.signingUp then "Create account" else "Log in") ]
          ]
      , el "form" [ cls "login-resend", A "method" "post", A "action" "/login/resend" ]
          [ el "button" [ cls "text-button", A "type" "submit" ] [ text "Send a new code" ]
          , el "a" [ cls "text-button", A "href" "/login" ] [ text "Use a different email" ]
          ]
      ]

-- ---------------------------------------------------------------- products

productsPage :: ProductsVM -> String
productsPage vm =
  layout vm $
    el "section" [ cls "products", A "aria-labelledby" "products-title" ]
      [ el "h1" [ cls "page-title", A "id" "products-title" ] [ text "Products" ]
      , el "ul" [ cls "product-grid" ] (map card vm.products)
      ]
  where
  card p =
    el "li" []
      [ el "a" [ cls "product-card", A "href" p.href ]
          [ el "span" [ cls "product-card-figure" ]
              [ elVoid "img" [ cls "product-card-image", A "src" p.image, A "alt" p.imageAlt ] ]
          , el "span" [ cls "product-card-name" ] [ text p.name ]
          , el "span" [ cls "product-card-summary" ] [ text p.summary ]
          , el "span" [ cls "product-card-price" ] [ text p.price ]
          , el "span" [ cls "product-card-availability" ] [ text p.availability ]
          ]
      ]

-- ---------------------------------------------------------------- product

productPage :: ProductVM -> String
productPage vm =
  layout vm $
    el "div" []
      [ el "section" [ cls "product", A "aria-labelledby" "product-title" ]
          [ productMedia vm
          , el "div" [ cls "product-details" ]
              [ el "h1" [ cls "page-title", A "id" "product-title" ] [ text vm.name ]
              , el "p" [ cls "price" ] [ text (vm.priceEach <> " each") ]
              , whenH (vm.shipBy /= "") (el "p" [ cls "preorder-note" ] [ text ("Pre-order · ships by " <> vm.shipBy) ])
              , el "p" [ cls "description" ] [ text vm.summary ]
              , if vm.open then purchase vm else soldOut vm
              ]
          ]
      , whenH vm.details (featureSection <> specSection <> trustStrip <> faqSection)
      ]

productMedia :: ProductVM -> Html
productMedia vm =
  el "div" [ cls "product-media" ]
    [ el "figure" [ cls "product-figure" ]
        [ elVoid "img" [ cls "product-illustration", A "src" vm.image, A "alt" vm.imageAlt ]
        , el "figcaption" [ cls "product-figcaption" ] [ text "Illustration — product photos coming soon." ]
        ]
    ]

purchase :: ProductVM -> Html
purchase vm =
  el "div" []
    [ whenH (vm.remaining >= 0) (el "p" [ cls "stock-note" ] [ text ("Only " <> show vm.remaining <> " left in this batch") ])
    , el "form" [ cls "add-form", A "method" "post", A "action" "/cart/add" ]
        [ elVoid "input" [ A "type" "hidden", A "name" "product", A "value" vm.slug ]
        , el "div" [ cls "quantity-field" ]
            [ el "label" [ A "for" "qty" ] [ text "Quantity" ]
            , elVoid "input" [ A "id" "qty", A "name" "quantity", A "type" "number", A "min" "1", A "max" (show vm.maxQuantity), A "value" "1", B "required" ]
            ]
        , el "button" [ cls "buy-button", A "type" "submit" ]
            [ text (if vm.inCart > 0 then "Add to cart (" <> show vm.inCart <> " in cart)" else "Add to cart") ]
        ]
    , el "p" [ cls "fine-print" ]
        [ text ((if vm.shipBy == "" then "" else "Pre-order: you're charged today and your house ships by " <> vm.shipBy <> ". Full refund any time before it ships, or if we miss that date. ") <> vm.fulfillmentNote) ]
    , whenH vm.batched $
        el "details" [ cls "waitlist-inline" ]
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
  , signInHref: vm.signInHref, signUpHref: vm.signUpHref, signedIn: vm.signedIn, accountLabel: vm.accountLabel
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
      [ el "h1" [ cls "page-title", A "id" "cart-title" ] [ text "Your cart" ]
      , cartBox vm
      , el "a" [ cls "buy-button", A "href" "/checkout" ] [ text "Proceed to checkout" ]
      , el "a" [ cls "text-button", A "href" "/products" ] [ text "Continue shopping" ]
      , el "p" [ cls "fine-print" ]
          [ text ((if vm.shipBy == "" then "" else "Pre-order: you're charged today and your house ships by " <> vm.shipBy <> ". Full refund any time before it ships, or if we miss that date. ") <> vm.fulfillmentNote) ]
      ]

-- The #cart box, re-rendered in place by the HTMX stepper.
cartBox :: CartVM -> Html
cartBox vm =
  el "div" [ A "id" "cart", cls "cart" ]
    [ el "div" [ cls "cart-line" ]
        [ el "span" [] [ text vm.productName ]
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
      , el "p" [ cls "checkout-total" ] [ text (show vm.quantity <> " × " <> vm.productName <> " · " <> vm.total) ]
      , el "form" [ cls "delivery-form", A "method" "post", A "action" "/checkout/delivery" ]
          ( [ el "label" [ cls "delivery-option delivery-option-disabled" ]
                [ elVoid "input" [ A "type" "radio", A "name" "method", A "value" "ship", B "disabled" ]
                , el "span" [] [ el "strong" [] [ text "Shipping" ], text " — coming soon" ]
                ]
            , whenH (vm.error /= "") (el "p" [ cls "waitlist-error", A "role" "alert" ] [ text vm.error ])
            , el "p" [ cls "delivery-heading" ] [ el "strong" [] [ text "Local pick-up" ], text " — free. Choose a time:" ]
            ]
              <> (if null vm.slots then [ el "p" [ cls "description" ] [ text "No pick-up times are open right now — check back soon." ] ] else map slotOption vm.slots)
              <> deliveryOptions vm
              <> (if null vm.slots && null vm.deliverySlots then [] else [ el "button" [ cls "buy-button", A "type" "submit" ] [ text "Continue to payment" ] ])
          )
      , el "div" [ cls "checkout-actions" ]
          [ el "a" [ cls "text-button", A "href" "/cart" ] [ text "Back to cart" ] ]
      ]

-- Local delivery appears only while an admin has it switched on and slots open.
deliveryOptions :: DeliveryVM -> Array Html
deliveryOptions vm
  | null vm.deliverySlots = []
  | otherwise =
      [ el "p" [ cls "delivery-heading" ]
          [ el "strong" [] [ text "Local delivery" ]
          , text (" — " <> vm.deliveryFee <> ", within " <> vm.deliveryRadius <> " miles. Choose a time:")
          ]
      ]
        <> map deliverySlotOption vm.deliverySlots

slotOption :: Slot -> Html
slotOption slot =
  el "label" [ cls "delivery-option" ]
    [ choiceInput ("pickup:" <> show slot.id) slot.selected
    , el "span" []
        [ el "strong" [] [ text slot.location ]
        , text (" — " <> slot.time)
        , whenH (slot.details /= "") (el "span" [ cls "delivery-details" ] [ text slot.details ])
        ]
    ]

deliverySlotOption :: DeliverySlot -> Html
deliverySlotOption slot =
  el "label" [ cls "delivery-option" ]
    [ choiceInput ("delivery:" <> show slot.id) slot.selected
    , el "span" [] [ el "strong" [] [ text "Delivery" ], text (" — " <> slot.time) ]
    ]

choiceInput :: String -> Boolean -> Html
choiceInput value selected =
  elVoid "input" ([ A "type" "radio", A "name" "choice", A "value" value, B "required" ] <> (if selected then [ B "checked" ] else []))

-- Step 2: pay. Wallet buttons (Express Checkout) sit above the card form. For
-- delivery the wallet supplies the address, or the card path's Address Element
-- does; pick-up needs none. The data attributes only label the wallet sheet.
checkoutPage :: CheckoutVM -> String
checkoutPage vm =
  layout vm $
    el "section"
      [ A "id" "checkout", cls "checkout", A "aria-labelledby" "checkout-title"
      , A "data-quantity" (show vm.quantity), A "data-fulfillment" vm.fulfillment, A "data-slot-label" vm.choiceLabel
      , A "data-product-name" vm.productName, A "data-subtotal-cents" (show vm.subtotalCents), A "data-fee-cents" (show vm.feeCents)
      ]
      [ el "h2" [ A "id" "checkout-title" ] [ text "Checkout" ]
      , el "dl" [ cls "order-summary checkout-breakdown" ]
          ( [ el "dt" [] [ text (show vm.quantity <> " × " <> vm.productName) ], el "dd" [] [ text vm.subtotal ] ]
              <> choiceRows
              <> [ el "dt" [] [ text "Total" ], el "dd" [] [ text vm.total ] ]
          )
      , el "p" [ cls "fine-print" ] [ el "a" [ cls "text-link", A "href" "/checkout" ] [ text (if delivering then "Change delivery time" else "Change pick-up time") ] ]
      , el "div" [ A "id" "express-checkout" ] []
      , el "form" [ A "id" "payment-form" ]
          ( [ el "label" [ A "for" "email" ] [ text "Email for receipt" ]
            , elVoid "input" [ A "id" "email", A "name" "email", A "type" "email", B "required", A "placeholder" "you@example.com", A "value" vm.email ]
            ]
              <> (if delivering then [ el "label" [] [ text "Delivery address" ], el "div" [ A "id" "shipping-address" ] [] ] else [])
              <>
                [ el "div" [ A "id" "payment-element" ] []
                , el "div" [ A "id" "payment-message", A "role" "alert", A "aria-live" "polite" ] []
                , el "button" [ A "id" "submit-payment", cls "buy-button" ] [ text ("Pay " <> vm.total) ]
                ]
          )
      , el "div" [ cls "checkout-actions" ]
          [ el "a" [ cls "text-button", A "href" "/cart" ] [ text "Back to cart" ]
          , el "p" [ cls "fine-print" ] [ text "Secure payment by Stripe." ]
          ]
      ]
  where
  delivering = vm.fulfillment == "delivery"
  choiceRows
    | delivering =
        [ el "dt" [] [ text "Local delivery" ], el "dd" [] [ text (vm.choiceLabel <> " — " <> vm.fee) ] ]
    | otherwise =
        [ el "dt" [] [ text "Pick-up" ], el "dd" [] [ text (vm.choiceLabel <> " — free") ] ]

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
    [ el "h1" [ cls "page-title" ] [ text (if vm.shipBy == "" then "Thank you for your order" else "Thank you for your pre-order") ]
    , el "p" [ cls "confirmation-lede" ]
        [ text (succeededLede vm) ]
    , orderSummary vm
    , receiptNote vm "A receipt has been sent to "
    , backToStore "Back to the store"
    ]
  "processing" ->
    [ el "h1" [ cls "page-title" ] [ text "Your payment is processing" ]
    , el "p" [ cls "confirmation-lede" ] [ text "We've received your order. Your bank is still confirming the payment, which usually takes a moment." ]
    , orderSummary vm
    , receiptNote vm "We'll send a receipt to "
    , backToStore "Back to the store"
    ]
  "failed" ->
    [ el "h1" [ cls "page-title" ] [ text "Your payment didn't go through" ]
    , el "p" [ cls "confirmation-lede" ] [ text (if vm.message == "" then "You have not been charged." else vm.message <> " You have not been charged.") ]
    , backToStore "Return to the store to try again"
    ]
  _ ->
    [ el "h1" [ cls "page-title" ] [ text "Thank you for your order" ]
    , el "p" [ cls "confirmation-lede" ] [ text "We couldn't load your order details right now. If your payment went through, a receipt is on its way to your email." ]
    , backToStore "Back to the store"
    ]

succeededLede :: OrderVM -> String
succeededLede vm
  | vm.fulfillment == "pickup" = "Your payment went through. Your " <> vm.productName <> " will be ready for pick-up: " <> vm.pickupLabel <> "."
  | vm.fulfillment == "delivery" = "Your payment went through. We'll deliver your " <> vm.productName <> " " <> vm.deliveryLabel <> "."
  | vm.shipBy == "" = "Your payment went through and your " <> vm.productName <> " is on its way to the workshop."
  | otherwise = "Your payment went through. Your " <> vm.productName <> " is on the workshop's list and will ship by " <> vm.shipBy <> "."

orderSummary :: OrderVM -> Html
orderSummary vm =
  el "dl" [ cls "order-summary" ]
    ( [ el "dt" [] [ text "Order" ], el "dd" [] [ text vm.number ]
      , el "dt" [] [ text "Date" ], el "dd" [] [ text vm.date ]
      , el "dt" [] [ text "Items" ], el "dd" [] [ text vm.items ]
      , el "dt" [] [ text "Total" ], el "dd" [] [ text vm.total ]
      ] <> fulfillmentRows vm
    )

fulfillmentRows :: OrderVM -> Array Html
fulfillmentRows vm = case vm.fulfillment of
  "pickup" -> pickupRows vm.pickupLabel
  "delivery" -> [ el "dt" [] [ text "Delivery" ], el "dd" [] [ text vm.deliveryLabel ] ] <> shipToRows "Deliver to" vm.shipTo
  _ -> shipToRows "Ship to" vm.shipTo

pickupRows :: String -> Array Html
pickupRows "" = []
pickupRows label = [ el "dt" [] [ text "Pick-up" ], el "dd" [] [ text label ] ]

shipToRows :: String -> Array String -> Array Html
shipToRows _ [] = []
shipToRows label lines =
  [ el "dt" [] [ text label ]
  , el "dd" [ cls "ship-to" ] (map (\line -> el "span" [] [ text line ]) lines)
  ]

receiptNote :: OrderVM -> String -> Html
receiptNote vm prefix =
  if vm.email == "" then empty
  else el "p" [ cls "fine-print" ] [ text prefix, el "strong" [] [ text vm.email ], text "." ]

backToStore :: String -> Html
backToStore label = el "a" [ cls "text-link", A "href" "/products" ] [ text label ]

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
          | otherwise -> signUpCta
    ]
  where
  joinedEmail = if vm.signedIn && vm.accountLabel /= "" then vm.accountLabel else vm.wlEmail

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

  signUpCta =
    el "div" [ cls "waitlist-signup" ]
      [ el "p" [ cls "description" ] [ text "Create a free account to join the waitlist, so we can reach you when we build more." ]
      , el "a" [ cls "buy-button", A "href" vm.signUpHref ] [ text "Create an account" ]
      , el "p" [ cls "fine-print" ]
          [ text "Already have one? "
          , el "a" [ cls "text-link", A "href" vm.signInHref ] [ text "Sign in" ]
          ]
      ]
