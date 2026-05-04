# Frontend template: cyber

## Vibe

Dark terminal aesthetic — near-black backgrounds, neon-cyan accents, sharp corners, mono-first type, uppercase tracked labels. Reads like a secure-shell session, not a SaaS dashboard. No drop shadows except optional accent glow.

## Fonts

- Display/headings: Space Grotesk (semibold, slightly tracked)
- Body / labels / code: JetBrains Mono

The font `<link>` is already loaded in `app/views/layouts/application.html.erb`.

## Class snippets

### Button (primary)
```erb
<%= button_tag "Save", class: "px-4 py-2 bg-[#00FFCC] text-[#07090E] font-mono uppercase tracking-wider text-sm rounded-none hover:bg-[#33FFD4] focus:outline-none focus:ring-2 focus:ring-[#00FFCC] focus:ring-offset-2 focus:ring-offset-[#07090E] disabled:opacity-50" %>
```
Derive secondary by swapping bg to `bg-transparent border border-[#00FFCC] text-[#00FFCC]`. Danger: `bg-[#FF3366] text-[#07090E]`.

### Form field (label + input)
```erb
<div class="space-y-1">
  <%= form.label :name, class: "block font-mono uppercase tracking-wider text-xs text-[#7A8190]" %>
  <%= form.text_field :name, class: "block w-full px-3 py-2 bg-[#0D1118] border border-[#1E2530] rounded-none text-[#E6EDF3] font-mono placeholder:text-[#4A5260] focus:outline-none focus:border-[#00FFCC] aria-invalid:border-[#FF3366]" %>
</div>
```

### Card
```erb
<div class="bg-[#0D1118] border border-[#1E2530] rounded-none p-6">
  <h2 class="font-display text-lg text-[#E6EDF3] uppercase tracking-wider mb-4">Title</h2>
  <div class="font-mono text-sm text-[#B7C0CC]">Body</div>
</div>
```

### App shell + top nav
```erb
<body class="bg-[#07090E] text-[#E6EDF3] font-mono min-h-screen">
  <nav class="border-b border-[#1E2530] bg-[#0D1118]">
    <div class="max-w-6xl mx-auto px-4 h-12 flex items-center gap-6">
      <span class="text-[#00FFCC] font-display uppercase tracking-widest">&gt; app</span>
      <%= link_to "tasks", "#", class: "text-xs uppercase tracking-wider text-[#B7C0CC] hover:text-[#00FFCC]" %>
    </div>
  </nav>
  <main class="max-w-6xl mx-auto px-4 py-8"><%= yield %></main>
</body>
```

### Alert
```erb
<div class="border border-[#00FFCC] bg-[#0D1118] text-[#00FFCC] font-mono text-sm uppercase tracking-wider px-4 py-2 rounded-none">
  &gt; <%= notice %>
</div>
```
Swap colour for state: error `border-[#FF3366] text-[#FF3366]`, warning `border-[#FFCC00] text-[#FFCC00]`, info `border-[#7A8190] text-[#B7C0CC]`.

## Layout density

- Container max-width: `max-w-6xl`. Page padding: `px-4 py-8`.
- Vertical rhythm between major blocks: `space-y-6`. Inside cards: `space-y-4`.

## Voice

- UPPERCASE LABELS for nav, button, table head. Sentence case for body copy.
- Prefix terminal-feel menu items and prompts with `&gt;`. No emoji, no decorative ornament.
- Copy register: terse, technical. "deploy" not "deploy now".
