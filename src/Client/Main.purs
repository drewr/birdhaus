-- The only client-side code: browser behavior the server can't render. It
-- sequences the effects; the browser specifics (Stripe Elements, Umami, DOM)
-- live in the FFI, as the storefront's client glue always has.
module Client.Main where

import Prelude
import Effect (Effect)

foreign import initAnalytics :: Effect Unit
foreign import initSignOut :: Effect Unit
foreign import initWaitlistTracking :: Effect Unit
foreign import initCheckout :: Effect Unit
foreign import initConfirmation :: Effect Unit

main :: Effect Unit
main = do
  initAnalytics
  initSignOut
  initWaitlistTracking
  initCheckout
  initConfirmation
