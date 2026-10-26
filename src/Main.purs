module Main where

import Prelude
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff.Compat (EffectFnAff, fromEffectFnAff)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)

foreign import startCheckout :: Int -> Effect Unit
foreign import resetCheckout :: Effect Unit
foreign import isPaymentComplete :: Boolean
foreign import fetchOrder :: EffectFnAff Order

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
  }

data OrderLookup = Loading | Loaded Order

type State =
  { checkoutOpen :: Boolean
  , paymentComplete :: Boolean
  , quantity :: Int
  , order :: OrderLookup
  }

data Action = Initialize | IncreaseQuantity | DecreaseQuantity | OpenCheckout | EditCart

data Query :: Type -> Type
data Query a

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  runUI component unit body

component :: H.Component Query Unit Void Aff
component = H.mkComponent
  { initialState: \_ -> { checkoutOpen: false, paymentComplete: isPaymentComplete, quantity: 1, order: Loading }
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
        ]
    , HH.main_
        [ if state.paymentComplete then paymentCompleteView state.order else storefront state ]
    ]

storefront :: State -> H.ComponentHTML Action () Aff
storefront state =
  HH.div_
    [ HH.section [ HP.classes [ HH.ClassName "product" ], HP.attr (HH.AttrName "aria-labelledby") "product-title" ]
        [ HH.img
            [ HP.classes [ HH.ClassName "hero-image" ]
            , HP.src "/logo.png"
            , HP.alt "Pencil sketch of a bluebird house above the word birdhaus"
            ]
        , HH.div [ HP.classes [ HH.ClassName "product-details" ] ]
            [ HH.h1 [ HP.id "product-title" ] [ HH.text "Bluebird House" ]
            , HH.p [ HP.classes [ HH.ClassName "price" ] ] [ HH.text "$40.00 USD each" ]
            , HH.p [ HP.classes [ HH.ClassName "description" ] ] [ HH.text "A simple home for backyard bluebirds." ]
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
                        , HP.disabled (state.quantity >= 99 || state.checkoutOpen)
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
            , HH.p [ HP.classes [ HH.ClassName "fine-print" ] ] [ HH.text "Shipping and taxes are not included." ]
            ]
        ]
    , if state.checkoutOpen then checkoutView state.quantity else HH.text ""
    ]

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
          [ HH.h1_ [ HH.text "Thank you for your order" ]
          , HH.p [ HP.classes [ HH.ClassName "confirmation-lede" ] ] [ HH.text "Your payment went through and your bluebird house is on its way to the workshop." ]
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
    state <- H.get
    when state.paymentComplete do
      order <- H.liftAff (fromEffectFnAff fetchOrder)
      H.modify_ _ { order = Loaded order }
  IncreaseQuantity -> H.modify_ \state -> state { quantity = min 99 (state.quantity + 1) }
  DecreaseQuantity -> H.modify_ \state -> state { quantity = max 1 (state.quantity - 1) }
  OpenCheckout -> do
    state <- H.get
    H.modify_ \current -> current { checkoutOpen = true }
    H.liftEffect (startCheckout state.quantity)
  EditCart -> do
    H.modify_ \state -> state { checkoutOpen = false }
    H.liftEffect resetCheckout
