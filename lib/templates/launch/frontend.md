# Frontend template: launch

## Vibe

Modern product landing page — near-white canvas, one indigo-to-violet gradient used sparingly, big confident headlines, generous vertical air, soft shadows and large radii. Reads like the marketing site in front of a SaaS product, not the dashboard behind it. Centred hero, feature grid, one clear call to action per screen.

## Fonts

- Display/headings: Plus Jakarta Sans (bold to extrabold, tight tracking)
- Body / labels: Inter (regular and medium)

The font `<link>` is already loaded in `app/views/layouts/application.html.erb`.

## Class snippets

### Button (primary)
```erb
<%= button_tag "Get started", class: "px-5 py-2.5 bg-[#4F46E5] text-white font-semibold text-sm rounded-xl shadow-sm hover:bg-[#4338CA] hover:shadow-md transition focus:outline-none focus:ring-2 focus:ring-[#818CF8] focus:ring-offset-2 disabled:opacity-50" %>
```
Secondary: `bg-white border border-[#E2E8F0] text-[#0B1120] hover:bg-[#F8FAFC]`. Ghost: `bg-transparent text-[#4F46E5] hover:bg-[#EEF2FF]`.

### Form field (label + input)
```erb
<div class="space-y-1.5">
  <%= form.label :email, class: "block font-medium text-sm text-[#0B1120]" %>
  <%= form.email_field :email, class: "block w-full px-4 py-2.5 bg-white border border-[#E2E8F0] rounded-xl text-[#0B1120] placeholder:text-[#94A3B8] focus:outline-none focus:border-[#4F46E5] focus:ring-2 focus:ring-[#EEF2FF] aria-invalid:border-[#DC2626]" %>
</div>
```

### Card
```erb
<div class="bg-white border border-[#E2E8F0] rounded-2xl shadow-sm p-6">
  <h2 class="font-display font-bold text-lg text-[#0B1120] mb-2">Title</h2>
  <div class="text-[#475569] leading-relaxed">Body copy that sells the point in two lines.</div>
</div>
```

### App shell + top nav
```erb
<body class="bg-white text-[#0B1120] min-h-screen">
  <nav class="sticky top-0 bg-white/80 backdrop-blur border-b border-[#E2E8F0] z-10">
    <div class="max-w-6xl mx-auto px-6 h-16 flex items-center justify-between">
      <span class="font-display font-extrabold text-lg tracking-tight">Product</span>
      <%= link_to "Get started", "#", class: "px-4 py-2 bg-[#4F46E5] text-white font-semibold text-sm rounded-xl" %>
    </div>
  </nav>
  <main class="max-w-6xl mx-auto px-6 py-16"><%= yield %></main>
</body>
```

### Alert
```erb
<div class="bg-[#EEF2FF] text-[#3730A3] border border-[#C7D2FE] rounded-xl px-4 py-3 text-sm">
  <%= notice %>
</div>
```
States: success `bg-[#ECFDF5] text-[#065F46] border-[#A7F3D0]`, warning `bg-[#FFFBEB] text-[#92400E] border-[#FDE68A]`, error `bg-[#FEF2F2] text-[#991B1B] border-[#FECACA]`.

## Images

Photos are remote files, not asset-pipeline assets: pass the **full absolute URL** from the
photo list, never a bare filename — `image_tag "photos/x.jpg"` resolves through Propshaft and
breaks. Geometry is fixed: bands are 16:9, cards 1:1, headshots 2:3 — pair each with the
matching `aspect-` class and `object-cover`. Write `alt` from what is in the picture, never
"Placeholder". These snippets style the image only; keep your own caption or card content.

This is the template a homepage photo matters most in. Keep colour, round the corners like
everything else, and tint the overlay indigo so the image belongs to the brand.

### Hero band
```erb
<section class="relative rounded-2xl shadow-sm overflow-hidden">
  <%= image_tag "<absolute URL from the photo list>", alt: "Sunlit living room", class: "absolute inset-0 w-full h-full object-cover" %>
  <div class="absolute inset-0 bg-gradient-to-r from-[#0B1120]/80 to-[#4F46E5]/50"></div>
  <div class="relative px-8 py-20 max-w-2xl space-y-5"><h1 class="font-display font-extrabold text-4xl text-white tracking-tight">Headline</h1></div>
</section>
```

### Portrait / avatar
`class: "w-full object-cover aspect-[2/3] rounded-xl border border-[#E2E8F0] shadow-sm"`

### Image card
Wrap in the Card snippet; image `class: "w-full object-cover aspect-square rounded-xl mb-4"`.

## Layout density

- Container max-width: `max-w-6xl`. Page padding: `px-6 py-16` — marketing pages breathe.
- Vertical rhythm between major sections: `space-y-20`. Inside cards: `space-y-3`.
- Feature grids: `grid md:grid-cols-3 gap-6`. Hero copy capped at `max-w-2xl`.

## Voice

- Sentence case headings. Short, declarative, benefit-first — "Ship faster", not "Shipping solutions".
- One call to action per section, phrased as the user's next step: "Start free", "Book a demo".
- No emoji, no exclamation marks, no invented statistics or customer logos.
