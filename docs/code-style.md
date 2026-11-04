# Code style

This guide is for anyone writing code for Artemis. Each rule tells you what to do; the reasons are left out.

## Comments

- A comment states something the code cannot show. That can be an invariant, a unit or coordinate space, an ordering requirement, a WebKit trap, an SPI precondition, or a one-sentence summary of a public API.
- A comment is at most three lines.
- Don't write history: no "used to", "the old version", dates, or stories about how a bug was found. That belongs in the commit message.
- Don't justify: no alternatives you rejected, no benchmarks, no "we chose X because Y beat Z". The commit message holds the evidence.
- Don't narrate: no comment that repeats the line below it, the type, or the name.
- If a passage needs a paragraph to defend it, simplify the passage instead.
- Delete stale comments rather than rewording them.
- Doc comments (`///`) start lowercase, as everywhere else in the codebase.

## Shape

- Solve the problem in front of you. Don't add an abstraction with one caller, a wrapper that only forwards, or a branch kept "in case".
- Use the tightest access level that compiles. A helper used in one file is `private`.
- Delete dead code. Git keeps it.
- Write `!`, `as!` or `try!` only on a value that cannot be nil or fail by construction, such as a literal URL or a regex.
- Never discard an error silently on a path the user would notice. `try?` is for genuinely optional work.
- Log with `DebugLog` or `Logger`, never `print`.

## Naming

Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines): clarity at the point of use, then brevity. A name says what something is or does. It doesn't describe how it is implemented, or what it replaced.

## Consistency

Match the surrounding file. Style-only changes go in their own commit, separate from behaviour changes.

## Generated and exact-text files

Don't edit these by hand:

- `Emojis.swift` and `SFSymbols.swift` are generated.
- `compat.js` is matched by exact text from `ExtensionCompat.swift`.
