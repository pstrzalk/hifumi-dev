# Frontend template: flower

## Vibe

Soft pastel boutique — pinks and lavenders on warm cream, generous padding, rounded everything, decorative serif headings paired with a friendly sans body. Soft drop shadows, no hard edges. Reads like a small wedding-florist site or a wellness brand, not a dashboard.

## Fonts

- Display/headings: Playfair Display (italic permitted for accents)
- Body / labels: Quicksand (medium for buttons and labels)

The font `<link>` is already loaded in `app/views/layouts/application.html.erb`.

## Class snippets

### Button (primary)
```erb
<%= button_tag "Save", class: "px-6 py-3 bg-[#E8639E] text-white font-medium rounded-2xl shadow-md hover:bg-[#D14F8A] hover:shadow-lg transition focus:outline-none focus:ring-2 focus:ring-[#E8639E] focus:ring-offset-2 disabled:opacity-50" %>
```
Secondary: swap bg to `bg-white border border-[#E8639E] text-[#E8639E]`. Ghost: `bg-transparent text-[#7A4A6F] hover:bg-[#FFF5F7]`.

### Form field (label + input)
```erb
<div class="space-y-1.5">
  <%= form.label :name, class: "block font-medium text-sm text-[#7A4A6F]" %>
  <%= form.text_field :name, class: "block w-full px-4 py-2.5 bg-white border border-[#F2D5DF] rounded-xl text-[#3D2A35] placeholder:text-[#C7A5B5] focus:outline-none focus:border-[#E8639E] focus:ring-2 focus:ring-[#FCE4ED] aria-invalid:border-[#D14F8A]" %>
</div>
```

### Card
```erb
<div class="bg-white rounded-2xl shadow-md p-8 border border-[#FCE4ED]">
  <h2 class="font-display text-2xl text-[#3D2A35] mb-3">Title</h2>
  <div class="text-[#5C4351] leading-relaxed">Body copy that flows.</div>
</div>
```

### App shell + top nav
```erb
<body class="bg-[#FFF5F7] text-[#3D2A35] min-h-screen">
  <nav class="bg-white/80 backdrop-blur border-b border-[#FCE4ED]">
    <div class="max-w-5xl mx-auto px-6 h-16 flex items-center gap-8">
      <span class="font-display text-xl text-[#E8639E]">Bloom</span>
      <%= link_to "Bouquets", "#", class: "text-sm text-[#7A4A6F] hover:text-[#E8639E]" %>
    </div>
  </nav>
  <main class="max-w-5xl mx-auto px-6 py-10"><%= yield %></main>
</body>
```

### Alert
```erb
<div class="bg-[#FCE4ED] text-[#7A4A6F] border border-[#F2D5DF] rounded-xl px-5 py-3 shadow-sm">
  <%= notice %>
</div>
```
States: success `bg-[#E8F5E9] text-[#3F6D45] border-[#C8E6C9]`, warning `bg-[#FFF4E0] text-[#7A5826] border-[#F2DAA8]`, error `bg-[#FDEAEA] text-[#9B3338] border-[#F2C5C8]`.

## Layout density

- Container max-width: `max-w-5xl`. Page padding: `px-6 py-10`.
- Vertical rhythm between major blocks: `space-y-8`. Inside cards: `space-y-5`.

## Voice

- Title Case for headings ("Wedding Bouquets"), sentence case for buttons and body.
- Warm and inviting — "Add to bouquet", not "Submit". "We'll be in touch", not "Form submitted".
- Allowed ornament: italic Playfair for taglines, soft dividers (`<hr class="border-[#FCE4ED]">`). No emoji.
