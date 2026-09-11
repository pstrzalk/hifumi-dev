# Frontend template: luxe

## Vibe

Quiet premium — warm ivory ground, near-black ink, one muted brass accent, high-contrast light serif at large sizes against small letter-spaced caps for everything functional. Hairline rules instead of borders and shadows; square corners throughout. Space is the main material: if it looks too empty, it is close to right. Reads like a boutique hotel, a jeweller, or an estate agent's brochure — never like an app.

## Fonts

- Display/headings: Cormorant Garamond (300 and 400; italic for pull quotes)
- Body / labels / nav: Jost (300 and 400; `tracking-[0.2em] uppercase` for labels)

The font `<link>` is already loaded in `app/views/layouts/application.html.erb`.

## Class snippets

### Button (primary)
```erb
<%= button_tag "Enquire", class: "px-8 py-3 bg-[#1A1815] text-[#FAF7F2] text-xs uppercase tracking-[0.2em] rounded-none hover:bg-[#A98B5D] transition-colors focus:outline-none focus:ring-1 focus:ring-[#A98B5D] focus:ring-offset-2 focus:ring-offset-[#FAF7F2] disabled:opacity-40" %>
```
Secondary: `bg-transparent border border-[#1A1815] text-[#1A1815] hover:bg-[#1A1815] hover:text-[#FAF7F2]`. Quiet: `bg-transparent text-[#6B645C] underline underline-offset-4 hover:text-[#A98B5D]`.

### Form field (label + input)
```erb
<div class="space-y-2">
  <%= form.label :name, class: "block text-[11px] uppercase tracking-[0.2em] text-[#6B645C]" %>
  <%= form.text_field :name, class: "block w-full px-0 py-2 bg-transparent border-0 border-b border-[#E3DCD1] rounded-none text-[#1A1815] placeholder:text-[#B5ADA1] focus:outline-none focus:border-[#A98B5D] aria-invalid:border-[#8C3A3A]" %>
</div>
```

### Card
```erb
<div class="bg-transparent border-t border-[#E3DCD1] pt-8">
  <h2 class="font-display font-light text-3xl text-[#1A1815] mb-4">Title</h2>
  <div class="text-[#6B645C] leading-loose">Body copy set generously, with room to breathe.</div>
</div>
```

### App shell + top nav
```erb
<body class="bg-[#FAF7F2] text-[#1A1815] min-h-screen">
  <nav class="border-b border-[#E3DCD1]">
    <div class="max-w-6xl mx-auto px-8 h-20 flex items-center justify-between">
      <span class="font-display font-light text-2xl tracking-wide">Maison</span>
      <%= link_to "Rooms", "#", class: "text-[11px] uppercase tracking-[0.2em] text-[#6B645C] hover:text-[#A98B5D]" %>
    </div>
  </nav>
  <main class="max-w-6xl mx-auto px-8 py-20"><%= yield %></main>
</body>
```

### Alert
```erb
<div class="border-l-2 border-[#A98B5D] bg-transparent px-6 py-3 text-sm text-[#6B645C]">
  <%= notice %>
</div>
```
States: success `border-[#5F7A5F]`, warning `border-[#B08A3E]`, error `border-[#8C3A3A] text-[#8C3A3A]`.

## Images

Photos are remote files, not asset-pipeline assets: pass the **full absolute URL** from the
photo list, never a bare filename — `image_tag "photos/x.jpg"` resolves through Propshaft and
breaks. Geometry is fixed: bands are 16:9, cards 1:1, headshots 2:3 — pair each with the
matching `aspect-` class and `object-cover`. Write `alt` from what is in the picture, never
"Placeholder". These snippets style the image only; keep your own caption or card content.

The photo set's warm neutral palette is already this template's palette — apply no filter and
no heavy scrim. Let images run large and full-bleed; restraint lives in the chrome, not the
picture. Square corners, hairline rule at most.

### Hero band
```erb
<section class="relative rounded-none overflow-hidden">
  <%= image_tag "<absolute URL from the photo list>", alt: "Sunlit living room", class: "absolute inset-0 w-full h-full object-cover" %>
  <div class="absolute inset-0 bg-[#12100E]/30"></div>
  <div class="relative px-8 py-32 max-w-xl space-y-6"><h1 class="font-display font-light text-5xl text-[#FAF7F2]">Headline</h1></div>
</section>
```

### Portrait / avatar
`class: "w-full object-cover aspect-[2/3] rounded-none"` — no border; separate portraits with whitespace.

### Image card
Wrap in the Card snippet; image `class: "w-full object-cover aspect-square rounded-none mb-6"`.

## Layout density

- Container max-width: `max-w-6xl`. Page padding: `px-8 py-20`. Prose columns cap at `max-w-xl`.
- Vertical rhythm between major blocks: `space-y-24`. Inside a block: `space-y-6`.
- Rules over boxes: `border-t border-[#E3DCD1]` to separate sections. No shadows anywhere.

## Voice

- Title Case for proper nouns and section headings; sentence case for body.
- Understated and specific — "Seventeen rooms, no two alike", not "Amazing luxury rooms!".
- Never exclaim, never discount, never urgency-sell. No emoji. Prices plain, unbolded.
