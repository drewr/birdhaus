#!/usr/bin/env nix-shell
#! nix-shell -i bash -p imagemagick
# Regenerates public/ brand images from the pencil sketches in brand/.
# Scanned paper becomes true white (#fff) by levelling; the pencil stays gray.
set -euo pipefail
cd "$(dirname "$0")/.."

clean() { magick "$1" -colorspace Gray -level 35%,90% "${@:2}"; }

# Wide logo: trimmed, with a little air, for Stripe branding and link previews.
clean brand/logo-source.png \
  -fill white -draw "rectangle 1320,760 1360,800" \
  -fuzz 12% -trim +repage -bordercolor white -border 40 -strip public/logo.png
magick public/logo.png -resize 1200x -strip public/logo.png

# Square mark: trimmed, centred on a white square.
clean brand/mark-source.png -fuzz 12% -trim +repage \
  -bordercolor white -border 24 -background white -gravity center \
  -extent "%[fx:max(w,h)]x%[fx:max(w,h)]" -strip /tmp/mark-full.png
magick /tmp/mark-full.png -resize 512x512 -strip public/mark-512.png
magick /tmp/mark-full.png -resize 180x180 -strip public/apple-touch-icon.png

# Tiny sizes: thicken the pencil so it survives downscaling.
for size in 16 32 48; do
  magick /tmp/mark-full.png -morphology Erode Disk:5 -resize ${size}x${size} \
    -level 0%,85% -strip public/favicon-$size.png
done
magick public/favicon-16.png public/favicon-32.png public/favicon-48.png public/favicon.ico
rm /tmp/mark-full.png

# 1200x630 social preview.
magick -size 1200x630 xc:white \( public/logo.png -resize x540 \) -gravity center -composite \
  -depth 8 -colorspace Gray -strip public/og-image.png
