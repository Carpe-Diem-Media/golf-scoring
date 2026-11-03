---
version: alpha
name: "The Ordinary"
website: "https://theordinary.com"
description: >-
  A clinical skincare brand whose marketing site runs Raleway — a geometric sans at weights 400
  and 700 — across a near-white canvas with near-black ink at #212529, with a tertiary accent of
  hot magenta #dc049b appearing on promotional badges and sale chips at 33 total occurrences.
  The system enforces a strict white-canvas discipline: no hero gradient, no tinted section
  backgrounds, and no brand-color fills on primary buttons — the single chromatic deviation from
  the black-and-white chrome is the magenta, which exists only on editorial callout elements and
  not on interactive surfaces. Geologica appears as a secondary sans for small-caps uppercase
  labels and cookie-banner body text, giving the marketing page two distinct sans voices rather
  than the monolithic single-family approach used by most clinical beauty brands.

seo:
  title: "The Ordinary Design System in Clinical White and Raleway"
  metaDescription: "A clinical white canvas, Raleway headings, Geologica uppercase labels and hot-magenta #dc049b badges: The Ordinary's tokens for React and AI tools."
  highlights:
    - "Clinical white canvas — no hero gradient, no tinted section fill, no brand-colored button background; the design says nothing so the formulas can say everything"
    - "Raleway at weight 700 for headings — 36px bold h2 headings anchor a system where the display tier is the only weight-contrast move in the typography stack"
    - "Hot magenta #dc049b appears 33 times as a badge and border — the single chromatic deviation in an otherwise monochrome page, reserved for promotional callouts and sale chips"
    - "Geologica as secondary voice — uppercase small-caps labels and cookie-banner body text run a different geometric sans, giving the page two distinct geometric voices"
    - "Near-black ink trio — three dark tones (#212529, #333333, #22121f) carry the page without a single pure black (#000000) in the primary text flow"
  tags:
    - "Healthcare & Wellness"
    - "E-commerce & Retail"
  lastUpdated: "2026-05-19"
  author:
    name: "Dov Azencot"
    url: "https://x.com/dovazencot"
  opening: |
    The Ordinary's marketing site communicates through deliberate visual silence. The hero is a white panel with a 36px bold Raleway headline, a product photograph, and a text sub-head — no gradient, no brand-colored CTA, no hero animation. The page continues this way below the fold: white cards with 20px border radius, product grids on white, editorial callout panels on white. The single moment of color is a hot magenta (#dc049b) that appears on promotional badges and price-chip borders — 33 occurrences in the extracted page, all on callout elements rather than primary interactive surfaces. Where most skincare brands build brand identity through color saturation (Tatcha's gold, Sunday Riley's sage, Youth to the People's sage-and-carbon), The Ordinary builds identity through its clinical absence of decoration.

    The DESIGN.md file packages the system into a machine-readable spec for React and AI tooling. Inside: 12 color tokens organized around three near-black ink tones (#212529 at 1020 occurrences, #333333 at 874, #22121f at 217) for text and borders, a pure-white canvas, a light beige (#e1ded9) hairline, and the hot magenta accent. Ten typography tokens span Raleway at 14-36px in weights 400/600/700 for display, body, and UI chrome, plus Geologica at 11-16px in weights 300/600/700 for uppercase labels. Five component groups cover the white-card grid, the black-border primary button, the monochrome top-nav, and the Raleway-driven hero heading.

    Feed this file to Claude or Cursor to reproduce The Ordinary's specific moves: white canvas with no tint, near-black text at #212529 (not pure black), Raleway at 700 for the only bold moment in the hierarchy, 20px card rounding as the single expressive shape move, and hot magenta reserved exclusively for promotional badges. The system is worth studying as a counter-example to the beauty-brand norm: it demonstrates that a skincare product page can convey authority through restraint rather than through brand-color saturation.
  related:
    - href: "/design"
      title: "Browse all design systems"
      description: "The full directory of DESIGN.md files on shadcn.io, with live mockups for each."
    - href: "https://theordinary.com"
      title: "The Ordinary — official site"
      description: "The Ordinary's public marketing site — the source of truth for the live tokens captured in this file."
    - href: "https://github.com/google-labs-code/design.md"
      title: "The DESIGN.md specification"
      description: "Google Labs' open spec for machine-readable design system files — the format this page is built on."
  questions:
    - id: "primary-color"
      title: "What is The Ordinary's brand accent color?"
      answer: "The Ordinary's single chromatic accent is hot magenta #dc049b — a vivid pink that sits midway between fuchsia and magenta. It appears 33 times in the captured page: 11 as text, 22 as border. It is found exclusively on promotional badge elements (sale chips, percentage-off labels, product category callout borders) and not on any primary interactive surface — buttons, inputs, or navigation links are all monochrome black or grey. The magenta is not declared in any CSS custom property; it is hard-coded on those callout elements only. Outside of promotional contexts, the page is strictly black-and-white."
    - id: "typography"
      title: "What typefaces does The Ordinary use?"
      answer: "The Ordinary runs two geometric sans-serif families. Raleway (Google Fonts, free) handles the primary hierarchy: h2 headlines at 36px / weight 700, navigation links and product names at 16-18px / weight 400 and 600, product descriptions at 14-18px / weight 400. Geologica (Google Fonts, free) acts as the secondary voice: uppercase small-caps labels at 11.2px / weight 700 / 0.896px tracking, badge-style annotation spans at 16px / weight 600, and cookie-banner body text at 14px / weight 300. Both families are free on Google Fonts, making this the only beauty brand in the directory whose full type stack is open-source and immediately reproducible."
    - id: "canvas-philosophy"
      title: "Why is The Ordinary's design so visually quiet?"
      answer: "The Ordinary positions itself as a clinical formulations company, not a luxury beauty brand. The design system enacts this positioning literally: no hero gradient, no brand-colored CTAs, no photography filters, no decorative type. The founding principle is that the formulas speak for themselves — Niacinamide 10% + Zinc 1%, Hyaluronic Acid 2% + B5, Lactic Acid 10%. The ingredient names are the brand's language, and they need a blank surface to project authority. Adding a brand color behind the headline would compete with the formula-name hierarchy. The single magenta accent exists only to mark promotions — a semantic color, not a brand-voice color."
    - id: "radius-philosophy"
      title: "What corner-radius values does The Ordinary use?"
      answer: "The Ordinary's radius scale has a distinctive upper register. The dominant value is 20px (22 occurrences), which appears on the product-carousel card tiles and editorial content cards — significantly softer than the 4-8px sharp rounding most clinical brands use. 50% circles (22 occurrences) are used on icon buttons and avatar elements. 4px (10 occurrences) appears on smaller UI chips and input outlines. 9px (8 occurrences) appears on mid-size interactive elements. 5px (8 occurrences) rounds secondary chips. The 20px card radius is the most expressive shape decision in the system — it softens what would otherwise be a very harsh clinical aesthetic."
    - id: "use-in-project"
      title: "Can I use this DESIGN.md to build a clinical skincare React site?"
      answer: "Yes — feed this file to Claude, Cursor, or any AI tool that reads DESIGN.md tokens and it will reproduce The Ordinary's specific moves: white canvas, near-black #212529 ink instead of pure black, Raleway at 700 for the single bold headline tier, 20px card rounding, and hot magenta reserved for badge callouts only. Both typefaces (Raleway and Geologica) are free on Google Fonts. The token count is intentionally minimal — 12 colors, 10 typography levels, 15 components — which means the output is easier to audit and extend than a maximalist system. The one architectural decision worth preserving is the semantic separation of the magenta: it should appear only on promotional/callout elements, never as a primary CTA color."

mockups:
  - "marketing-hero"
  - "media-grid"

colors:
  ink: "#212529"
  ink-secondary: "#333333"
  ink-deep-plum: "#22121f"
  ink-muted: "#757575"
  canvas: "#ffffff"
  surface-pink: "#fce9f5"
  hairline: "#e1ded9"
  magenta: "#dc049b"
  ink-dark: "#090a0b"
  primary: "#000000"
  hairline-dark: "#757575"
  shadow: "#000000"

typography:
  display-xl:
    fontFamily: "Raleway, sans-serif"
    fontSize: 36px
    fontWeight: 700
    lineHeight: 43.2px
    letterSpacing: 0
  heading-md:
    fontFamily: "Raleway, sans-serif"
    fontSize: 18px
    fontWeight: 600
    lineHeight: 27px
    letterSpacing: 0
  heading-sm:
    fontFamily: "Raleway, sans-serif"
    fontSize: 16px
    fontWeight: 700
    lineHeight: 17px
    letterSpacing: 0
  body-lg:
    fontFamily: "Raleway, sans-serif"
    fontSize: 18px
    fontWeight: 400
    lineHeight: 27px
    letterSpacing: 0
  body-md:
    fontFamily: "Raleway, sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 24px
    letterSpacing: 0
  body-sm:
    fontFamily: "Raleway, sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 19.5px
    letterSpacing: 0
  nav-link:
    fontFamily: "Raleway, sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 24px
    letterSpacing: 0
  button-md:
    fontFamily: "Raleway, sans-serif"
    fontSize: 16px
    fontWeight: 600
    lineHeight: 42px
    letterSpacing: 0
  caption:
    fontFamily: "Raleway, sans-serif"
    fontSize: 13px
    fontWeight: 400
    lineHeight: 17px
    letterSpacing: 0
  label-caps:
    fontFamily: "Geologica, sans-serif"
    fontSize: 11.2px
    fontWeight: 700
    lineHeight: 23.8px
    letterSpacing: "0.896px"
  label-geo:
    fontFamily: "Geologica, sans-serif"
    fontSize: 16px
    fontWeight: 600
    lineHeight: 22.4px
    letterSpacing: 0
  label-geo-sm:
    fontFamily: "Geologica"
    fontSize: 12px
    fontWeight: 300
    lineHeight: 14px
    letterSpacing: "0.96px"

rounded:
  none: "0px"
  xs: "2px"
  sm: "4px"
  md: "5px"
  lg: "9px"
  xl: "20px"
  full: "50%"
  pill: "110px"

spacing:
  xxs: "3px"
  xs: "4px"
  sm: "8px"
  md: "12px"
  base: "16px"
  lg: "20px"
  xl: "32px"
  2xl: "40px"

components:
  hero-heading:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.display-xl}"
    padding: "0"
  body-paragraph:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    padding: "0"
  body-paragraph-muted:
    backgroundColor: "transparent"
    textColor: "{colors.ink-muted}"
    typography: "{typography.body-sm}"
    padding: "0"
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.canvas}"
    typography: "{typography.button-md}"
    rounded: "{rounded.none}"
    padding: "0px 20px"
    height: "40px"
    borderColor: "{colors.primary}"
  button-secondary:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.none}"
    padding: "0px 20px"
    height: "40px"
    borderColor: "{colors.ink}"
  top-nav:
    backgroundColor: "{colors.ink-secondary}"
    textColor: "{colors.canvas}"
    typography: "{typography.nav-link}"
    rounded: "{rounded.none}"
    padding: "8px 16px"
    height: "40px"
  nav-link:
    backgroundColor: "transparent"
    textColor: "{colors.canvas}"
    typography: "{typography.nav-link}"
    padding: "0px 8px"
  card:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.xl}"
    padding: "16px"
    borderColor: "{colors.hairline}"
  badge-magenta:
    backgroundColor: "transparent"
    textColor: "{colors.magenta}"
    typography: "{typography.label-caps}"
    rounded: "{rounded.sm}"
    padding: "2px 8px"
    borderColor: "{colors.magenta}"
  section-heading:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.display-xl}"
    padding: "0"
  label-caps:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.label-caps}"
    padding: "0"
  text-input:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.primary}"
    typography: "{typography.label-geo-sm}"
    rounded: "{rounded.none}"
    padding: "10px 40px 10px 0px"
    height: "40px"
    borderColor: "{colors.ink}"
  product-name:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.heading-md}"
    padding: "0"
  caption:
    backgroundColor: "transparent"
    textColor: "{colors.ink-muted}"
    typography: "{typography.caption}"
    padding: "0"
  surface-tinted:
    backgroundColor: "{colors.surface-pink}"
    textColor: "{colors.ink}"
    typography: "{typography.body-md}"
    rounded: "{rounded.xl}"
    padding: "16px"
---

## Overview

The Ordinary's site is not quiet by accident. **Clinical restraint as brand language**: the page is a white surface carrying Raleway text and product photographs, with the formulas themselves — Niacinamide 10% + Zinc 1%, Hyaluronic Acid 2% + B5 — doing the identity work that most beauty brands offload to hero gradients and colored CTAs. Where Tatcha layers gold tones and Sunday Riley builds warmth through amber, The Ordinary holds the canvas white and lets the ingredient percentages function as the typography's headline material.

The single chromatic departure is hot magenta (#dc049b) — a saturated fuchsia-adjacent pink that appears on promotional badges and percentage-off chip borders. At 33 total occurrences it is genuinely rare on the page, and its use is strictly semantic: it marks callout information (sale price, limited promotion) rather than brand accent. A developer who applies it to primary CTAs has misread the system.

**Near-black trio, not pure black**: the primary text color is #212529 (1020 occurrences), a very slightly warm near-black that sits just above pure black. Supporting text runs #333333 (874 occurrences) and the deep plum-black #22121f (217 occurrences). Pure black (#000000) appears 439 times but primarily in structural roles and the nav bar fill — not in body text.

**Key Characteristics:**
- White canvas throughout — no hero gradient, no section tints, no brand fills behind copy.
- Raleway at weight 700 is the single bold moment: 36px h2 / 43px line-height, used for section headlines only.
- Hot magenta (#dc049b) restricted to 33 occurrences: 11 as text, 22 as border — promotional badges only, never interactive CTAs.
- Two geometric-sans families: Raleway (primary hierarchy) and Geologica (uppercase-label secondary voice).
- 20px card radius is the system's most expressive shape decision — softer than the clinical typography suggests.
- Near-black ink at #212529, not pure #000000, in primary text — a warmth nuance that prevents the white canvas from feeling sterile.
- Primary button: pure black fill (#000000) with white text, sharp corners (0px radius) — the one surface where pure black appears as a fill.

## Colors

### Ink

- **Ink** (`{colors.ink}` — #212529): frequency 1020. Used as text (519), border (501). The primary near-black, clustered from several very-dark near-charcoal values. Not pure black; the slight warmth prevents the white canvas from reading as a laboratory surface.
- **Ink Secondary** (`{colors.ink-secondary}` — #333333): frequency 874. Used as text (435), bg (1), border (438). The secondary near-black wired as `--gray-dark` and `--dark`. Fills the top navigation bar and secondary body text.
- **Ink Deep Plum** (`{colors.ink-deep-plum}` — #22121f): frequency 217. Used as text (113), border (104). A very dark plum-black used on the darkest UI chrome — modal backgrounds, strong borders, and header separators.
- **Ink Muted** (`{colors.ink-muted}` — #757575): frequency 37. Used as text (18), bg (1), border (18). Wired as `--gray` and `--secondary`. Secondary labels, price secondary lines, and de-emphasized captions.
- **Ink Dark** (`{colors.ink-dark}` — #090a0b): frequency 18. Used as text (9), border (9). The darkest structural ink — near-pure-black used on the strongest hairline borders and emphasis elements.
- **Primary** (`{colors.primary}` — #000000): frequency 439. Used as text (216), bg (8), border (203), shadow (12). Wired as `--primary`. Pure black drives the CTA button fill, some heading text, and shadow values.

### Surface

- **Canvas** (`{colors.canvas}` — #ffffff): frequency 336. Used as text (138), bg (68), border (130). The page floor — pure white drives the body canvas and nav text-on-dark surfaces.
- **Surface Pink** (`{colors.surface-pink}` — #fce9f5): frequency 11, all as background. A pale magenta-pink used on the light tinted panel that frames in-store consultation promotional cards. Adjacent to the brand magenta but significantly lighter.

### Accent

- **Magenta** (`{colors.magenta}` — #dc049b): frequency 33. Used as text (11), border (22). The single chromatic accent on the page — reserved for promotional badge text and sale chip borders.

### Hairline

- **Hairline** (`{colors.hairline}` — #e1ded9): frequency 15, all as border. A warm light beige clustered from two near-identical hairline values. Card borders, section dividers, and light separators — not grey, which keeps the white canvas feeling organic rather than clinical.

## Typography

### Font Families

The system runs two free Google Fonts families. **Raleway** handles the full primary hierarchy — display headlines at 36px / weight 700, headings at 16-18px / weight 600, running body at 14-18px / weight 400, nav links at 16px / weight 400, and button labels at 16px / weight 600. **Geologica** carries the secondary annotation layer: uppercase-tracked small-caps labels at 11.2px / weight 700 and cookie-banner body at 14px / weight 300. Unlike most clinical brands that commit to a single ultra-minimal sans (The Outset uses one family, Skinceuticals uses one), The Ordinary runs two sans voices and uses them to separate what is "primary content" (Raleway) from what is "technical annotation" (Geologica).

### Hierarchy

| Token | Family | Size | Weight | Use |
|---|---|---|---|---|
| `{typography.display-xl}` | Raleway | 36px | 700 | h2 section headlines |
| `{typography.heading-md}` | Raleway | 18px | 600 | Product names, sub-heads |
| `{typography.heading-sm}` | Raleway | 16px | 700 | Price emphasis, strong labels |
| `{typography.body-lg}` | Raleway | 18px | 400 | Lead body paragraphs |
| `{typography.body-md}` | Raleway | 16px | 400 | Default running text |
| `{typography.body-sm}` | Raleway | 14px | 400 | Caption rows, small descriptions |
| `{typography.nav-link}` | Raleway | 16px | 400 | Nav link labels |
| `{typography.button-md}` | Raleway | 16px | 600 | Button labels |
| `{typography.caption}` | Raleway | 13px | 400 | Meta captions |
| `{typography.label-caps}` | Geologica | 11.2px | 700 | Uppercase small-caps labels, badges |
| `{typography.label-geo}` | Geologica | 16px | 600 | Secondary badge text |
| `{typography.label-geo-sm}` | Geologica | 12px | 300 | Email input placeholder |

### Note on Font Substitutes

Both Raleway and Geologica are free on Google Fonts. No substitution is needed. Raleway at weight 700 is the key differentiator in the display tier — swapping to weight 600 loses the visual authority of the headline. Geologica at weight 700 with 0.9px tracking produces the uppercase-label voice; if Geologica is unavailable, **DM Sans** at 500 with `text-transform: uppercase` and `letter-spacing: 0.08em` is the closest available substitute.

## Layout

### Spacing System

- **Base unit:** 16px dominant (55 occurrences) and 4px (44 occurrences) as the micro module.
- **Tokens:** `{spacing.xxs}` 3px · `{spacing.xs}` 4px · `{spacing.sm}` 8px · `{spacing.md}` 12px · `{spacing.base}` 16px · `{spacing.lg}` 20px · `{spacing.xl}` 32px · `{spacing.2xl}` 40px.
- **Card internal padding:** `{spacing.base}` 16px for product cards, `{spacing.lg}` 20px for larger editorial panels.
- **Section rhythm:** 40px between primary content sections.

### Grid & Container

- **Hero:** two-column split at desktop — editorial text left, product photography right, white background both sides.
- **Product grid:** 4-column carousel at desktop, 20px radius cards on the white canvas.
- **Below fold:** alternating full-width editorial photography (Why You Love More Lipids, Discover In-Store Consultations) and 4-column product grid segments.

### Rhythm

The page alternates between photography-led editorial panels and text-anchored product grids. Section breaks use white space rather than background-color changes — there are no tinted section bands on the page body except the pink `{colors.surface-pink}` panel for the consultation card.

## Elevation

The system has a minimal shadow tier. Pure black (#000000) appears 12 times as shadow — very light 1px shadows used on card hover states. Cards in their resting state carry no shadow; the 20px border radius and the `{colors.hairline}` (#e1ded9) border provide all the visual separation needed on the white canvas.

## Shapes

The radius scale spans two distinct tiers: small-step increments on UI chrome and 20px on content cards.

- `{rounded.none}` 0px — the primary CTA button (sharp-cornered black pill) and form input outlines.
- `{rounded.xs}` 2px — smallest UI chips.
- `{rounded.sm}` 4px — 10 occurrences on smaller interactive elements.
- `{rounded.md}` 5px — 8 occurrences on secondary chips and badges.
- `{rounded.lg}` 9px — 8 occurrences on mid-size card elements.
- `{rounded.xl}` 20px — 22 occurrences, the dominant card radius. This is the system's expressive move: product cards sit on the white canvas with generous 20px rounding that softens the clinical type.
- `{rounded.full}` 50% — 22 occurrences on circular icon buttons and profile elements.
- `{rounded.pill}` 110px — 1 occurrence on a promotional chip.

The sharp primary button beside the 20px card radius is the shape tension in the system — the CTA is the one hard surface against otherwise soft card geometry.

## Components

**`hero-heading`** — Raleway 36px / 700 at `{typography.display-xl}`, ink `{colors.ink}` on white. The system's only bold display moment.

**`body-paragraph`** — Raleway 16px / 400 at `{typography.body-md}`, ink text on white. Default running copy.

**`body-paragraph-muted`** — Raleway 14px / 400 at `{typography.body-sm}`, muted `{colors.ink-muted}` text. Used for price secondary lines and secondary descriptions.

**`button-primary`** — Pure black `{colors.primary}` fill, white text in Raleway 16px / 600, sharp corners `{rounded.none}`, 0×20px padding, 40px height. The signature CTA — the one surface in the system where pure black is used as a fill rather than as text.

**`button-secondary`** — White `{colors.canvas}` fill, ink text, 1px ink border, same sharp-corner geometry. Used for secondary actions like "Learn More."

**`top-nav`** — Dark `{colors.ink-secondary}` (#333333) fill, white text, 40px height. The top utility bar carrying the currency selector, location, and secondary links. The nav sits above the main product navigation.

**`nav-link`** — Transparent background, white text (on dark nav) or ink text (below nav), Raleway 16px / 400.

**`card`** — White canvas, ink text, Raleway 14px / 400, 20px radius `{rounded.xl}`, 16px padding, 1px `{colors.hairline}` beige border. The dominant content surface — product image above, name + description + price below.

**`badge-magenta`** — Transparent background, magenta `{colors.magenta}` text and 1px magenta border, Geologica 11.2px / 700 / 0.9px tracking, 4px radius, 2×8px padding. The sole chromatic element in the system — applied only to promotional tags and sale percentages.

**`section-heading`** — Raleway 36px / 700, ink text, transparent background. Same as `{component.hero-heading}` — one display token drives both hero and section heads.

**`label-caps`** — Geologica 11.2px / 700 / 0.896px tracking in uppercase, ink text, transparent background. Small-caps section labels and annotation chips.

**`text-input`** — White fill, pure black text `{colors.primary}`, Geologica 12px / 300 for placeholder, sharp corners `{rounded.none}`, 10px vertical / 40px horizontal padding, 40px height, ink bottom border only (no full-outline box).

**`product-name`** — Raleway 18px / 600, ink text. Product title below the product image in card grids.

**`caption`** — Raleway 13px / 400, muted `{colors.ink-muted}` text. Below images and beneath social proof elements.

**`surface-tinted`** — Light pink `{colors.surface-pink}` background, ink text, 20px radius, 16px padding. Used for the in-store consultation promotional panel — the only non-white section surface in the system.

## Do's and Don'ts

**Do** use `{colors.magenta}` (#dc049b) only on promotional and callout badges — not on primary CTAs, nav links, or headings. The magenta is a semantic accent for "this is a promotion" and loses its signal if applied to interactive chrome.

**Do** keep the primary button with sharp corners (`{rounded.none}`) even though the card grid uses 20px rounding. The tension between the button's hard edge and the card's soft radius is a deliberate visual hierarchy — the CTA reads as decisive against the soft grid.

**Do** use #212529 as the primary text color, not pure `{colors.primary}` (#000000). The slight warmth in the near-black is what prevents the white-canvas system from reading as harsh or sterile; swapping to pure black shifts the page from clinical-warm to clinical-harsh.

**Do** let Raleway 700 appear only at 36px for display headlines. Applying bold 700 at body sizes or card labels breaks the weight hierarchy — the system's single bold moment is the h2 headline, and its scarcity is the source of its visual authority.

**Don't** introduce `{colors.surface-pink}` (#fce9f5) as a general section background. It appears in one location on the page (the in-store consultation card); using it as a general page-section tint creates a pink brand association the system does not intend.

**Don't** use `{colors.hairline}` (#e1ded9) for text or as a hover-state fill — it is a border-only token (15 occurrences, all as border). For a subtle hover background on cards, use a very light tint of `{colors.canvas}` or add opacity rather than the hairline beige.

**Don't** apply 20px radius (`{rounded.xl}`) to buttons or inputs. The 20px radius belongs to content cards; interactive elements use either sharp corners or smaller radii (4-9px). Using it on a button makes the CTA feel like a floating card rather than a tap target.

**Don't** apply the Geologica family to primary display headings or body paragraphs. Geologica is the annotation family (small-caps labels, badges, cookie-banner text); mixing it into the Raleway-led primary hierarchy undermines the two-voice separation the system is built on.

## Known Gaps

- **Dark mode:** no dark-mode variant is exposed on the marketing surface or in the extracted CSS custom properties.
- **Hover and focus states:** `{component.button-primary}` hover and focus ring styling are not captured; the full state matrix for inputs and interactive cards is absent.
- **Product detail page:** this file captures the homepage only. The product detail page, ingredient glossary, and regimen-builder surfaces carry their own component instances not represented here.
- **Mobile navigation:** the mobile hamburger drawer and category-navigation tree are not captured in the extracted data.
- **Motion:** product carousel transitions, scroll-fade reveals on editorial sections, and modal transitions have no documented easing or duration values.
- **Loyalty and account surfaces:** the Mamboo loyalty program and account dashboard carry their own color accents (the loyalty program uses a purple tier system) not visible in the marketing-page extraction.
- **Third-party tolstoy widget:** the short-video shoppable widget (captured as `tolstoy-custom-font-family`) uses its own typography and is not represented in the token spec.
