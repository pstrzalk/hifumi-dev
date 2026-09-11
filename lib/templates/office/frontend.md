# Frontend template: office

## Vibe

Professional B2B dashboard — neutral greys with one strong navy/blue accent, dense data layouts, narrow row heights, restrained colour. Reads like Jira, Linear, or an internal admin console. Sharp small radii, hover states subtle, no decorative shadows.

## Fonts

- Display/headings: Inter (semibold)
- Body / labels / data: Inter (regular and medium)

One typeface family for the whole UI. Tabular numerals for tables (`tabular-nums`).

The font `<link>` is already loaded in `app/views/layouts/application.html.erb`.

## Class snippets

### Button (primary)
```erb
<%= button_tag "Save", class: "px-3 py-1.5 bg-[#0052CC] text-white font-medium text-sm rounded-sm hover:bg-[#0747A6] focus:outline-none focus:ring-2 focus:ring-[#4C9AFF] disabled:opacity-50" %>
```
Secondary: `bg-white border border-[#DFE1E6] text-[#172B4D] hover:bg-[#F4F5F7]`. Subtle/ghost: `bg-transparent text-[#0052CC] hover:bg-[#DEEBFF]`. Danger: `bg-[#DE350B] hover:bg-[#BF2600]`.

### Form field (label + input)
```erb
<div class="space-y-1">
  <%= form.label :name, class: "block font-medium text-xs text-[#5E6C84] uppercase tracking-wide" %>
  <%= form.text_field :name, class: "block w-full px-2.5 py-1.5 bg-white border border-[#DFE1E6] rounded-sm text-sm text-[#172B4D] placeholder:text-[#7A869A] focus:outline-none focus:border-[#4C9AFF] focus:ring-1 focus:ring-[#4C9AFF] aria-invalid:border-[#DE350B]" %>
</div>
```

### Card
```erb
<div class="bg-white border border-[#DFE1E6] rounded-sm p-5">
  <h2 class="font-semibold text-base text-[#172B4D] mb-3">Title</h2>
  <div class="text-sm text-[#42526E] leading-snug">Body</div>
</div>
```

### App shell + top nav
```erb
<body class="bg-[#F4F5F7] text-[#172B4D] min-h-screen">
  <nav class="bg-white border-b border-[#DFE1E6]">
    <div class="max-w-7xl mx-auto px-4 h-12 flex items-center gap-5">
      <span class="font-semibold text-[#0052CC]">Workboard</span>
      <%= link_to "Issues", "#", class: "text-sm font-medium text-[#42526E] hover:text-[#0052CC] hover:bg-[#DEEBFF] px-2 py-1 rounded-sm" %>
    </div>
  </nav>
  <main class="max-w-7xl mx-auto px-4 py-6"><%= yield %></main>
</body>
```

### Alert
```erb
<div class="bg-[#DEEBFF] text-[#0747A6] border-l-4 border-[#0052CC] px-3 py-2 text-sm rounded-sm">
  <%= notice %>
</div>
```
States: success `bg-[#E3FCEF] text-[#006644] border-[#00875A]`, warning `bg-[#FFFAE6] text-[#974F0C] border-[#FF991F]`, error `bg-[#FFEBE6] text-[#BF2600] border-[#DE350B]`.

## Images

Photos are remote files, not asset-pipeline assets: pass the **full absolute URL** from the
photo list, never a bare filename — `image_tag "photos/x.jpg"` resolves through Propshaft and
breaks. Geometry is fixed: bands are 16:9, cards 1:1, headshots 2:3 — pair each with the
matching `aspect-` class and `object-cover`. Write `alt` from what is in the picture, never
"Placeholder". These snippets style the image only; keep your own caption or card content.

Images are content, not decoration: hairline border, small radius, no filter and no
shadow. Keep `rounded-sm` — `rounded-lg` on a photo breaks the shell.

### Hero band
```erb
<section class="relative rounded-sm border border-[#DFE1E6] overflow-hidden">
  <%= image_tag "<absolute URL from the photo list>", alt: "Empty conference stage", class: "absolute inset-0 w-full h-full object-cover" %>
  <div class="absolute inset-0 bg-[#172B4D]/75"></div>
  <div class="relative px-6 py-10 max-w-2xl space-y-3"><h1 class="font-semibold text-2xl text-white">Headline</h1></div>
</section>
```

### Portrait / avatar
`class: "w-full object-cover aspect-[2/3] rounded-sm border border-[#DFE1E6]"`

### Image card
Wrap in the Card snippet; image `class: "w-full object-cover aspect-square rounded-sm border border-[#DFE1E6]"`.

## Layout density

- Container max-width: `max-w-7xl`. Page padding: `px-4 py-6`.
- Tables: row height `py-2`, hover `hover:bg-[#F4F5F7]`. Forms: `space-y-3` between fields.
- Vertical rhythm between major blocks: `space-y-5`.

## Voice

- Sentence case headings, Title Case for product/proper nouns.
- Direct and operational — "Assign issue", "Move to done". No marketing copy.
- No emoji, no exclamation marks, no decorative ornament.
