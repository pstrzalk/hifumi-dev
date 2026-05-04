# Frontend template: earth

## Vibe

Muted, warm, low-contrast — sage, clay, and warm off-white. Slab-serif headings over a soft serif body, modest radii, no harsh borders, no shadows except the lightest hint of paper texture. Reads like a slow-living journal or a thoughtful longform blog.

## Fonts

- Display/headings: Roboto Slab (medium to semibold)
- Body / labels: Source Serif 4 (regular, occasional italic)

The font `<link>` is already loaded in `app/views/layouts/application.html.erb`.

## Class snippets

### Button (primary)
```erb
<%= button_tag "Save", class: "px-5 py-2.5 bg-[#6B7F5F] text-[#F5F0E8] font-display font-medium rounded-md hover:bg-[#5A6E4F] focus:outline-none focus:ring-2 focus:ring-[#6B7F5F] focus:ring-offset-2 focus:ring-offset-[#F5F0E8] disabled:opacity-50" %>
```
Secondary: `bg-transparent border border-[#6B7F5F] text-[#6B7F5F] hover:bg-[#EDE6D6]`. Ghost: `text-[#6B7F5F] hover:bg-[#EDE6D6]`.

### Form field (label + input)
```erb
<div class="space-y-1.5">
  <%= form.label :name, class: "block font-display text-sm text-[#4A4338]" %>
  <%= form.text_field :name, class: "block w-full px-3.5 py-2 bg-[#FBF8F1] border border-[#D9D0BC] rounded-md text-[#2E2A22] placeholder:text-[#A89E88] focus:outline-none focus:border-[#6B7F5F] focus:ring-1 focus:ring-[#6B7F5F] aria-invalid:border-[#A65A3D]" %>
</div>
```

### Card
```erb
<div class="bg-[#FBF8F1] border border-[#E5DDC8] rounded-md p-7">
  <h2 class="font-display text-xl text-[#2E2A22] mb-3">Title</h2>
  <div class="text-[#4A4338] leading-relaxed">Body copy with a calm reading rhythm.</div>
</div>
```

### App shell + top nav
```erb
<body class="bg-[#F5F0E8] text-[#2E2A22] min-h-screen">
  <nav class="border-b border-[#E5DDC8] bg-[#F5F0E8]">
    <div class="max-w-4xl mx-auto px-6 h-14 flex items-center gap-6">
      <span class="font-display text-lg text-[#6B7F5F]">Field Notes</span>
      <%= link_to "Entries", "#", class: "text-sm text-[#4A4338] hover:text-[#6B7F5F]" %>
    </div>
  </nav>
  <main class="max-w-4xl mx-auto px-6 py-10"><%= yield %></main>
</body>
```

### Alert
```erb
<div class="bg-[#EDE6D6] text-[#4A4338] border border-[#D9D0BC] rounded-md px-4 py-3">
  <%= notice %>
</div>
```
States: success `bg-[#E3EAD6] text-[#3F5232] border-[#C4D2B0]`, warning `bg-[#F2E5C2] text-[#6E5A1F] border-[#D9C58A]`, error `bg-[#EFD7CC] text-[#7A3826] border-[#D9B59E]`.

## Layout density

- Container max-width: `max-w-4xl`. Page padding: `px-6 py-10`.
- Vertical rhythm between major blocks: `space-y-7`. Inside cards: `space-y-4`.

## Voice

- Sentence case for everything, including headings.
- Quiet, considered language — "publish entry" rather than "post". Long-form welcome.
- Allowed ornament: italic Source Serif for pull quotes, thin dividers (`<hr class="border-[#E5DDC8]">`). No emoji, no exclamation marks.
