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
  , notifyFragment
  , module Server.Admin
  ) where

import Prelude
import Data.Array (null)
import Html (Attr(..), Html, cls, el, elVoid, empty, raw, render, text, whenH)
import Server.Admin (adminCopyPage, adminDeliveryPage, adminInventoryPage, adminOrdersPage, adminPickupPage)
import Server.Layout (Chrome, cartLinkEl, layout, layoutWithHero)

-- "Notify me when available" on a product that isn't selling. notifyState is
-- "ready" (show the button), "requested" or "error"; loginHref is where a
-- signed-out shopper signs in first, and is empty in the POST /notify fragment.
type NotifyFields r =
  ( slug :: String
  , notifyState :: String
  , notifyEmail :: String
  , loginHref :: String
  | r
  )

-- welcome is admin-edited copy, already rendered and sanitized (server/copy.js).
type HomeVM = { | Chrome ( welcome :: String ) }

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
-- srcset is empty when the image is an illustration rather than a photo.
type ProductCard =
  { href :: String, name :: String, summary :: String, image :: String, imageAlt :: String, srcset :: String, price :: String, availability :: String }

-- A detail-page thumbnail: a link to ?photo=<name> that the client turns into
-- an in-place swap using src, srcset and alt.
type Thumb = { href :: String, src :: String, srcset :: String, alt :: String, thumb :: String, current :: Boolean }

type ProductsVM = { | Chrome ( products :: Array ProductCard ) }

type ProductVM =
  { | Chrome
      ( NotifyFields
          ( name :: String
          , summary :: String
          , image :: String -- the photo shown, or the illustration
          , imageAlt :: String
          , srcset :: String -- empty for an illustration
          , thumbs :: Array Thumb -- empty unless there are photos to choose between
          , open :: Boolean
          , reason :: String -- "open" | "sold-out" | "unavailable"
          , details :: Boolean -- the Bluebird House's feature, spec and FAQ sections
          , inCart :: Int -- this product's quantity in the cart
          , remaining :: Int -- how many are left when that's few, else -1
          , priceEach :: String
          , maxQuantity :: Int -- what can be added on top of the cart
          , fulfillmentNote :: String
          )
      )
  }

-- cartQty 0 means the product sold out and was removed; notice says why the
-- cart changed, and checkoutOk is false while stock can't be checked.
type CartVM =
  { | Chrome
      ( productName :: String
      , productHref :: String
      , lineTotal :: String
      , subtotal :: String
      , maxQuantity :: Int
      , notice :: String
      , checkoutOk :: Boolean
      , fulfillmentNote :: String
      )
  }

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

-- subtotalCents and feeCents label the wallet sheet and let the server catch a
-- price that changed since the page loaded; the server sets the amount.
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
      , quantity :: Int
      , fulfillment :: String
      , pickupLabel :: String
      , deliveryLabel :: String
      )
  }

type NotifyVM = { | NotifyFields () }

-- ---------------------------------------------------------------- home

-- The copy is edited at /admin/site; the image is fixed.
homePage :: HomeVM -> String
homePage vm = layoutWithHero vm hero empty
  where
  hero =
    el "section" [ cls "hero", A "aria-label" "Welcome" ]
      [ el "div" [ cls "hero-inner" ]
          [ el "div" [ cls "hero-copy prose" ] [ raw vm.welcome ]
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
          , el "a" [ cls "secondary-button ui-button ui-button--outline ui-button--block", A "href" vm.googleHref ] [ text "Continue with Google" ]
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
          , el "a" [ cls "secondary-button ui-button ui-button--outline ui-button--block", A "href" vm.googleHref ] [ text "Sign up with Google" ]
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
          <> [ whenH (error /= "") (el "p" [ cls "waitlist-error ui-status ui-status--danger", A "role" "alert", A "id" (purpose <> "-error") ] [ text error ])
             , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text label ]
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
      , el "a" [ cls "buy-button ui-button ui-button--block", A "href" vm.next ] [ text "Continue" ]
      , el "a" [ cls "text-button ui-button ui-button--link", A "href" "/api/auth/logout", B "data-signout" ] [ text "Sign out" ]
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
      , whenH (vm.notice /= "") (el "p" [ cls "login-notice ui-alert ui-alert--info", A "role" "status" ] [ text vm.notice ])
      , el "form" [ cls "login-email", A "method" "post", A "action" "/login/code" ]
          [ el "label" [ A "for" "login-code" ] [ text "Code" ]
          , elVoid "input"
              [ A "id" "login-code", A "name" "code", A "type" "text", A "inputmode" "numeric", A "pattern" "[0-9 ]*"
              , A "autocomplete" "one-time-code", A "maxlength" "7", B "required", B "autofocus"
              ]
          , whenH (vm.error /= "") (el "p" [ cls "waitlist-error ui-status ui-status--danger", A "role" "alert" ] [ text vm.error ])
          , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text (if vm.signingUp then "Create account" else "Log in") ]
          ]
      , el "form" [ cls "login-resend", A "method" "post", A "action" "/login/resend" ]
          [ el "button" [ cls "text-button ui-button ui-button--link", A "type" "submit" ] [ text "Send a new code" ]
          , el "a" [ cls "text-button ui-button ui-button--link", A "href" "/login" ] [ text "Use a different email" ]
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
          [ el "span" [ cls (if p.srcset == "" then "product-card-figure" else "product-card-figure product-card-photo") ]
              [ elVoid "img"
                  ( [ cls "product-card-image", A "src" p.image, A "alt" p.imageAlt ]
                      <> photoAttrs p.srcset "(max-width: 480px) 100vw, 340px"
                  )
              ]
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
              , el "p" [ cls "description" ] [ text vm.summary ]
              , if vm.open then purchase vm else unavailable vm
              ]
          ]
      , whenH vm.details (featureSection <> specSection <> trustStrip <> faqSection)
      ]

productMedia :: ProductVM -> Html
productMedia vm =
  el "div" [ cls "product-media" ]
    [ if vm.srcset == "" then
        el "figure" [ cls "product-figure" ]
          [ elVoid "img" [ cls "product-illustration", A "src" vm.image, A "alt" vm.imageAlt ] ]
      else
        el "figure" [ cls "product-photo-figure" ]
          [ elVoid "img"
              ( [ cls "product-photo", A "id" "product-photo", A "src" vm.image, A "alt" vm.imageAlt ]
                  <> photoAttrs vm.srcset "(max-width: 1023px) 100vw, 600px"
              )
          ]
    , whenH (not (null vm.thumbs)) $
        el "ul" [ cls "product-thumbs", A "aria-label" "Photos" ] (map thumbLink vm.thumbs)
    ]

thumbLink :: Thumb -> Html
thumbLink t =
  el "li" []
    [ el "a"
        [ cls "product-thumb", A "href" t.href, A "aria-current" (if t.current then "true" else "false")
        , A "data-src" t.src, A "data-srcset" t.srcset, A "data-alt" t.alt
        ]
        [ elVoid "img" [ A "src" t.thumb, A "width" "160", A "height" "160", A "alt" t.alt ] ]
    ]

-- Photos are square; the size attributes reserve their space before they load.
photoAttrs :: String -> String -> Array Attr
photoAttrs srcset sizes
  | srcset == "" = []
  | otherwise = [ A "srcset" srcset, A "sizes" sizes, A "width" "1200", A "height" "1200" ]

purchase :: ProductVM -> Html
purchase vm =
  el "div" []
    [ if vm.maxQuantity < 1 then
        el "p" [ cls "stock-note ui-alert ui-alert--warning" ] [ text ("Your cart already has the last " <> plural vm.inCart <> ".") ]
      else
        el "form" [ cls "add-form", A "method" "post", A "action" "/cart/add" ]
          [ elVoid "input" [ A "type" "hidden", A "name" "product", A "value" vm.slug ]
          , el "div" [ cls "quantity-field" ]
              [ el "label" [ A "for" "qty" ] [ text "Quantity" ]
              , el "div" [ cls "quantity-row" ]
                  [ elVoid "input" [ A "id" "qty", A "name" "quantity", A "type" "number", A "min" "1", A "max" (show vm.maxQuantity), A "value" "1", B "required", A "aria-describedby" "stock-left" ]
                  , whenH (vm.remaining >= 0) (el "span" [ cls "stock-note ui-badge ui-badge--warning", A "id" "stock-left" ] [ text ("Only " <> show vm.remaining <> " left") ])
                  ]
              ]
          , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Add to cart" ]
          ]
    , el "p" [ cls "fine-print" ] [ text vm.fulfillmentNote ]
    ]
  where
  plural n = if n == 1 then "one" else show n

-- Sold out: the status where the quantity would be, and a button to hear when
-- it's back. Unavailable (stock can't be checked) offers nothing.
unavailable :: ProductVM -> Html
unavailable vm =
  el "div" [ cls "sold-out" ]
    ( [ el "p" [ cls "sold-out-status" ] [ text status ] ]
        <> if vm.reason == "unavailable" then [ el "p" [ cls "description" ] [ text "We can't check stock right now. Try again in a minute." ] ]
          else [ notifyView (toNotify vm) ]
    )
  where
  status = if vm.reason == "unavailable" then "Temporarily unavailable" else "Sold out"

toNotify :: ProductVM -> NotifyVM
toNotify vm = { slug: vm.slug, notifyState: vm.notifyState, notifyEmail: vm.notifyEmail, loginHref: vm.loginHref }

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
    , trustItem true "Pick-up and delivery" "[Where pick-up is, and the local delivery area and fee.]"
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
    , el "div" [ cls "faq-list ui-disclosure-group" ]
        [ faqItem "How do I mount it, and how high?" "[Your mounting guidance. Bluebird houses usually sit 5–6 feet up, in the open, away from heavy foot traffic.]"
        , faqItem "How do I keep sparrows and predators out?" "[The 1½-inch hole already blocks starlings. Add any guidance on house sparrows, baffles or predator guards.]"
        , faqItem "How do I clean it?" "[Your cleaning instructions, and how the box opens for it.]"
        , faqItem "Does it come assembled?" "[Assembled or flat-pack, and what's in the box.]"
        , faqItem "When can I get it?" "[How soon after ordering it's ready for pick-up or local delivery.]"
        ]
    ]

faqItem :: String -> String -> Html
faqItem question answer =
  el "details" [ cls "faq-item ui-disclosure" ]
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
      , whenH vm.checkoutOk (el "a" [ cls "buy-button ui-button ui-button--block", A "href" "/checkout" ] [ text "Proceed to checkout" ])
      , el "a" [ cls "text-button ui-button ui-button--link", A "href" "/products" ] [ text "Continue shopping" ]
      , el "p" [ cls "fine-print" ] [ text vm.fulfillmentNote ]
      ]

-- The #cart box, re-rendered in place by the HTMX stepper.
cartBox :: CartVM -> Html
cartBox vm =
  el "div" [ A "id" "cart", cls "cart" ]
    if vm.cartQty < 1 then
      [ el "div" [ cls "cart-line" ] [ el "span" [] [ text vm.productName ] ]
      , notice
      , el "a" [ cls "text-link", A "href" vm.productHref ] [ text "Get notified when it's back" ]
      ]
    else
      [ el "div" [ cls "cart-line" ]
          [ el "span" [] [ text vm.productName ]
          , el "span" [] [ text vm.lineTotal ]
          ]
      , notice
      , el "div" [ cls "cart-controls" ]
          [ stepper vm.cartQty vm.maxQuantity
          , el "form" [ cls "cart-remove", A "method" "post", A "action" "/cart/clear" ]
              [ el "button" [ cls "text-button ui-button ui-button--link", A "type" "submit", A "aria-label" ("Remove " <> vm.productName <> " from your cart") ] [ text "Remove" ] ]
          ]
      , el "p" [ cls "cart-total" ] [ text ("Subtotal · " <> vm.subtotal) ]
      ]
  where
  notice = whenH (vm.notice /= "") (el "p" [ cls "cart-notice ui-alert ui-alert--warning", A "role" "status" ] [ text vm.notice ])

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
    ( [ cls "quantity-button ui-button ui-button--outline ui-button--icon", A "type" "button"
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
          ( [ el "label" [ cls "delivery-option ui-choice" ]
                [ elVoid "input" [ A "type" "radio", A "name" "method", A "value" "ship", B "disabled" ]
                , el "span" [] [ el "strong" [] [ text "Shipping" ], text " — coming soon" ]
                ]
            , whenH (vm.error /= "") (el "p" [ cls "waitlist-error ui-status ui-status--danger", A "role" "alert" ] [ text vm.error ])
            , el "p" [ cls "delivery-heading" ] [ el "strong" [] [ text "Local pick-up" ], text " — free. Choose a time:" ]
            ]
              <> (if null vm.slots then [ el "p" [ cls "description" ] [ text "No pick-up times are open right now — check back soon." ] ] else map slotOption vm.slots)
              <> deliveryOptions vm
              <> (if null vm.slots && null vm.deliverySlots then [] else [ el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Continue to payment" ] ])
          )
      , el "div" [ cls "checkout-actions" ]
          [ el "a" [ cls "text-button ui-button ui-button--link", A "href" "/cart" ] [ text "Back to cart" ] ]
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
  el "label" [ cls "delivery-option ui-choice" ]
    [ choiceInput ("pickup:" <> show slot.id) slot.selected
    , el "span" []
        [ el "strong" [] [ text slot.location ]
        , text (" — " <> slot.time)
        , whenH (slot.details /= "") (el "span" [ cls "delivery-details" ] [ text slot.details ])
        ]
    ]

deliverySlotOption :: DeliverySlot -> Html
deliverySlotOption slot =
  el "label" [ cls "delivery-option ui-choice" ]
    [ choiceInput ("delivery:" <> show slot.id) slot.selected
    , el "span" [] [ el "strong" [] [ text "Delivery" ], text (" — " <> slot.time) ]
    ]

choiceInput :: String -> Boolean -> Html
choiceInput value selected =
  elVoid "input" ([ A "type" "radio", A "name" "choice", A "value" value, B "required" ] <> (if selected then [ B "checked" ] else []))

-- Step 2: pay. Wallet buttons (Express Checkout) sit above the card form. For
-- delivery the wallet supplies the address, or the card path's Address Element
-- does; pick-up needs none. The data attributes label the wallet sheet and
-- tell the server the total shown.
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
                , el "button" [ A "id" "submit-payment", cls "buy-button ui-button ui-button--block" ] [ text ("Pay " <> vm.total) ]
                ]
          )
      , el "div" [ cls "checkout-actions" ]
          [ el "a" [ cls "text-button ui-button ui-button--link", A "href" "/cart" ] [ text "Back to cart" ]
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
    [ el "h1" [ cls "page-title" ] [ text "Thank you for your order" ]
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
  | otherwise = "Your payment went through. We'll be in touch about getting your " <> vm.productName <> " to you."

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

-- ---------------------------------------------------------------- notify me

notifyFragment :: NotifyVM -> String
notifyFragment = render <<< notifyView

notifyView :: NotifyVM -> Html
notifyView vm =
  el "div" [ A "id" "notify", cls "notify" ]
    case vm.notifyState of
      "requested" ->
        [ el "p" [ cls "notify-done ui-alert ui-alert--success", A "role" "status", A "data-notify-requested" "true" ]
            [ text ("We'll email " <> vm.notifyEmail <> " when it's available again.") ]
        ]
      _
        | vm.notifyEmail == "" && vm.loginHref /= "" ->
            [ el "a" [ cls "buy-button ui-button ui-button--block", A "href" vm.loginHref ] [ text "Notify me when available" ]
            , el "p" [ cls "fine-print" ] [ text "Sign in or create a free account so we know where to email you." ]
            ]
        | otherwise ->
            [ el "form"
                [ A "method" "post", A "action" "/notify"
                , A "hx-post" "/notify", A "hx-target" "#notify", A "hx-swap" "outerHTML"
                ]
                [ elVoid "input" [ A "type" "hidden", A "name" "product", A "value" vm.slug ]
                , whenH (vm.notifyState == "error") (el "p" [ cls "waitlist-error ui-status ui-status--danger", A "role" "alert" ] [ text "We couldn't save that. Please try again." ])
                , el "button" [ cls "buy-button ui-button ui-button--block", A "type" "submit" ] [ text "Notify me when available" ]
                ]
            , el "p" [ cls "fine-print" ] [ text ("We'll email " <> vm.notifyEmail <> " once, when it's back.") ]
            ]
