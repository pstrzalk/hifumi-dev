# Frontend template: editorial

## Vibe

Magazine front page — black on white, no grey backgrounds, a heavy serif display at headline scale over a compact sans for every piece of metadata. Structure comes from rules: a thick rule under the masthead, hairlines between stories. One red accent for kickers and links, used sparingly. Square corners, no shadows, tight leading. Reads like a newspaper or a longform publication, not a blog theme.

## Fonts

- Display/headings: Source Serif 4 (600 and 700; italic for standfirsts and pull quotes)
- Body / metadata / labels: Inter (regular and medium; `uppercase tracking-wide text-xs` for kickers and bylines)

The font `<link>` is already loaded in `app/views/layouts/application.html.erb`.

## Class snippets

### Button (primary)
```erb
<%= button_tag "Subscribe", class: "px-5 py-2.5 bg-[#111111] text-white font-medium text-sm rounded-none hover:bg-[#C1272D] transition-colors focus:outline-none focus:ring-2 focus:ring-[#C1272D] focus:ring-offset-2 disabled:opacity-40" %>
```
Secondary: `bg-white border border-[#111111] text-[#111111] hover:bg-[#F5F5F5]`. Link style: `text-[#C1272D] underline underline-offset-2 hover:no-underline`.

### Form field (label + input)
```erb
<div class="space-y-1.5">
  <%= form.label :email, class: "block text-xs uppercase tracking-wide font-medium text-[#5A5A5A]" %>
  <%= form.email_field :email, class: "block w-full px-3 py-2 bg-white border border-[#DDDDDD] rounded-none text-[#111111] placeholder:text-[#9A9A9A] focus:outline-none focus:border-[#111111] aria-invalid:border-[#C1272D]" %>
</div>
```

### Card (story teaser)
```erb
<article class="border-t border-[#DDDDDD] pt-4">
  <p class="text-xs uppercase tracking-wide text-[#C1272D] mb-1.5">Kicker</p>
  <h2 class="font-display font-bold text-2xl text-[#111111] leading-tight mb-2">Headline that runs to two lines</h2>
  <p class="text-[#5A5A5A] leading-snug mb-2">Standfirst summarising the piece in a sentence.</p>
  <p class="text-xs uppercase tracking-wide text-[#9A9A9A]">By Name · 12 Sep 2026</p>
</article>
```

### App shell + masthead
```erb
<body class="bg-white text-[#111111] min-h-screen">
  <header class="border-b-2 border-[#111111]">
    <div class="max-w-6xl mx-auto px-6 py-5 flex items-baseline justify-between">
      <span class="font-display font-bold text-3xl tracking-tight">The Review</span>
      <%= link_to "Culture", "#", class: "text-xs uppercase tracking-wide text-[#5A5A5A] hover:text-[#C1272D]" %>
    </div>
  </header>
  <main class="max-w-6xl mx-auto px-6 py-10"><%= yield %></main>
</body>
```

### Alert
```erb
<div class="border-l-4 border-[#111111] bg-[#F5F5F5] px-4 py-3 text-sm text-[#111111]">
  <%= notice %>
</div>
```
States: success `border-[#1F6F43]`, warning `border-[#B5820C]`, error `border-[#C1272D] text-[#C1272D]`.

## Images

Photos are remote files, not asset-pipeline assets: pass the **full absolute URL** from the
photo list, never a bare filename — `image_tag "photos/x.jpg"` resolves through Propshaft and
breaks. Geometry is fixed: bands are 16:9, cards 1:1, headshots 2:3 — pair each with the
matching `aspect-` class and `object-cover`. Write `alt` from what is in the picture, never
"Placeholder". These snippets style the image only; keep your own caption or card content.

Press photography runs unfiltered and full width, with the headline set *below* the image
rather than over it — overlaid type is a marketing device, not an editorial one. Every image
takes a caption in small grey sans.

### Hero band (article lead)
```erb
<figure class="space-y-2">
  <%= image_tag "<absolute URL from the photo list>", alt: "Tower Bridge under a clear sky", class: "w-full object-cover aspect-video rounded-none" %>
  <figcaption class="text-xs text-[#9A9A9A]">Caption describing the photograph.</figcaption>
</figure>
```

### Portrait / avatar
`class: "w-full object-cover aspect-[2/3] rounded-none border border-[#DDDDDD]"` — bylines use `w-10 rounded-full aspect-square`.

### Image card
Wrap in the story teaser; image `class: "w-full object-cover aspect-square rounded-none mb-3"`.

## Layout density

- Masthead and index: `max-w-6xl`. Article body: `max-w-2xl` — measure beats width.
- Page padding: `px-6 py-10`. Story grids: `grid md:grid-cols-3 gap-x-8 gap-y-10`.
- Vertical rhythm between sections: `space-y-10`. Body copy `leading-relaxed`, headlines `leading-tight`.

## Voice

- Headlines in sentence case, no full stop. Kickers in uppercase. Bylines "By Name · 12 Sep 2026".
- Reported and specific — "Council rejects the bid", not "Big news about the bid!".
- No emoji, no exclamation marks, no second-person marketing copy. Dates spelled `12 Sep 2026`.
