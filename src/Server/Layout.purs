-- The page shell shared by the storefront (Server.Render) and the admin portal
-- (Server.Admin): <head>, asset links, analytics and the site header.
module Server.Layout
  ( Chrome
  , layout
  , cartLinkEl
  ) where

import Prelude
import Html (Attr(..), Html, cls, el, elVoid, render, text, whenH)

-- Fields shared by every full page (header + <head> asset links + analytics).
type Chrome r =
  ( css :: String
  , js :: String
  , accountId :: String
  , accountLabel :: String
  , signedIn :: Boolean
  , isAdmin :: Boolean
  , cartQty :: Int
  , reason :: String
  , version :: String
  , commit :: String
  | r
  )

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
            , footer c
            ]
        ]
    )

-- Which build is serving, for bug reports; the same values as /api/health.
footer :: forall r. { | Chrome r } -> Html
footer c =
  el "footer" [ cls "site-footer" ]
    [ el "span" [ A "title" "Version" ] [ text c.version ]
    , text " · "
    , el "span" [ A "title" "Commit" ] [ text c.commit ]
    ]

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
                ( if c.isAdmin then [ el "a" [ cls "text-link", A "href" "/admin" ] [ text "Admin" ] ] else [] )
                  <>
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
