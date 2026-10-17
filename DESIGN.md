---
name: OpenBucket
description: The Mac app landing page, played straight - one product, real windows, one download.
colors:
  canvas: "#ffffff"
  band: "#f5f5f7"
  ink: "#1d1d1f"
  ink-2: "#6e6e73"
  hairline: "rgb(0 0 0 / 0.1)"
  action: "#0071e3"
  action-hover: "#0077ed"
  on-action: "#fff"
  link: "#0066cc"
  night: "#000000"
  night-ink: "#f5f5f7"
  night-ink-2: "#a1a1a6"
  night-link: "#2997ff"
  nav-glass: "rgb(255 255 255 / 0.76)"
  selection: "rgb(0 113 227 / 0.22)"
  footer-link: "#424245"
  badge-tested-fill: "#e3f4e7"
  badge-tested-ink: "#1a6b33"
  badge-implemented-fill: "#e5effb"
  badge-implemented-ink: "#0058b0"
  badge-untested-fill: "#ebebef"
  badge-untested-ink: "#56565c"
typography:
  display:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "clamp(44px, 7vw, 80px)"
    fontWeight: 600
    lineHeight: 1.05
    letterSpacing: "-0.025em"
  headline:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "clamp(36px, 5vw, 56px)"
    fontWeight: 600
    lineHeight: 1.07
    letterSpacing: "-0.022em"
  lede:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "clamp(19px, 1.6vw, 21px)"
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: "-0.012em"
  title:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "19px"
    fontWeight: 600
    lineHeight: 1.47
    letterSpacing: "-0.016em"
  link-large:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "19px"
    fontWeight: 400
    lineHeight: 1.47
    letterSpacing: "-0.012em"
  check:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "19px"
    fontWeight: 400
    lineHeight: 1.42
    letterSpacing: "-0.012em"
  body:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.47
    letterSpacing: "-0.012em"
  brand:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "17px"
    fontWeight: 600
    letterSpacing: "-0.012em"
  button:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "17px"
    fontWeight: 500
    letterSpacing: "-0.012em"
  nav:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    letterSpacing: "-0.012em"
  callout:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: "-0.012em"
  panel-label:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "14px"
    fontWeight: 600
    letterSpacing: "-0.012em"
  fine:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.47
    letterSpacing: "-0.012em"
    fontFeature: "tnum"
  button-small:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "13px"
    fontWeight: 500
    letterSpacing: "-0.012em"
  badge:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "12px"
    fontWeight: 600
    letterSpacing: "-0.012em"
  footer:
    fontFamily: "system-ui, -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.47
    letterSpacing: "-0.012em"
rounded:
  pill: "999px"
  panel: "24px"
  detail: "14px"
  focus: "4px"
  icon: "22.5%"
  window: "1.47% / 2.34%"
  window-tall: "1.47% / 2.07%"
  window-phone: "2.3% / 3.66%"
  window-tall-phone: "2.88% / 2.07%"
spacing:
  gutter: "22px"
  measure: "1080px"
  section: "120px"
  section-phone: "80px"
  stack: "22px"
  split: "72px"
  grid-row: "56px"
  grid-column: "48px"
components:
  nav:
    backgroundColor: "{colors.nav-glass}"
    textColor: "{colors.ink}"
    typography: "{typography.nav}"
    padding: "0 22px"
    height: "52px"
    width: "1080px"
  brand:
    textColor: "{colors.ink}"
    typography: "{typography.brand}"
  button-primary:
    backgroundColor: "{colors.action}"
    textColor: "{colors.on-action}"
    typography: "{typography.button}"
    rounded: "{rounded.pill}"
    padding: "0 24px"
    height: "48px"
  button-primary-hover:
    backgroundColor: "{colors.action-hover}"
  button-small:
    backgroundColor: "{colors.action}"
    textColor: "{colors.on-action}"
    typography: "{typography.button-small}"
    rounded: "{rounded.pill}"
    padding: "0 14px"
    height: "28px"
  button-small-hover:
    backgroundColor: "{colors.action-hover}"
  text-link:
    textColor: "{colors.link}"
    typography: "{typography.link-large}"
  text-link-night:
    textColor: "{colors.night-link}"
    typography: "{typography.link-large}"
  hero:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.display}"
    padding: "72px 22px 0"
  hero-icon:
    rounded: "{rounded.icon}"
    size: "112px"
  window:
    rounded: "{rounded.window}"
    width: "1100px"
  window-tall:
    rounded: "{rounded.window-tall}"
  window-detail:
    rounded: "{rounded.detail}"
    width: "1014px"
  window-caption:
    textColor: "{colors.ink-2}"
    typography: "{typography.fine}"
  section-band:
    backgroundColor: "{colors.band}"
    textColor: "{colors.ink}"
    typography: "{typography.headline}"
    padding: "120px 22px"
  section-plain:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.headline}"
    padding: "120px 22px"
  fact:
    textColor: "{colors.ink-2}"
    typography: "{typography.body}"
  fact-title:
    textColor: "{colors.ink}"
    typography: "{typography.title}"
  check:
    textColor: "{colors.ink}"
    typography: "{typography.check}"
  status-panel:
    backgroundColor: "{colors.band}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.panel}"
    padding: "32px 32px 28px"
  status-panel-phone:
    padding: "24px 22px 22px"
  badge-tested:
    backgroundColor: "{colors.badge-tested-fill}"
    textColor: "{colors.badge-tested-ink}"
    typography: "{typography.badge}"
    rounded: "{rounded.pill}"
    padding: "2px 10px"
  badge-implemented:
    backgroundColor: "{colors.badge-implemented-fill}"
    textColor: "{colors.badge-implemented-ink}"
    typography: "{typography.badge}"
    rounded: "{rounded.pill}"
    padding: "2px 10px"
  badge-not-yet-tested:
    backgroundColor: "{colors.badge-untested-fill}"
    textColor: "{colors.badge-untested-ink}"
    typography: "{typography.badge}"
    rounded: "{rounded.pill}"
    padding: "2px 10px"
  feature-row:
    textColor: "{colors.ink}"
    typography: "{typography.title}"
    padding: "16px 0"
  dark-band:
    backgroundColor: "{colors.night}"
    textColor: "{colors.night-ink}"
    typography: "{typography.headline}"
    padding: "120px 22px"
  trio-item:
    textColor: "{colors.night-ink-2}"
    typography: "{typography.body}"
  get-block:
    backgroundColor: "{colors.canvas}"
    textColor: "{colors.ink}"
    typography: "{typography.headline}"
    padding: "40px 22px 120px"
  get-icon:
    rounded: "{rounded.icon}"
    size: "96px"
  fine-print:
    textColor: "{colors.ink-2}"
    typography: "{typography.fine}"
  footer:
    backgroundColor: "{colors.band}"
    textColor: "{colors.ink-2}"
    typography: "{typography.footer}"
    padding: "22px 22px 36px"
  footer-link:
    textColor: "{colors.footer-link}"
---

# Design System: OpenBucket

## Overview

**Creative North Star: "The Straight Mac Page"**

OpenBucket's site is the category-standard Mac app landing page executed without a concept or costume, at the craft level of culturedcode.com/things and apple.com product pages. One product, one blue glass bucket icon, real app windows, one signed download. The page is a vertical stack of full-bleed sections on a white canvas, alternating with soft grey bands and a single black band, all set in the system face (SF Pro on Macs) with large semibold, slightly tightened headlines and generous whitespace.

The product itself is the only imagery. Every visual of OpenBucket is a genuine screenshot of a real window against a local Garage bucket of demo files, shown at its own corner radius with a soft offset window shadow, and the hero window settles into place as it scrolls into view. Colour is restrained to Apple's neutral greys plus one action blue; the only other hues are the three compatibility badges, which carry evidence, not decoration.

The voice of the layout is calm and confident: centred heroes and section heads, two- and three-column grids of short facts, and claims that never outrun the documented evidence. It rejects novelty concepts and the dark developer-tool look.

**Key Characteristics:**
- White canvas, #f5f5f7 bands, exactly one black band; light colour scheme only.
- System type, semibold headlines with negative tracking, 17px body.
- One action blue for the download pill; link blue for text links.
- Real screenshots with radii that match the window's own 18px corners and a soft two-layer shadow.
- The app icon is the only illustration; Lucide line icons are the only glyphs.
- Scroll-driven settle on the hero window, still under reduced motion.

## Colors

Apple's neutral ladder with one blue for action, one link blue per ground, and three muted badge pairs that encode test status.

### Primary
- **Action Blue** (action): the fill of every pill button (Download in the nav, Download for macOS, Go to OpenBucket), the skip link, the focus ring, the line icons in the facts grid and the checks list, and (at 22% alpha, the selection tint) text selection. Lifts to **Action Blue Hover** (action-hover) on hover.
- **Link Blue** (link): every text link on light ground, including "View on GitHub ↗" and "Compatibility details ↗".

### Secondary
- **Night Link Blue** (night-link): the shield mark, trio icons and text link inside the black band, where Link Blue would be too dark.

### Tertiary
- **Tested Green** (badge-tested-ink on badge-tested-fill): the "Tested" badge only.
- **Implemented Blue** (badge-implemented-ink on badge-implemented-fill): the "Implemented" badge only.
- **Untested Grey** (badge-untested-ink on badge-untested-fill): the "Not yet tested" badge only.

### Neutral
- **Canvas White** (canvas): page ground, plain sections, hero, get block; also the `theme-color`.
- **Band Grey** (band): alternating feature bands, the status panel, the footer.
- **Ink** (ink): headlines, body copy, nav links (at 0.8 opacity, 1 on hover), brand name.
- **Secondary Ink** (ink-2): ledes, fact and feature descriptions, second line of two-tone headlines, captions, fine print, panel label.
- **Hairline** (hairline): nav bottom border, feature-list and status-row dividers, footer top rule.
- **Nav Glass** (nav-glass): the sticky nav's translucent white, always paired with its backdrop blur.
- **Night** (night): the single black security band. **Night Ink** (night-ink) for its headline and titles, **Night Secondary Ink** (night-ink-2) for its lede and trio copy.
- **Footer Link Grey** (footer-link): footer links, a step darker than the footer's Secondary Ink text.

### Named Rules
**The One Blue Rule.** Action Blue fills only the download-path pill and marks icons; every other link is Link Blue text. Never introduce a second filled button colour.

**The Evidence Colour Rule.** Green, blue and grey badges exist only to state test status. No other surface borrows their hues.

**The One Night Rule.** The page carries exactly one black band, for the security story. Everything else alternates Canvas White and Band Grey.

## Typography

**Display Font:** system-ui (SF Pro on Macs, with -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', 'Segoe UI', Roboto, Arial, sans-serif)
**Body Font:** the same system stack
**Label/Mono Font:** none; there is no mono or secondary face.

**Character:** one family carries everything, as on apple.com: big semibold headlines tightened a few hundredths of an em, and a quiet 17px body with a whole-page -0.012em tracking and antialiased rendering.

### Hierarchy
- **Display** (600, clamp(44px, 7vw, 80px), 1.05, -0.025em): the hero headline only; 404 headline uses Headline.
- **Headline** (600, clamp(36px, 5vw, 56px), 1.07, -0.022em): every section h2 and the get block. Balanced wrapping. A two-tone variant sets its second line in Secondary Ink ("Not a web console in a window.").
- **Lede** (400, clamp(19px, 1.6vw, 21px), 1.4): one-sentence subheads under headlines, max 34em, centred, pretty wrapping, Secondary Ink (Night Secondary Ink in the black band).
- **Title** (600, 19px, -0.016em): fact titles, feature-list terms, trio titles.
- **Check** (400, 19px, 1.42): the endpoint checks list; drops to 17px on phones.
- **Large link** (400, 19px): standalone text links with a trailing arrow; 17px inside the status panel.
- **Body** (400, 17px, 1.47, -0.012em): all running copy.
- **Button** (500, 17px) and **Small button** (500, 13px): pill labels.
- **Nav** (400, 14px): nav links. **Callout** (400, 14px, 1.4): status notes. **Panel label** (600, 14px, Secondary Ink): the status panel title.
- **Fine** (400, 13px, tabular numerals): release line under the download pill, window captions.
- **Badge** (600, 12px) and **Footer** (400, 12px).

### Named Rules
**The System Face Rule.** Use the system stack only; SF Pro is the point on a Mac app's own page. No web fonts.

**The Semibold Ceiling Rule.** Headings top out at 600. Nothing on the page is bold (700).

## Layout

A single centred column of full-bleed sections. Content width is the 1080px measure with 22px gutters; the hero window may run to 1100px, the list-detail crop to 1014px, the trio to 940px, section heads to 820px.

- **Section rhythm:** bands, plain sections, the black band and the get block pad 120px vertically (80px on phones). The get block starts at 40px so it reads as the close of the section above it. Hero: 72px top (48px on phones), window 46px below the actions (28px on phones), 96px under the window (64px on phones).
- **Stacks:** centred blocks (hero, black band, open-source block, get block) stack with a 22px gap. Section heads stack at 20px and sit 72px above their grid (48px on phones).
- **Grids:** facts run 3 columns at 56px × 48px gaps; feature list 2 columns with a 56px column gap; trio 3 columns at 48px; the compatibility split is 1.05fr / 1fr at a 72px gap, vertically centred. The "everything you do" split stacks headline, feature list and the full-width Storage Overview window at 56px so the window's text stays legible.
- **Breakpoints:** at 1068px the facts grid drops to 2 columns and splits stack at 48px. At 734px the nav links hide (brand and Download pill remain), facts, feature list and trio go to 1 column at 36px, section padding drops to 80px, the status panel tightens, and screenshots swap to phone crops.
- **Phone crops:** each wide screenshot is a `<picture>` with a `(max-width: 734px)` source pointing at a native-scale crop of the same real window (grid view 784×492, Storage Overview 624×870), so phones see legible UI rather than a shrunken desktop.
- **Anchors:** smooth scrolling with a 64px scroll padding so section titles clear the sticky nav.

## Elevation & Depth

The page is flat. Sections are separated by tonal bands, not shadows; the status panel is a flat Band Grey surface on white. Depth is reserved for the product: real windows float on a soft two-layer shadow, and the app icon casts a blue-tinted drop shadow. The nav is the only translucent layer.

### Shadow Vocabulary
- **Window shadow** (`box-shadow: 0 2px 6px rgb(0 0 0 / 0.12), 0 34px 70px -18px rgb(0 0 0 / 0.42)`): every screenshot window, a tight contact shadow plus a long, inset, offset lift, like a macOS window.
- **Hero icon glow** (`filter: drop-shadow(0 12px 22px rgb(0 40 120 / 0.28))`): the 112px hero icon.
- **Get icon glow** (`filter: drop-shadow(0 10px 18px rgb(0 40 120 / 0.25))`): the 96px icon in the get block and on the 404 page.
- **Nav glass** (`backdrop-filter: saturate(1.8) blur(20px)` over Nav Glass with a Hairline bottom border): the sticky nav.

### Named Rules
**The Product Floats Rule.** Only the app's own windows and icon carry shadow. Panels, pills and sections stay flat.

## Shapes

Soft, Apple-standard geometry. Buttons and badges are full pills (999px). The status panel is the one rounded container (24px). Screenshot corners are not a design choice but a measurement: the captured windows round 18px of their 1224px width, so the window radius is expressed as percentages of the image (1.47% / 2.34% for the 1224×768 grid view, 1.47% / 2.07% for the 1224×870 Storage Overview) and stays true at any display size. Phone crops recompute the same 18px at crop scale (2.3% / 3.66% for 784×492, 2.88% / 2.07% for 624×870). The list-detail crop, cut from inside the window, takes a plain 14px. The app icon artwork is full-bleed and shows inside the macOS rounded-square mask (22.5%). Focus rings round at 4px.

### Named Rules
**The Measured Corner Rule.** A screenshot's radius matches the window's own 18px corner at the image's scale. Never round a real window with an arbitrary token.

## Components

### Navigation
- **Style:** sticky, 52px tall, Nav Glass with backdrop blur and a Hairline bottom border; inner row on the 1080px measure with a 28px gap.
- **Content:** 28px masked app icon + "OpenBucket" (Brand, 9px gap) on the left; Features, Compatibility, Security, GitHub (Nav, Ink at 0.8 opacity, 26px gap); the small Download pill at the right.
- **States:** links go to full opacity on hover with no underline.
- **Phone:** links hide; brand and Download pill remain.

### Buttons
- **Shape:** full pill (999px).
- **Primary:** Action Blue fill, white label, 17px/500, min-height 48px, 0 24px padding, optional 19px download glyph at an 8px gap.
- **Small:** same fill, min-height 28px, 0 14px padding, 13px label; nav only.
- **Hover / Focus:** background eases to Action Blue Hover over 0.2s, no underline; focus is a 2px Action Blue outline at a 3px offset.

### Text links
- **Style:** Link Blue, 19px, followed by a 16-17px arrow-up-right icon at a 2px gap; Night Link Blue inside the black band.
- **Hover:** underline at a 0.16em offset.
- **Pairing:** next to the primary pill for the secondary path ("View on GitHub"), or alone at the end of a section.

### Hero
Centred stack: 112px app icon, Display headline in two lines, Lede, actions row (pill + text link, 18px × 32px gaps), Fine release line ("Version x · macOS 26 or later · Apple silicon and Intel · Signed and notarized"), then the hero window, which starts inside the first viewport and continues below the fold.

### Window figure + caption
- **Image:** a real screenshot with the measured window radius and Window shadow, up to 1100px wide.
- **Caption:** Fine, Secondary Ink, 18px below, saying what the window really is ("A real OpenBucket window, connected to a local Garage bucket of demo files.").
- **Detail variant:** a 1014px list-detail crop with a 14px radius sits under the facts grid.

### Facts grid
Three columns of icon + Title + Secondary Ink body. Icons are 28px Lucide line icons at 1.7 stroke in Action Blue; titles sit 14px below the icon.

### Checks list
Single column, 18px apart, 19px copy with an 18px Action Blue check (2.4 stroke) in a 26px gutter column.

### Status panel + badges
- **Panel:** Band Grey, 24px radius, 32px 32px 28px padding (24px 22px 22px on phones), Panel label title.
- **Rows:** provider name (600) and a badge on one line, the note (Callout, Secondary Ink) below, 16px row padding, Hairline divider.
- **Badges:** pill, 2px 10px, 12px/600: Tested (green), Implemented (blue), Not yet tested (grey). A badge states exactly what the compatibility document states.
- **Close:** a 17px text link to the compatibility details, 20px above.

### Feature list
Two columns of term (Title) + description (Body, Secondary Ink), each row 16px padded under a Hairline top rule; one column on phones.

### Dark band trio
- **Band:** Night ground, centred, 44px shield icon (1.5 stroke) in Night Link Blue, Headline in Night Ink, Lede in Night Secondary Ink.
- **Trio:** three left-aligned columns at 48px, max 940px, each a 26px Night Link Blue icon, Title in Night Ink, body in Night Secondary Ink; a Night Link Blue text link closes the band.

### Open-source block
Plain section, centred: Headline, Lede, and a row of three text links (Source code, Release notes, Contribute).

### Get block
Centred close: 96px app icon with the Get icon glow, Headline ("Get OpenBucket."), the primary pill, and a Fine line that names the release and asks for bug reports. The 404 page reuses this block with "Go to OpenBucket".

### Footer
Band Grey, 12px Secondary Ink, on the measure with a Hairline top rule and 22px 22px 36px padding: maker line, a wrapping row of Footer Link Grey links (6px × 22px gaps), and the trademark line stating that OpenBucket is not affiliated with Amazon or Apple.

### Signature: the settling window
The hero window settles as it scrolls into view: a CSS scroll-driven animation on `view()` over `entry 10% cover 45%`, from `perspective(1600px) rotateX(9deg) translateY(28px) scale(0.94)` to no transform, linear, both fill. It runs only under `prefers-reduced-motion: no-preference` and where `animation-timeline: view()` is supported; otherwise the window simply sits flat. Under `prefers-reduced-motion: reduce`, smooth scrolling and all transitions are also switched off.

## Do's and Don'ts

### Do:
- **Do** show only real OpenBucket screenshots, with the measured window radius and the Window shadow, and caption them truthfully.
- **Do** cut phone crops from the same real window at native scale and serve them through `<picture>` at `(max-width: 734px)`, recomputing the 18px corner at crop scale.
- **Do** keep every claim inside the documented evidence: Garage 2.4.1 and Adobe S3Mock as Tested, Amazon S3 as Implemented, MinIO, RustFS and others as Not yet tested.
- **Do** keep one obvious download path: an Action Blue pill, with the source one text link away.
- **Do** use the system font stack, semibold (600) headlines with negative tracking, and 17px body.
- **Do** alternate Canvas White and Band Grey sections at 120px (80px on phones), with exactly one Night band.
- **Do** keep the settle animation still under reduced motion.

### Don't:
- **Don't** use mockups, illustrations, renders or stock imagery; the app icon is the only illustration.
- **Don't** show or invent adoption numbers, stars, downloads, testimonials, ratings, press or benchmarks.
- **Don't** say or imply "works with every provider".
- **Don't** imply affiliation with or endorsement by Amazon or Apple; keep the trademark and non-affiliation line in the footer.
- **Don't** add a second filled button colour, gradients, or the dark developer-tool look.
- **Don't** round screenshots with an arbitrary radius or put shadows on panels, pills or sections.
