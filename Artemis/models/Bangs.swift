// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Fin. Additional terms under GPL section 7 apply: see LICENSE-ADDITIONAL-TERMS.

import Foundation

/// a `!shortcut` that sends the rest of the query straight to one site,
/// DuckDuckGo-style, without a round trip through a results page
struct Bang: Identifiable, Hashable, Codable {
    let trigger: String
    let name: String
    /// destination with `{q}` where the query goes
    let template: String

    var id: String { trigger }

    /// the site's own root, used when the bang is typed with nothing after it
    private var homeURL: URL? {
        guard let url = URL(string: template.replacingOccurrences(of: "{q}", with: "")),
            let scheme = url.scheme, let host = url.host()
        else { return nil }
        return URL(string: "\(scheme)://\(host)/")
    }

    func url(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return homeURL ?? URL(string: template) }
        let escaped =
            trimmed.addingPercentEncoding(withAllowedCharacters: Bangs.queryAllowed) ?? trimmed
        return URL(string: template.replacingOccurrences(of: "{q}", with: escaped))
    }
}

enum Bangs {
    static let enabledKey = "bangsEnabled"
    private static let customKey = "customBangsV1"

    /// everything but the characters that would end the query parameter
    static let queryAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// custom first, so a custom `!gh` beats the built-in one
    private static var all: [Bang] { custom + builtin }

    static var custom: [Bang] {
        guard let data = UserDefaults.standard.data(forKey: customKey),
            let decoded = try? JSONDecoder().decode([Bang].self, from: data)
        else { return [] }
        return decoded
    }

    static func setCustom(_ bangs: [Bang]) {
        guard let data = try? JSONEncoder().encode(bangs) else { return }
        UserDefaults.standard.set(data, forKey: customKey)
    }

    static func lookup(_ trigger: String) -> Bang? {
        let key = trigger.lowercased()
        return all.first { $0.trigger == key }
    }

    /// bangs whose trigger or name starts with `prefix`, triggers first
    static func matching(_ prefix: String, limit: Int = 8) -> [Bang] {
        let key = prefix.lowercased()
        guard !key.isEmpty else { return Array(all.prefix(limit)) }
        let byTrigger = all.filter { $0.trigger.hasPrefix(key) }
        let byName = all.filter {
            !$0.trigger.hasPrefix(key) && $0.name.lowercased().contains(key)
        }
        return Array((byTrigger + byName).prefix(limit))
    }

    /// the bang ⇥ arms for a lone word naming it: its trigger (two letters or more,
    /// so ⇥ after "g" still walks the list) or its name without spaces
    static func tabTarget(_ input: String) -> Bang? {
        let word = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard isEnabled, !word.isEmpty, !word.contains(" "), !word.hasPrefix("!") else { return nil }
        return all.first {
            ($0.trigger == word && word.count >= 2)
                || $0.name.lowercased().replacingOccurrences(of: " ", with: "") == word
        }
    }

    /// the bang token and what's left of the query. the token may sit at either
    /// end, the way DuckDuckGo accepts it
    static func split(_ input: String) -> (trigger: String, query: String)? {
        let words = input.split(separator: " ", omittingEmptySubsequences: true)
        guard let index = words.firstIndex(where: { $0.hasPrefix("!") && $0.count > 1 })
        else { return nil }
        var rest = words
        let token = rest.remove(at: index)
        return (String(token.dropFirst()).lowercased(), rest.joined(separator: " "))
    }

    /// the trigger being typed, when the input is nothing but a bare `!token`
    static func partial(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!"), !trimmed.dropFirst().contains(" ") else { return nil }
        return String(trimmed.dropFirst()).lowercased()
    }

    /// DuckDuckGo, which resolves every bang server-side, for a trigger not carried here
    static func fallbackURL(trigger: String, query: String) -> URL? {
        let phrase = "!\(trigger) \(query)".trimmingCharacters(in: .whitespaces)
        guard let escaped = phrase.addingPercentEncoding(withAllowedCharacters: queryAllowed)
        else { return nil }
        return URL(string: "https://duckduckgo.com/?q=\(escaped)")
    }

    // MARK: - Table

    static let builtin: [Bang] = table
        .split(separator: "\n")
        .compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return Bang(
                trigger: String(parts[0]), name: String(parts[1]), template: String(parts[2]))
        }

    private static let table = """
        g|Google|https://www.google.com/search?q={q}
        ddg|DuckDuckGo|https://duckduckgo.com/?q={q}
        b|Bing|https://www.bing.com/search?q={q}
        brave|Brave Search|https://search.brave.com/search?q={q}
        kagi|Kagi|https://kagi.com/search?q={q}
        ecosia|Ecosia|https://www.ecosia.org/search?q={q}
        sp|Startpage|https://www.startpage.com/sp/search?q={q}
        qw|Qwant|https://www.qwant.com/?q={q}
        w|Wikipedia|https://en.wikipedia.org/w/index.php?search={q}
        wiki|Wikipedia|https://en.wikipedia.org/w/index.php?search={q}
        yt|YouTube|https://www.youtube.com/results?search_query={q}
        gh|GitHub|https://github.com/search?q={q}
        ghr|GitHub Repositories|https://github.com/search?type=repositories&q={q}
        gist|GitHub Gists|https://gist.github.com/search?q={q}
        gl|GitLab|https://gitlab.com/search?search={q}
        so|Stack Overflow|https://stackoverflow.com/search?q={q}
        se|Stack Exchange|https://stackexchange.com/search?q={q}
        su|Super User|https://superuser.com/search?q={q}
        au|Ask Ubuntu|https://askubuntu.com/search?q={q}
        r|Reddit|https://www.reddit.com/search/?q={q}
        hn|Hacker News|https://hn.algolia.com/?q={q}
        lob|Lobsters|https://lobste.rs/search?q={q}
        ph|Product Hunt|https://www.producthunt.com/search?q={q}
        a|Amazon|https://www.amazon.com/s?k={q}
        auk|Amazon UK|https://www.amazon.co.uk/s?k={q}
        ebay|eBay|https://www.ebay.com/sch/i.html?_nkw={q}
        etsy|Etsy|https://www.etsy.com/search?q={q}
        ali|AliExpress|https://www.aliexpress.com/wholesale?SearchText={q}
        argos|Argos|https://www.argos.co.uk/search/{q}
        ikea|IKEA|https://www.ikea.com/gb/en/search/?q={q}
        maps|Google Maps|https://www.google.com/maps/search/{q}
        osm|OpenStreetMap|https://www.openstreetmap.org/search?query={q}
        gm|Gmail|https://mail.google.com/mail/u/0/#search/{q}
        gcal|Google Calendar|https://calendar.google.com/calendar/r/search?q={q}
        gd|Google Drive|https://drive.google.com/drive/search?q={q}
        gi|Google Images|https://www.google.com/search?tbm=isch&q={q}
        gn|Google News|https://news.google.com/search?q={q}
        gs|Google Scholar|https://scholar.google.com/scholar?q={q}
        tr|Google Translate|https://translate.google.com/?text={q}
        imdb|IMDb|https://www.imdb.com/find?q={q}
        rt|Rotten Tomatoes|https://www.rottentomatoes.com/search?search={q}
        mc|Metacritic|https://www.metacritic.com/search/{q}/
        lb|Letterboxd|https://letterboxd.com/search/{q}/
        mal|MyAnimeList|https://myanimelist.net/search/all?q={q}
        netflix|Netflix|https://www.netflix.com/search?q={q}
        steam|Steam|https://store.steampowered.com/search/?term={q}
        pdb|ProtonDB|https://www.protondb.com/search?q={q}
        itch|itch.io|https://itch.io/search?q={q}
        tw|Twitch|https://www.twitch.tv/search?term={q}
        vimeo|Vimeo|https://vimeo.com/search?q={q}
        sc|SoundCloud|https://soundcloud.com/search?q={q}
        bc|Bandcamp|https://bandcamp.com/search?q={q}
        spotify|Spotify|https://open.spotify.com/search/{q}
        genius|Genius|https://genius.com/search?q={q}
        discogs|Discogs|https://www.discogs.com/search/?q={q}
        x|X|https://x.com/search?q={q}
        tt|TikTok|https://www.tiktok.com/search?q={q}
        ig|Instagram|https://www.instagram.com/explore/tags/{q}/
        fb|Facebook|https://www.facebook.com/search/top?q={q}
        li|LinkedIn|https://www.linkedin.com/search/results/all/?keywords={q}
        mdn|MDN|https://developer.mozilla.org/en-US/search?q={q}
        caniuse|Can I Use|https://caniuse.com/?search={q}
        w3c|W3C|https://www.w3.org/search/?q={q}
        npm|npm|https://www.npmjs.com/search?q={q}
        pypi|PyPI|https://pypi.org/search/?q={q}
        py|Python Docs|https://docs.python.org/3/search.html?q={q}
        crates|crates.io|https://crates.io/search?q={q}
        docsrs|docs.rs|https://docs.rs/releases/search?query={q}
        rust|Rust Docs|https://doc.rust-lang.org/std/index.html?search={q}
        go|Go Packages|https://pkg.go.dev/search?q={q}
        spi|Swift Package Index|https://swiftpackageindex.com/search?query={q}
        apple|Apple Developer|https://developer.apple.com/search/?q={q}
        cpp|cppreference|https://en.cppreference.com/mwiki/index.php?search={q}
        mvn|Maven Central|https://central.sonatype.com/search?q={q}
        nuget|NuGet|https://www.nuget.org/packages?q={q}
        gem|RubyGems|https://rubygems.org/search?query={q}
        brew|Homebrew|https://formulae.brew.sh/formula/{q}
        dh|Docker Hub|https://hub.docker.com/search?q={q}
        k8s|Kubernetes Docs|https://kubernetes.io/search/?q={q}
        aws|AWS Docs|https://docs.aws.amazon.com/search/doc-search.html?searchPath=documentation&searchQuery={q}
        gcp|Google Cloud Docs|https://cloud.google.com/s/results?q={q}
        azure|Azure Docs|https://learn.microsoft.com/en-us/search/?terms={q}
        cf|Cloudflare Docs|https://developers.cloudflare.com/search/?q={q}
        vercel|Vercel Docs|https://vercel.com/docs?q={q}
        react|React Docs|https://react.dev/search?q={q}
        vue|Vue Docs|https://vuejs.org/?search={q}
        svelte|Svelte Docs|https://svelte.dev/docs?q={q}
        next|Next.js Docs|https://nextjs.org/docs?q={q}
        tw3|Tailwind CSS|https://tailwindcss.com/docs/{q}
        arch|Arch Wiki|https://wiki.archlinux.org/index.php?search={q}
        aur|AUR|https://aur.archlinux.org/packages?K={q}
        deb|Debian Packages|https://packages.debian.org/search?keywords={q}
        ubuntu|Ubuntu Packages|https://packages.ubuntu.com/search?keywords={q}
        nix|Nix Packages|https://search.nixos.org/packages?query={q}
        man|Man Pages|https://man7.org/linux/man-pages/dir_all_alphabetic.html#{q}
        tldr|tldr pages|https://tldr.inbrowser.app/search?q={q}
        regex|regex101|https://regex101.com/?regex={q}
        cve|CVE|https://cve.mitre.org/cgi-bin/cvekey.cgi?keyword={q}
        vt|VirusTotal|https://www.virustotal.com/gui/search/{q}
        urlscan|urlscan.io|https://urlscan.io/search/#{q}
        whois|WHOIS|https://who.is/whois/{q}
        wa|Wolfram Alpha|https://www.wolframalpha.com/input?i={q}
        desmos|Desmos|https://www.desmos.com/calculator?q={q}
        arxiv|arXiv|https://arxiv.org/abs/{q}
        pubmed|PubMed|https://pubmed.ncbi.nlm.nih.gov/?term={q}
        doi|DOI|https://doi.org/{q}
        nature|Nature|https://www.nature.com/search?q={q}
        ted|TED|https://www.ted.com/search?q={q}
        coursera|Coursera|https://www.coursera.org/search?query={q}
        khan|Khan Academy|https://www.khanacademy.org/search?page_search_query={q}
        figma|Figma Community|https://www.figma.com/community/search?resource_type=mixed&q={q}
        dribbble|Dribbble|https://dribbble.com/search/{q}
        behance|Behance|https://www.behance.net/search/projects?search={q}
        unsplash|Unsplash|https://unsplash.com/s/photos/{q}
        pexels|Pexels|https://www.pexels.com/search/{q}/
        fa|Font Awesome|https://fontawesome.com/search?q={q}
        gfonts|Google Fonts|https://fonts.google.com/?query={q}
        emoji|Emojipedia|https://emojipedia.org/search?q={q}
        bbc|BBC News|https://www.bbc.co.uk/search?q={q}
        guardian|The Guardian|https://www.theguardian.com/uk/search?q={q}
        reuters|Reuters|https://www.reuters.com/site-search/?query={q}
        nyt|New York Times|https://www.nytimes.com/search?query={q}
        ars|Ars Technica|https://arstechnica.com/search/?query={q}
        verge|The Verge|https://www.theverge.com/search?q={q}
        tc|TechCrunch|https://techcrunch.com/?s={q}
        wired|WIRED|https://www.wired.com/search/?q={q}
        yelp|Yelp|https://www.yelp.com/search?find_desc={q}
        ta|Tripadvisor|https://www.tripadvisor.com/Search?q={q}
        booking|Booking.com|https://www.booking.com/searchresults.html?ss={q}
        airbnb|Airbnb|https://www.airbnb.com/s/{q}/homes
        indeed|Indeed|https://www.indeed.com/jobs?q={q}
        gd2|Glassdoor|https://www.glassdoor.com/Search/results.htm?keyword={q}
        cb|Crunchbase|https://www.crunchbase.com/textsearch?q={q}
        notion|Notion|https://www.notion.so/search?q={q}
        chatgpt|ChatGPT|https://chatgpt.com/?q={q}
        claude|Claude|https://claude.ai/new?q={q}
        gemini|Gemini|https://gemini.google.com/app?q={q}
        perp|Perplexity|https://www.perplexity.ai/search?q={q}
        hf|Hugging Face|https://huggingface.co/search/full-text?q={q}
        kaggle|Kaggle|https://www.kaggle.com/search?q={q}
        wb|Wayback Machine|https://web.archive.org/web/*/{q}
        """
}
