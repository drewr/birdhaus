# Kit

[datum-ui](https://github.com/datum-cloud/datum-ui)'s design as plain CSS on
[Open Props](https://open-props.style), themed sky blue. datum-ui is React,
shadcn/Radix and Tailwind v4; this kit is the same look for server-rendered
HTML, with no JavaScript and no Tailwind. Birdhaus uses it, but nothing here
knows about birdhaus, so it can move to its own package later.

## Use

Build with PostCSS: `postcss-jit-props` (with `open-props` as its source) and
`postcss-custom-media`, as `vite.config.js` does. Then import the kit unlayered
and name its layer before yours:

```css
@layer reset, kit, mine;
@import "./kit/index.css";
```

The kit puts itself in `kit.tokens`, `kit.elements` and `kit.components`. Any
layer after `kit` wins over all of it, whatever the specificity.

To see every component, open `demo.html`:
`npx vite --config vite.config.js kit`, then `/demo.html`.

## What it provides

- **`tokens.css`:** the `--ui-*` roles, which are datum-ui's purpose tokens
  (`themes/alpha.css`) renamed:
  - surfaces and text: `background`, `foreground`, `card`, `muted`,
    `muted-foreground`, `border`;
  - actions: `primary` (with `-hover`, `-active`, `-foreground` and `-wash`),
    `secondary`, `tertiary`, `neutral`;
  - status: `destructive`, `success`, `warning`, `info`;
  - fields: `input-*`, `ring`, `focus-shadow`;
  - type: `font-sans`, `text`, `text-small`, `weight-*`, `title-1…4`;
  - shape and motion: `radius`, `rule`, `shadow*`, `duration-*`, `ease*`.

  The prefix keeps them clear of Open Props, which has its own `--font-sans`,
  and of the site's tokens.
- **`elements.css`:** classless defaults for the page, headings, links, code,
  `<blockquote>`, `<hr>` and form controls. Everything is inside `:where()`.
- **`fonts.css`:** Inter at 400, 400 italic, 500 and 600, Latin only.
- **`components/`:**

  | Class | datum-ui | Modifiers |
  |---|---|---|
  | `.ui-button` | Button | types `--secondary`, `--tertiary`, `--quaternary`, `--danger`, `--success`; themes `--outline`, `--light`, `--borderless`, `--link`; sizes `--sm`, `--lg`, `--icon`, `--block` |
  | `.ui-field`, `__hint`, `__error`, `.ui-check`, `.ui-choice` | Form field, Checkbox, Radio | |
  | `.ui-card`, `__header`, `__title`, `__description`, `__action`, `__content`, `__footer` | Card | `--sm`, `--raised`, `--sectioned` |
  | `.ui-table`, `.ui-table-scroll` | Table | `--mist` (the data-table header) |
  | `.ui-badge` | Badge | types as buttons plus `--info`, `--warning`; `--solid`, `--outline` |
  | `.ui-alert`, `__title`, `__description`, `.ui-status` | Alert | `--muted`, `--info`, `--success`, `--warning`, `--danger` |
  | `.ui-disclosure`, `.ui-disclosure-group` | Collapsible | on `<details>` |
  | `.ui-dialog`, `__header`, `__body`, `__footer` | Dialog | on `<dialog>` |
  | `[data-tooltip]` | Tooltip | CSS only |

## How it differs from datum-ui

- **Scales.** Every size snaps to an Open Props step, so it looks like datum-ui
  without being pixel-identical:
  - Body text is 16px (`--font-size-1`), not 14px. Small text is 12px
    (`--font-size-0`), not 13px.
  - The 4px spacing grid maps to `--size-*`, so 12px gaps become 8 or 16px.
  - Corners are all `--radius-2` (5px), from datum-ui's 4, 6 and 10px.
  - Shadows are Open Props', tinted navy.
- **Colour.** Sky blue on Open Props' blue, cyan and gray scales, replacing
  datum-ui's rose, navy and lime:
  - primary `--blue-8`, hover `--blue-9`;
  - text `--blue-12`;
  - washes `--blue-0`;
  - `--blue-3` for decoration only.

  Every text/background pair is at least 4.5:1. Hover and active states are
  the next steps down each scale, instead of datum-ui's `color-mix` darkening.
- **Font.** Inter (SIL Open Font License 1.1, via `@fontsource/inter`) replaces
  Alliance No1, which is a commercial typeface. There is no Canela title font.
- **Light only.** No `.dark` theme.
- **No React components.** Selects, tooltips, dialogs and collapsibles are the
  native elements, styled. There's no menu, popover or date picker.
