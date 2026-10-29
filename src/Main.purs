module Main where

import Prelude
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff.Compat (EffectFnAff, fromEffectFnAff)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import Web.Event.Event (Event, preventDefault)

foreign import startCheckout :: Int -> Effect Unit
foreign import resetCheckout :: Effect Unit
foreign import isPaymentComplete :: Boolean
foreign import fetchOrder :: EffectFnAff Order
foreign import fetchBatch :: EffectFnAff Batch
foreign import fetchMe :: EffectFnAff Account
foreign import signOut :: Effect Unit
-- email, quantity, postal code -> "" on success, else a message to show.
foreign import joinWaitlist :: String -> Int -> String -> EffectFnAff String

-- Display-ready fields from Main.js. status is "succeeded", "processing",
-- "failed", or "error" (the order could not be loaded).
type Order =
  { status :: String
  , message :: String
  , number :: String
  , date :: String
  , items :: String
  , total :: String
  , email :: String
  , shipTo :: Array String
  , shipBy :: String
  }

-- From /api/me. id is the Rauthy subject, used only for analytics; email is the
-- verified address. signedIn is false for guests and when sign-in is off.
type Account =
  { signedIn :: Boolean
  , id :: String
  , email :: String
  , name :: String
  }

-- From /api/batch. reason is "open", "sold-out" or "closed"; remaining is -1
-- unless the batch is nearly gone; shipBy is display-ready ("December 15").
type Batch =
  { open :: Boolean
  , reason :: String
  , shipBy :: String
  , remaining :: Int
  }

data WaitlistStatus = Editing | Sending | Joined | Failed String

type Waitlist =
  { email :: String
  , quantity :: String
  , postalCode :: String
  , status :: WaitlistStatus
  }

data OrderLookup = Loading | Loaded Order

type State =
  { checkoutOpen :: Boolean
  , paymentComplete :: Boolean
  , quantity :: Int
  , order :: OrderLookup
  , batch :: Maybe Batch
  , showWaitlist :: Boolean
  , waitlist :: Waitlist
  , account :: Account
  }

data Action
  = Initialize
  | IncreaseQuantity
  | DecreaseQuantity
  | OpenCheckout
  | EditCart
  | ShowWaitlist
  | SetWaitlistEmail String
  | SetWaitlistQuantity String
  | SetWaitlistPostalCode String
  | SubmitWaitlist Event
  | SignOut

data Query :: Type -> Type
data Query a

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  runUI component unit body

component :: H.Component Query Unit Void Aff
component = H.mkComponent
  { initialState: \_ ->
      { checkoutOpen: false
      , paymentComplete: isPaymentComplete
      , quantity: 1
      , order: Loading
      , batch: Nothing
      , showWaitlist: false
      , waitlist: { email: "", quantity: "1", postalCode: "", status: Editing }
      , account: { signedIn: false, id: "", email: "", name: "" }
      }
  , render
  , eval: H.mkEval $ H.defaultEval { handleAction = handleAction, initialize = Just Initialize }
  }

render :: State -> H.ComponentHTML Action () Aff
render state =
  HH.div_
    [ HH.header [ HP.classes [ HH.ClassName "site-header" ] ]
        [ HH.a [ HP.classes [ HH.ClassName "wordmark" ], HP.href "/" ]
            [ HH.img [ HP.classes [ HH.ClassName "wordmark-mark" ], HP.src "/favicon-48.png", HP.alt "" ]
            , HH.text "BIRDHAUS"
            ]
        , accountNav state.account
        ]
    , HH.main_
        [ if state.paymentComplete then paymentCompleteView state.order else storefront state ]
    ]

accountNav :: Account -> H.ComponentHTML Action () Aff
accountNav account =
  HH.nav [ HP.classes [ HH.ClassName "account-nav" ] ]
    ( if account.signedIn then
        [ HH.span [ HP.classes [ HH.ClassName "account-email" ] ]
            [ HH.text (if account.name == "" then account.email else account.name) ]
        , HH.button
            [ HP.type_ HP.ButtonButton
            , HP.classes [ HH.ClassName "text-button" ]
            , HE.onClick \_ -> SignOut
            ]
            [ HH.text "Sign out" ]
        ]
      else
        [ HH.a [ HP.classes [ HH.ClassName "text-link" ], HP.href "/api/auth/login?next=/" ] [ HH.text "Sign in" ] ]
    )

storefront :: State -> H.ComponentHTML Action () Aff
storefront state =
  HH.div_
    [ HH.section [ HP.classes [ HH.ClassName "product" ], HP.attr (HH.AttrName "aria-labelledby") "product-title" ]
        [ HH.div [ HP.classes [ HH.ClassName "product-details" ] ]
            [ HH.h1 [ HP.id "product-title" ] [ HH.text "Bluebird House" ]
            , HH.p [ HP.classes [ HH.ClassName "price" ] ] [ HH.text "$40.00 USD each" ]
            , if shipBy == "" then HH.text ""
              else HH.p [ HP.classes [ HH.ClassName "preorder-note" ] ] [ HH.text ("Pre-order · ships by " <> shipBy) ]
            , HH.p [ HP.classes [ HH.ClassName "description" ] ] [ HH.text "A simple home for backyard bluebirds." ]
            , if open then purchase else soldOut
            ]
        ]
    , if open && state.checkoutOpen then checkoutView state.quantity else HH.text ""
    ]
  where
  fromBatch :: forall a. a -> (Batch -> a) -> a
  fromBatch d f = fromMaybe d (map f state.batch)
  -- Until /api/batch answers, show the store as open.
  open = fromBatch true _.open
  shipBy = fromBatch "" _.shipBy
  remaining = fromBatch (-1) _.remaining
  maxQuantity = if remaining >= 0 then min 99 remaining else 99

  soldOut =
    HH.div [ HP.classes [ HH.ClassName "sold-out" ] ]
      [ HH.h2_ [ HH.text (if fromBatch "" _.reason == "closed" then "Pre-orders have closed" else "This batch is sold out") ]
      , HH.p [ HP.classes [ HH.ClassName "description" ] ]
          [ HH.text "Join the waitlist and we'll email you first when we can build more. No payment needed." ]
      , waitlistView state.waitlist
      ]

  purchase =
    HH.div_
      [ if remaining >= 0 then HH.p [ HP.classes [ HH.ClassName "stock-note" ] ] [ HH.text ("Only " <> show remaining <> " left in this batch") ] else HH.text ""
      , HH.section [ HP.classes [ HH.ClassName "cart" ], HP.attr (HH.AttrName "aria-label") "Shopping cart" ]
                [ HH.h2_ [ HH.text "Your cart" ]
                , HH.div [ HP.classes [ HH.ClassName "cart-line" ] ]
                    [ HH.span_ [ HH.text "Bluebird House" ]
                    , HH.span_ [ HH.text (formatTotal state.quantity) ]
                    ]
                , HH.div [ HP.classes [ HH.ClassName "quantity-control" ], HP.attr (HH.AttrName "aria-label") "Quantity" ]
                    [ HH.button
                        [ HP.type_ HP.ButtonButton
                        , HP.classes [ HH.ClassName "quantity-button" ]
                        , HP.disabled (state.quantity <= 1 || state.checkoutOpen)
                        , HP.attr (HH.AttrName "aria-label") "Decrease quantity"
                        , HE.onClick \_ -> DecreaseQuantity
                        ]
                        [ HH.text "−" ]
                    , HH.span [ HP.attr (HH.AttrName "aria-live") "polite", HP.attr (HH.AttrName "aria-atomic") "true" ] [ HH.text (show state.quantity) ]
                    , HH.button
                        [ HP.type_ HP.ButtonButton
                        , HP.classes [ HH.ClassName "quantity-button" ]
                        , HP.disabled (state.quantity >= maxQuantity || state.checkoutOpen)
                        , HP.attr (HH.AttrName "aria-label") "Increase quantity"
                        , HE.onClick \_ -> IncreaseQuantity
                        ]
                        [ HH.text "+" ]
                    ]
                , HH.p [ HP.classes [ HH.ClassName "cart-total" ] ]
                    [ HH.text ("Subtotal · " <> formatTotal state.quantity) ]
                ]
            , HH.button
                [ HP.classes [ HH.ClassName "buy-button" ]
                , HP.disabled state.checkoutOpen
                , HE.onClick \_ -> OpenCheckout
                ]
                [ HH.text "Proceed to checkout" ]
      , HH.p [ HP.classes [ HH.ClassName "fine-print" ] ]
          [ HH.text
              ( (if shipBy == "" then "" else "Pre-order: you're charged today and your house ships by " <> shipBy <> ". Full refund any time before it ships, or if we miss that date. ")
                  <> "Shipping and taxes are not included."
              )
          ]
      , if state.showWaitlist then
          HH.div [ HP.classes [ HH.ClassName "waitlist-inline" ] ]
            [ HH.p [ HP.classes [ HH.ClassName "description" ] ] [ HH.text "Need more than this batch has? Tell us how many and we'll email you when we can build them." ]
            , waitlistView state.waitlist
            ]
        else
          HH.button [ HP.type_ HP.ButtonButton, HP.classes [ HH.ClassName "text-button" ], HE.onClick \_ -> ShowWaitlist ] [ HH.text "Need more? Join the waitlist" ]
      ]

waitlistView :: Waitlist -> H.ComponentHTML Action () Aff
waitlistView waitlist = case waitlist.status of
  Joined ->
    HH.p [ HP.classes [ HH.ClassName "waitlist-joined" ], HP.attr (HH.AttrName "role") "status" ]
      [ HH.text ("You're on the waitlist for " <> waitlist.quantity <> ". We'll email " <> waitlist.email <> " when we can build more.") ]
  _ ->
    HH.form [ HP.classes [ HH.ClassName "waitlist-form" ], HE.onSubmit SubmitWaitlist ]
      [ HH.label [ HP.for "waitlist-email" ] [ HH.text "Email" ]
      , HH.input [ HP.id "waitlist-email", HP.type_ HP.InputEmail, HP.required true, HP.placeholder "you@example.com", HP.value waitlist.email, HE.onValueInput SetWaitlistEmail ]
      , HH.div [ HP.classes [ HH.ClassName "waitlist-row" ] ]
          [ HH.div_
              [ HH.label [ HP.for "waitlist-quantity" ] [ HH.text "How many" ]
              , HH.input [ HP.id "waitlist-quantity", HP.type_ HP.InputNumber, HP.required true, HP.min 1.0, HP.max 99.0, HP.value waitlist.quantity, HE.onValueInput SetWaitlistQuantity ]
              ]
          , HH.div_
              [ HH.label [ HP.for "waitlist-zip" ] [ HH.text "ZIP code (optional)" ]
              , HH.input [ HP.id "waitlist-zip", HP.type_ HP.InputText, HP.attr (HH.AttrName "autocomplete") "postal-code", HP.value waitlist.postalCode, HE.onValueInput SetWaitlistPostalCode ]
              ]
          ]
      , case waitlist.status of
          Failed message -> HH.p [ HP.classes [ HH.ClassName "waitlist-error" ], HP.attr (HH.AttrName "role") "alert" ] [ HH.text message ]
          _ -> HH.text ""
      , HH.button [ HP.classes [ HH.ClassName "buy-button" ], HP.disabled (isSending waitlist.status) ] [ HH.text "Join the waitlist" ]
      ]
  where
  isSending Sending = true
  isSending _ = false

checkoutView :: Int -> H.ComponentHTML Action () Aff
checkoutView quantity =
  HH.section [ HP.id "checkout", HP.classes [ HH.ClassName "checkout" ], HP.attr (HH.AttrName "aria-labelledby") "checkout-title" ]
    [ HH.h2 [ HP.id "checkout-title" ] [ HH.text "Checkout" ]
    , HH.p [ HP.classes [ HH.ClassName "checkout-total" ] ] [ HH.text (show quantity <> " × Bluebird House · " <> formatTotal quantity) ]
    , HH.form [ HP.id "payment-form" ]
        [ HH.label [ HP.for "email" ] [ HH.text "Email for receipt" ]
        , HH.input
            [ HP.id "email"
            , HP.name "email"
            , HP.type_ HP.InputEmail
            , HP.required true
            , HP.placeholder "you@example.com"
            ]
        , HH.label_ [ HH.text "Shipping address" ]
        , HH.div [ HP.id "shipping-address" ] []
        , HH.div [ HP.id "payment-element" ] []
        , HH.div [ HP.id "payment-message", HP.attr (HH.AttrName "role") "alert", HP.attr (HH.AttrName "aria-live") "polite" ] []
        , HH.button [ HP.id "submit-payment", HP.classes [ HH.ClassName "buy-button" ] ] [ HH.text ("Pay " <> formatTotal quantity) ]
        ]
    , HH.div [ HP.classes [ HH.ClassName "checkout-actions" ] ]
        [ HH.button [ HP.type_ HP.ButtonButton, HP.classes [ HH.ClassName "text-button" ], HE.onClick \_ -> EditCart ] [ HH.text "Edit cart" ]
        , HH.p [ HP.classes [ HH.ClassName "fine-print" ] ] [ HH.text "Secure payment by Stripe." ]
        ]
    ]

formatTotal :: Int -> String
formatTotal quantity = "$" <> show (quantity * 40) <> ".00 USD"

paymentCompleteView :: OrderLookup -> H.ComponentHTML Action () Aff
paymentCompleteView lookup =
  HH.section [ HP.id "payment-success", HP.classes [ HH.ClassName "confirmation" ], HP.attr (HH.AttrName "aria-live") "polite" ]
    case lookup of
      Loading ->
        [ HH.p [ HP.classes [ HH.ClassName "confirmation-loading" ] ] [ HH.text "Loading your order…" ] ]
      Loaded order -> case order.status of
        "succeeded" ->
          [ HH.h1_ [ HH.text (if order.shipBy == "" then "Thank you for your order" else "Thank you for your pre-order") ]
          , HH.p [ HP.classes [ HH.ClassName "confirmation-lede" ] ]
              [ HH.text
                  ( if order.shipBy == "" then "Your payment went through and your bluebird house is on its way to the workshop."
                    else "Your payment went through. Your bluebird house is on the workshop's list and will ship by " <> order.shipBy <> "."
                  )
              ]
          , orderSummary order
          , receiptNote order "A receipt has been sent to "
          , backToStore "Back to the store"
          ]
        "processing" ->
          [ HH.h1_ [ HH.text "Your payment is processing" ]
          , HH.p [ HP.classes [ HH.ClassName "confirmation-lede" ] ] [ HH.text "We've received your order. Your bank is still confirming the payment, which usually takes a moment." ]
          , orderSummary order
          , receiptNote order "We'll send a receipt to "
          , backToStore "Back to the store"
          ]
        "failed" ->
          [ HH.h1_ [ HH.text "Your payment didn't go through" ]
          , HH.p [ HP.classes [ HH.ClassName "confirmation-lede" ] ]
              [ HH.text (if order.message == "" then "You have not been charged." else order.message <> " You have not been charged.") ]
          , backToStore "Return to the store to try again"
          ]
        _ ->
          [ HH.h1_ [ HH.text "Thank you for your order" ]
          , HH.p [ HP.classes [ HH.ClassName "confirmation-lede" ] ] [ HH.text "We couldn't load your order details right now. If your payment went through, a receipt is on its way to your email." ]
          , backToStore "Back to the store"
          ]

orderSummary :: Order -> H.ComponentHTML Action () Aff
orderSummary order =
  HH.dl [ HP.classes [ HH.ClassName "order-summary" ] ]
    ( [ HH.dt_ [ HH.text "Order" ], HH.dd_ [ HH.text order.number ]
      , HH.dt_ [ HH.text "Date" ], HH.dd_ [ HH.text order.date ]
      , HH.dt_ [ HH.text "Items" ], HH.dd_ [ HH.text order.items ]
      , HH.dt_ [ HH.text "Total" ], HH.dd_ [ HH.text order.total ]
      ]
        <> case order.shipTo of
          [] -> []
          lines -> [ HH.dt_ [ HH.text "Ship to" ], HH.dd [ HP.classes [ HH.ClassName "ship-to" ] ] (map (\line -> HH.span_ [ HH.text line ]) lines) ]
    )

receiptNote :: Order -> String -> H.ComponentHTML Action () Aff
receiptNote order prefix =
  if order.email == "" then HH.text ""
  else HH.p [ HP.classes [ HH.ClassName "fine-print" ] ] [ HH.text prefix, HH.strong_ [ HH.text order.email ], HH.text "." ]

backToStore :: String -> H.ComponentHTML Action () Aff
backToStore label =
  HH.a [ HP.classes [ HH.ClassName "text-link" ], HP.href "/" ] [ HH.text label ]

handleAction :: forall output. Action -> H.HalogenM State Action () output Aff Unit
handleAction = case _ of
  Initialize -> do
    account <- H.liftAff (fromEffectFnAff fetchMe)
    H.modify_ _ { account = account }
    state <- H.get
    if state.paymentComplete then do
      order <- H.liftAff (fromEffectFnAff fetchOrder)
      H.modify_ _ { order = Loaded order }
    else do
      batch <- H.liftAff (fromEffectFnAff fetchBatch)
      H.modify_ _ { batch = Just batch }
  IncreaseQuantity -> H.modify_ \state ->
    let
      remaining = fromMaybe (-1) (map _.remaining state.batch)
      limit = if remaining >= 0 then min 99 remaining else 99
    in
      state { quantity = min limit (state.quantity + 1) }
  DecreaseQuantity -> H.modify_ \state -> state { quantity = max 1 (state.quantity - 1) }
  OpenCheckout -> do
    state <- H.get
    H.modify_ \current -> current { checkoutOpen = true }
    H.liftEffect (startCheckout state.quantity)
  EditCart -> do
    H.modify_ \state -> state { checkoutOpen = false }
    H.liftEffect resetCheckout
  ShowWaitlist -> H.modify_ _ { showWaitlist = true }
  SetWaitlistEmail email -> H.modify_ \state -> state { waitlist = state.waitlist { email = email } }
  SetWaitlistQuantity quantity -> H.modify_ \state -> state { waitlist = state.waitlist { quantity = quantity } }
  SetWaitlistPostalCode postalCode -> H.modify_ \state -> state { waitlist = state.waitlist { postalCode = postalCode } }
  SignOut -> H.liftEffect signOut
  SubmitWaitlist event -> do
    H.liftEffect (preventDefault event)
    state <- H.get
    case Int.fromString state.waitlist.quantity of
      Just quantity | quantity >= 1 && quantity <= 99 -> do
        H.modify_ _ { waitlist = state.waitlist { status = Sending } }
        message <- H.liftAff (fromEffectFnAff (joinWaitlist state.waitlist.email quantity state.waitlist.postalCode))
        H.modify_ \current -> current { waitlist = current.waitlist { status = if message == "" then Joined else Failed message } }
      _ -> H.modify_ _ { waitlist = state.waitlist { status = Failed "Choose a quantity from 1 to 99." } }
