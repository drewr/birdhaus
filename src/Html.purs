-- A tiny server-side HTML DSL: values render to escaped String. No browser
-- types, so these modules are safe to bundle for Node. `text` escapes; `raw` is
-- an escape hatch for server-trusted markup only, never user input.
module Html
  ( Html
  , Attr(..)
  , render
  , text
  , raw
  , el
  , elVoid
  , empty
  , whenH
  , cls
  ) where

import Prelude
import Data.Foldable (foldMap)
import Data.String (Pattern(..), Replacement(..), replaceAll)

newtype Html = Html String

derive newtype instance semigroupHtml :: Semigroup Html
derive newtype instance monoidHtml :: Monoid Html

data Attr = A String String | B String

render :: Html -> String
render (Html s) = s

escapeText :: String -> String
escapeText =
  replaceAll (Pattern ">") (Replacement "&gt;")
    <<< replaceAll (Pattern "<") (Replacement "&lt;")
    <<< replaceAll (Pattern "&") (Replacement "&amp;")

escapeAttr :: String -> String
escapeAttr =
  replaceAll (Pattern "\"") (Replacement "&quot;")
    <<< replaceAll (Pattern ">") (Replacement "&gt;")
    <<< replaceAll (Pattern "<") (Replacement "&lt;")
    <<< replaceAll (Pattern "&") (Replacement "&amp;")

renderAttr :: Attr -> String
renderAttr (A k v) = " " <> k <> "=\"" <> escapeAttr v <> "\""
renderAttr (B k) = " " <> k

text :: String -> Html
text = Html <<< escapeText

raw :: String -> Html
raw = Html

empty :: Html
empty = Html ""

el :: String -> Array Attr -> Array Html -> Html
el tag attrs kids =
  Html ("<" <> tag <> foldMap renderAttr attrs <> ">" <> foldMap render kids <> "</" <> tag <> ">")

elVoid :: String -> Array Attr -> Html
elVoid tag attrs = Html ("<" <> tag <> foldMap renderAttr attrs <> ">")

whenH :: Boolean -> Html -> Html
whenH true h = h
whenH false _ = empty

cls :: String -> Attr
cls = A "class"
