# Git Integration — pomysły

Git nie jest tylko mechanizmem wewnętrznym (checkpointing, revert). Jest narzędziem edukacyjnym i profesjonalnym. Użytkownicy uczą się Rails patrząc na to co agent zrobił i jak.

## Motywacja

- **Popularyzacja Ruby on Rails** — to jest nadrzędny cel. Wygenerowana apka to czyste repo Rails, nie vendor lock-in. User dostaje profesjonalną bazę i kontynuuje standardowymi narzędziami Rails.
- Narzędzie dla profesjonalistów i przyszłych profesjonalistów
- Git diff = "co agent zrobił i dlaczego" — najlepsza forma nauki
- Export = "teraz to twój projekt." Zero zależności od naszej platformy. Standardowy Rails, standardowy git, standardowe narzędzia.
- Czysta historia git = profesjonalna baza, nie wygenerowany blob

## Pomysły

### Widoczność zmian
- **Git diff między rewizjami** — w UI, syntax-highlighted. User klika rewizję → widzi co się zmieniło. Uczy się jak agent buduje aplikację Rails.
- **Annotated commits** — każdy commit ma sensowny message opisujący CO i DLACZEGO. Nie "update files" ale "Add Flower model with name, price, seasonal availability. Belongs_to :category with counter cache."
- **Diff w chacie** — po zakończeniu rewizji LLM może pokazać kluczowe zmiany inline, nie tylko "zrobione". Tool `ShowDiff`?
- **File browser** — przeglądanie wygenerowanego kodu per rewizja. Jak GitHub code view ale w naszym UI.
- **Blame view** — która instrukcja/rewizja dodała którą linię. Łączy kod z decyzjami z chatu.

### Export i kontynuacja pracy
- **Push to GitHub** — OAuth, nowe repo, pełna historia commitów
- **Push to GitLab / Bitbucket** — analogicznie
- **Clone instructions** — "oto jak sklonować i kontynuować lokalnie" (wyświetlane po exporcie)
- **Czyste repo Rails** — zero zależności od naszej platformy. Wygenerowana apka to standardowy Rails project: `git clone`, `bundle install`, `rails db:prepare`, `rails server`. Działa z dowolnym edytorem, CI, hostingiem. Żadnych custom wrapperów, żadnych proprietary gemów.
- **README.md** — generowany automatycznie: co to za apka, jak uruchomić, jakie gemy i dlaczego, decyzje architektoniczne. Standardowy onboarding dla nowego developera.
- **CLAUDE.md** — opcjonalnie, dla tych którzy chcą kontynuować z Claude Code. Ale to dodatek, nie wymóg.

### Edukacja
- **"Explain this change"** — user klika na diff i pyta "dlaczego tak?" → LLM wyjaśnia w kontekście Rails Way
- **Step-by-step replay** — odtwarzanie budowy aplikacji krok po kroku. Jak timelapse ale z wyjaśnieniami. "Oto jak zbudowano tę apkę od zera."
- **Rails conventions highlighting** — w diffie zaznaczanie "to jest konwencja Rails" vs "to jest specyficzne dla twojej apki"
- **Compare with alternative** — "jak by to wyglądało gdybyśmy użyli X zamiast Y?" (przyszłość, wymaga branching)

### Profesjonalne workflow
- **Branch per feature** — zamiast liniowej historii, opcjonalnie: każda instrukcja to branch + merge. Bardziej realistyczny git flow.
- **PR-like review** — przed zaaplikowaniem rewizji user może zrobić "review" zmian. Code review jako forma nauki.
- **Git hooks w wygenerowanej apce** — linting (HERB), testy, formatowanie. Uczy dobrych praktyk od pierwszego dnia.
- **Conventional commits** — format commitów (feat:, fix:, refactor:) żeby historia była czytelna

### Współpraca
- **Invite collaborator** — ktoś inny może dołączyć do projektu i kontynuować w chacie
- **Fork project** — skopiuj czyjś projekt i modyfikuj (jak GitHub fork)
- **Share snapshot** — link do konkretnej rewizji do pokazania komuś

## Status

Faza: zbiór pomysłów, do priorytetyzacji na roadmapie.
