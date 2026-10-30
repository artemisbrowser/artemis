#!/usr/bin/env python3
"""Build the URL list the tab-rename corpus is captured from.

Writes one URL per line to ~/Downloads/artemis-corpus-urls.txt, where
`ARTEMIS_DIAG=corpus` picks it up (the app is sandboxed; Downloads is the
one place both sides can reach).

The point of the list is *spread*, not size. A thousand news articles would
say nothing a hundred don't, while the pages that actually break tab naming
are the awkward ones: titles that are a bare word ("Pricing"), titles that
are the site's name and nothing else, single-page apps that set their title
from script, consent walls, non-Latin scripts, and pages whose title is a
sentence. Every category below is here because it fails differently.
"""

import os

# Hard cases first — these are the ones that decide whether a prompt is good.
VAGUE_TITLES = [
    "https://stripe.com/pricing",
    "https://www.notion.com/pricing",
    "https://linear.app/pricing",
    "https://vercel.com/pricing",
    "https://www.figma.com/pricing/",
    "https://slack.com/pricing",
    "https://github.com/pricing",
    "https://openai.com/pricing/",
    "https://www.cloudflare.com/plans/",
    "https://about.gitlab.com/pricing/",
    "https://www.apple.com/uk/support/",
    "https://support.google.com/",
    "https://www.bbc.co.uk/news",
    "https://news.ycombinator.com/",
    "https://www.reddit.com/",
    "https://developer.mozilla.org/en-US/",
    "https://www.gov.uk/",
    "https://www.nhs.uk/",
    "https://www.w3.org/",
    "https://www.ietf.org/",
]

# Long, punctuated, SEO-stuffed titles — the classic "needs shortening" case.
LONG_TITLES = [
    "https://stackoverflow.com/questions/11227809/why-is-processing-a-sorted-array-faster-than-processing-an-unsorted-array",
    "https://stackoverflow.com/questions/1642028/what-is-the-operator-in-c-c",
    "https://stackoverflow.com/questions/231767/what-does-the-yield-keyword-do-in-python",
    "https://stackoverflow.com/questions/292357/what-is-the-difference-between-git-pull-and-git-fetch",
    "https://superuser.com/questions/217364/how-to-list-all-files-recursively",
    "https://askubuntu.com/questions/162391/how-do-i-fix-my-locale-issue",
    "https://www.theguardian.com/uk",
    "https://www.nytimes.com/section/technology",
    "https://arstechnica.com/gadgets/",
    "https://www.theverge.com/tech",
    "https://techcrunch.com/category/startups/",
    "https://www.wired.com/category/science/",
    "https://www.bbc.co.uk/food/recipes/spaghetti_bolognese_69553",
    "https://www.bbcgoodfood.com/recipes/classic-lasagne",
    "https://www.seriouseats.com/the-best-chocolate-chip-cookies-recipe",
    "https://www.allrecipes.com/recipe/17481/simple-white-cake/",
]

# Documentation — dense, technical, often one-word titles with a site suffix.
DOCS = [
    "https://developer.apple.com/documentation/swiftui/view",
    "https://developer.apple.com/documentation/webkit/wkwebview",
    "https://developer.apple.com/documentation/foundationmodels",
    "https://developer.mozilla.org/en-US/docs/Web/API/fetch",
    "https://developer.mozilla.org/en-US/docs/Web/CSS/grid-template-areas",
    "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Promise",
    "https://docs.python.org/3/library/asyncio.html",
    "https://docs.python.org/3/tutorial/classes.html",
    "https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html",
    "https://go.dev/doc/effective_go",
    "https://react.dev/learn/thinking-in-react",
    "https://vuejs.org/guide/introduction.html",
    "https://svelte.dev/docs/introduction",
    "https://tailwindcss.com/docs/flex",
    "https://docs.djangoproject.com/en/stable/topics/db/models/",
    "https://kubernetes.io/docs/concepts/workloads/pods/",
    "https://docs.docker.com/engine/reference/builder/",
    "https://www.postgresql.org/docs/current/queries-with.html",
    "https://redis.io/docs/latest/develop/data-types/",
    "https://developers.cloudflare.com/workers/",
    "https://swiftpackageindex.com/",
    "https://www.swift.org/documentation/",
]

# Reference and encyclopaedia — titles are the subject, so a good name is
# mostly "don't make it worse".
REFERENCE = [
    "https://en.wikipedia.org/wiki/Kakapo",
    "https://en.wikipedia.org/wiki/Byzantine_Empire",
    "https://en.wikipedia.org/wiki/Quantum_entanglement",
    "https://en.wikipedia.org/wiki/Rust_(programming_language)",
    "https://en.wikipedia.org/wiki/Battle_of_Trafalgar",
    "https://en.wikipedia.org/wiki/Photosynthesis",
    "https://en.wikipedia.org/wiki/Mariana_Trench",
    "https://en.wikipedia.org/wiki/Ada_Lovelace",
    "https://en.wikipedia.org/wiki/Great_Fire_of_London",
    "https://en.wikipedia.org/wiki/Bauhaus",
    "https://simple.wikipedia.org/wiki/Black_hole",
    "https://www.britannica.com/science/general-relativity",
    "https://plato.stanford.edu/entries/consciousness/",
    "https://www.etymonline.com/word/browser",
]

# Video, music, social — heavy SPAs whose titles arrive late and change.
MEDIA_SOCIAL = [
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "https://www.youtube.com/watch?v=v0hg84vhZKE",
    "https://www.youtube.com/@veritasium",
    "https://www.youtube.com/results?search_query=swiftui+tutorial",
    "https://vimeo.com/staffpicks",
    "https://soundcloud.com/discover",
    "https://open.spotify.com/",
    "https://bandcamp.com/",
    "https://www.twitch.tv/directory",
    "https://mastodon.social/explore",
    "https://bsky.app/",
    "https://www.reddit.com/r/apple/",
    "https://www.reddit.com/r/programming/",
    "https://lobste.rs/",
    "https://news.ycombinator.com/item?id=1",
]

# Commerce — long product titles stuffed with specifications.
COMMERCE = [
    "https://www.amazon.co.uk/dp/B0CHX3QBCH",
    "https://www.apple.com/uk/shop/buy-mac/macbook-pro",
    "https://www.johnlewis.com/electricals",
    "https://www.argos.co.uk/browse/technology/",
    "https://www.ikea.com/gb/en/cat/beds-bm003/",
    "https://www.etsy.com/uk/c/jewelry",
    "https://www.ebay.co.uk/b/Laptops-Netbooks/175672",
    "https://www.currys.co.uk/computing/laptops",
]

# Long-form writing and blogs — a real title, but a subject worth naming.
WRITING = [
    "https://danluu.com/deconstruct-files/",
    "https://jvns.ca/blog/2023/11/10/notes-on-nix/",
    "https://overreacted.io/a-complete-guide-to-useeffect/",
    "https://simonwillison.net/2025/Jan/1/",
    "https://blog.cloudflare.com/",
    "https://www.joelonsoftware.com/2000/04/06/things-you-should-never-do-part-i/",
    "https://paulgraham.com/greatwork.html",
    "https://waitbutwhy.com/2014/05/fermi-paradox.html",
    "https://slatestarcodex.com/",
    "https://www.raywenderlich.com/",
    "https://nshipster.com/",
    "https://www.swiftbysundell.com/",
    "https://css-tricks.com/",
    "https://ciechanow.ski/gears/",
]

# Academic and government — formal titles, PDFs, identifiers.
ACADEMIC_GOV = [
    "https://arxiv.org/abs/1706.03762",
    "https://arxiv.org/abs/2507.13575",
    "https://arxiv.org/list/cs.CL/recent",
    "https://pubmed.ncbi.nlm.nih.gov/",
    "https://www.nature.com/nature/",
    "https://www.science.org/",
    "https://scholar.google.com/",
    "https://www.legislation.gov.uk/ukpga/1998/29/contents",
    "https://www.gov.uk/browse/driving",
    "https://www.parliament.uk/",
    "https://www.who.int/health-topics/coronavirus",
    "https://data.gov.uk/",
    "https://www.ons.gov.uk/",
]

# Tools, dashboards and apps — often behind a login, titles like "Dashboard".
APPS = [
    "https://github.com/apple/swift",
    "https://github.com/rust-lang/rust/issues",
    "https://github.com/features/copilot",
    "https://gitlab.com/explore",
    "https://app.slack.com/",
    "https://calendar.google.com/",
    "https://mail.google.com/",
    "https://drive.google.com/",
    "https://www.notion.com/",
    "https://trello.com/",
    "https://linear.app/",
    "https://figma.com/",
    "https://www.canva.com/",
    "https://chatgpt.com/",
    "https://claude.ai/",
    "https://www.icloud.com/",
]

# Non-English and non-Latin — a token is roughly a character in CJK, so the
# context budget behaves completely differently here.
INTERNATIONAL = [
    "https://www.lemonde.fr/",
    "https://www.spiegel.de/",
    "https://elpais.com/",
    "https://www.corriere.it/",
    "https://www.asahi.com/",
    "https://www3.nhk.or.jp/news/",
    "https://www.people.com.cn/",
    "https://ja.wikipedia.org/wiki/富士山",
    "https://zh.wikipedia.org/wiki/長城",
    "https://ru.wikipedia.org/wiki/Москва",
    "https://ar.wikipedia.org/wiki/القاهرة",
    "https://ko.wikipedia.org/wiki/한글",
    "https://www.aljazeera.net/",
    "https://www.dw.com/de/themen/s-9077",
]

# Maps, weather, finance, sport, travel — data pages with terse titles.
UTILITY = [
    "https://www.google.com/maps",
    "https://www.openstreetmap.org/",
    "https://www.metoffice.gov.uk/weather/forecast/gcpvj0v07",
    "https://weather.com/",
    "https://finance.yahoo.com/quote/AAPL/",
    "https://www.bloomberg.com/markets",
    "https://www.ft.com/markets",
    "https://www.bbc.co.uk/sport/football",
    "https://www.espn.com/nba/",
    "https://www.skysports.com/football/live-scores",
    "https://www.nationalrail.co.uk/",
    "https://www.tfl.gov.uk/",
    "https://www.booking.com/",
    "https://www.airbnb.co.uk/",
    "https://www.skyscanner.net/",
    "https://www.timeanddate.com/worldclock/",
    "https://archive.org/",
    "https://www.wolframalpha.com/",
]

CATEGORIES = {
    "vague": VAGUE_TITLES,
    "long-title": LONG_TITLES,
    "docs": DOCS,
    "reference": REFERENCE,
    "media-social": MEDIA_SOCIAL,
    "commerce": COMMERCE,
    "writing": WRITING,
    "academic-gov": ACADEMIC_GOV,
    "apps": APPS,
    "international": INTERNATIONAL,
    "utility": UTILITY,
}

# Wikipedia gives cheap breadth across subjects without repeating a template:
# every article is a different domain of knowledge with a real, specific title.
WIKI_SUBJECTS = [
    "Antikythera_mechanism", "Bioluminescence", "Cuneiform", "Deep_sea_mining",
    "Ecliptic", "Fermentation", "Gothic_architecture", "Hydrothermal_vent",
    "Isotope", "Jacquard_machine", "Kintsugi", "Longitude_prize", "Monsoon",
    "Nixie_tube", "Origami", "Permafrost", "Quipu", "Radiocarbon_dating",
    "Semaphore_line", "Tectonic_uplift", "Ultramarine", "Vulcanization",
    "Watermark", "Xylophone", "Yeast", "Zeppelin", "Aurora", "Basalt",
    "Cartography", "Dendrochronology", "Electroplating", "Fresco",
    "Glassblowing", "Heraldry", "Illuminated_manuscript", "Jetstream",
    "Kiln", "Lithography", "Mycelium", "Nautical_chart", "Obsidian",
    "Papermaking", "Quarrying", "Rigging", "Sundial", "Tannin", "Umami",
    "Viaduct", "Windmill", "Zoetrope",
]

# GitHub repositories: titles are "owner/repo: one-line description", a shape
# that is everywhere and needs the description to name well.
GITHUB_REPOS = [
    "apple/swift-syntax", "rust-lang/cargo", "microsoft/vscode", "torvalds/linux",
    "facebook/react", "vuejs/core", "sveltejs/svelte", "denoland/deno",
    "nodejs/node", "python/cpython", "golang/go", "JetBrains/kotlin",
    "tensorflow/tensorflow", "pytorch/pytorch", "huggingface/transformers",
    "ggerganov/llama.cpp", "obsproject/obs-studio", "signalapp/Signal-Desktop",
    "syncthing/syncthing", "caddyserver/caddy", "traefik/traefik",
    "grafana/grafana", "prometheus/prometheus", "elastic/elasticsearch",
    "redis/redis", "sqlite/sqlite", "duckdb/duckdb", "pola-rs/polars",
    "sharkdp/bat", "BurntSushi/ripgrep", "junegunn/fzf", "tmux/tmux",
    "neovim/neovim", "helix-editor/helix", "zed-industries/zed",
    "alacritty/alacritty", "wez/wezterm", "starship/starship",
]


def build() -> list[tuple[str, str]]:
    """(category, url), so failures can be read per class rather than in bulk."""
    rows: list[tuple[str, str]] = []
    for name, group in CATEGORIES.items():
        rows += [(name, url) for url in group]
    rows += [("wikipedia", f"https://en.wikipedia.org/wiki/{s}") for s in WIKI_SUBJECTS]
    rows += [("github", f"https://github.com/{r}") for r in GITHUB_REPOS]
    # keep order stable and drop any accidental duplicates
    seen: set[str] = set()
    unique = []
    for category, url in rows:
        if url not in seen:
            seen.add(url)
            unique.append((category, url))
    return unique


def main() -> None:
    rows = build()
    destination = os.path.expanduser("~/Downloads/artemis-corpus-urls.txt")
    with open(destination, "w") as handle:
        handle.write("\n".join(f"{c}\t{u}" for c, u in rows) + "\n")
    print(f"{len(rows)} urls → {destination}")
    for name, group in CATEGORIES.items():
        print(f"  {name:14} {len(group)}")
    print(f"  {'wikipedia':14} {len(WIKI_SUBJECTS)}")
    print(f"  {'github':14} {len(GITHUB_REPOS)}")


if __name__ == "__main__":
    main()
