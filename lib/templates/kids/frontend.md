# Frontend template: kids

## Vibe

Bright, bold, playful — primary red/blue/yellow on cream, thick black borders, big rounded corners, chunky offset shadows. Reads like a children's learning app or a friendly game. Confident, big buttons; nothing subtle.

## Fonts

- Display/headings: Lilita One (always uppercase or Title Case, slight letterspacing)
- Body / labels / buttons: Fredoka (medium to semibold)

The font `<link>` is already loaded in `app/views/layouts/application.html.erb`.

## Class snippets

### Button (primary)
```erb
<%= button_tag "Go!", class: "px-6 py-3 bg-[#FF4136] text-white font-display text-lg rounded-2xl border-2 border-[#1A1A1A] shadow-[4px_4px_0_#1A1A1A] hover:translate-y-0.5 hover:shadow-[2px_2px_0_#1A1A1A] active:translate-y-1 active:shadow-none transition focus:outline-none focus:ring-2 focus:ring-[#1A1A1A] focus:ring-offset-2 disabled:opacity-50" %>
```
Variants: primary blue `bg-[#0074D9]`, primary yellow `bg-[#FFD23F] text-[#1A1A1A]`, ghost `bg-white text-[#1A1A1A]`. Keep the black border + offset shadow on every variant — it's the language.

### Form field (label + input)
```erb
<div class="space-y-2">
  <%= form.label :name, class: "block font-display text-base text-[#1A1A1A]" %>
  <%= form.text_field :name, class: "block w-full px-4 py-3 bg-white border-2 border-[#1A1A1A] rounded-2xl text-[#1A1A1A] placeholder:text-[#888] focus:outline-none focus:ring-2 focus:ring-[#FFD23F] aria-invalid:border-[#FF4136]" %>
</div>
```

### Card
```erb
<div class="bg-white rounded-2xl border-2 border-[#1A1A1A] shadow-[6px_6px_0_#1A1A1A] p-6">
  <h2 class="font-display text-2xl text-[#1A1A1A] mb-3">Title</h2>
  <div class="text-[#333] font-medium">Body</div>
</div>
```

### App shell + top nav
```erb
<body class="bg-[#FFFCEE] text-[#1A1A1A] min-h-screen">
  <nav class="bg-[#FFD23F] border-b-2 border-[#1A1A1A]">
    <div class="max-w-5xl mx-auto px-5 h-16 flex items-center gap-5">
      <span class="font-display text-2xl text-[#1A1A1A]">Wonderland</span>
      <%= link_to "Levels", "#", class: "font-display text-base px-3 py-1 rounded-xl bg-white border-2 border-[#1A1A1A] hover:bg-[#FFE680]" %>
    </div>
  </nav>
  <main class="max-w-5xl mx-auto px-5 py-8"><%= yield %></main>
</body>
```

### Alert
```erb
<div class="bg-[#FFD23F] text-[#1A1A1A] border-2 border-[#1A1A1A] rounded-2xl shadow-[4px_4px_0_#1A1A1A] px-5 py-3 font-medium">
  <%= notice %>
</div>
```
States: success `bg-[#2ECC40]`, error `bg-[#FF4136] text-white`, info `bg-[#0074D9] text-white`. Border + shadow stay constant.

## Layout density

- Container max-width: `max-w-5xl`. Page padding: `px-5 py-8`.
- Vertical rhythm between major blocks: `space-y-6`. Cards `space-y-4`.

## Voice

- Title Case headings, sentence case body. Energetic — "Let's go!", "Nice work!".
- Exclamation marks allowed sparingly. No emoji in core UI (icons stay illustrative SVGs).
- Allowed ornament: thick black borders + offset shadow on every interactive element. Don't drop the shadow language.
