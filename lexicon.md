# Shoum — Voice Command Lexicon ("speak markdown")

How spoken words become symbols and formatting. The implementation is
`Shoum/CommandProcessor.swift` (a pure, static function applied to each
transcription chunk before it splices into the box). **The tables in that file
ARE the lexicon — edit them to change behaviour, then `./upgrade.sh`.** This
document explains the model, the defaults, the rough edges, and how to revise.

Toggle the whole feature with **`voice_commands`** (config / Settings checkbox,
default **on**). Off → the raw transcription is inserted unchanged.

---

## The model

Whisper transcribes the *words* you speak; `CommandProcessor` then substitutes.
The initial prompt only *primes* whisper to emit the command words reliably — it
cannot transform output (proven), so all substitution is ours.

Four mechanisms:

1. **`ascii <name>` → symbol.** The universal prefix. `ascii slash` → `/`,
   `ascii open paren` → `(`. The bare word ("slash") stays literal, so there's no
   collision with ordinary speech. Multi-word names work (`ascii open paren`) and
   match longest-first (`ascii plus minus` → `±` beats `ascii plus` → `+`).

2. **Bare words → formatting**, no prefix needed (these are rarely literal):
   `new paragraph` → blank line, `newline` / `new line` → line break.

3. **Modes** (`mode … `):
   - `mode ascii` … `mode normal` — inside the span, symbol names work **without**
     the `ascii` prefix: `mode ascii hash dollar percent mode normal` → `# $ %`.
   - `mode all caps` … `mode normal` — UPPERCASES everything in the span.
   - `mode normal` ends whichever mode(s) are active.

4. **Casing:** `cap <word>` capitalises the next word: `cap apple` → `Apple`.

---

## Default lexicon

> **The live, authoritative list is the in-app Commands tab** (built directly from
> `CommandProcessor`'s tables, so it never drifts). The table below is a snapshot.
> Names in `(parens)` are optional shorthand — `(forward) slash` means "slash" or
> "forward slash" both work; `exclamation (mark)`, `less (than)`, `single (quote)`,
> etc. Recent symbols also include `…` (ellipsis / "dot dot dot") and `--` (double
> dash).

### ASCII symbols (`ascii <name>`, or bare inside `mode ascii`)

| sym | spoken names | sym | spoken names |
|---|---|---|---|
| `(` | open paren, open parenthesis, left paren | `)` | close paren, close parenthesis, right paren |
| `[` | open bracket, left bracket | `]` | close bracket, right bracket |
| `{` | open brace, left brace | `}` | close brace, right brace |
| `<` | less than, open angle | `>` | greater than, close angle |
| `:` | colon | `;` | semicolon |
| `,` | comma | `.` | period, full stop, dot |
| `/` | forward slash, slash | `\` | backslash |
| `\|` | pipe | `±` | plus minus |
| `-` | dash, hyphen, minus | `+` | plus |
| `=` | equals | `_` | underscore |
| `*` | asterisk, star | `^` | caret |
| `~` | tilde | `` ` `` | backtick |
| `@` | at sign, at | `#` | hash, number sign |
| `£` | pound | `$` | dollar |
| `€` | euro | `%` | percent |
| `&` | ampersand | `!` | exclamation mark, exclamation, pling, bang |
| `?` | question mark, question | `'` | single quote, apostrophe |
| `"` | double quote | `§` | section |
| `•` | bullet | | |

### Bare words (no prefix)

| out | spoken names |
|---|---|
| line break (`\n`) | newline, new line |
| blank line (`\n\n`) | new paragraph |

### Control words

`ascii`, `mode ascii`, `mode normal`, `mode all caps`, `cap`.

---

## Spacing model

Symbols join their neighbours per a fixed rule (in `CommandProcessor`, sets
`attachRight` / `attachLeft` / `attachBoth`):

- **No space after:** `(` `[` `{` → `ascii open paren x` = `(x`
- **No space before:** `)` `]` `}` `,` `.` `:` `;` `!` `?` `%` → `word ascii comma` = `word,`
- **No space either side:** `_` → `foo ascii underscore bar` = `foo_bar`
- **Double quotes pair up:** the 1st `"` opens (hugs what follows), the 2nd closes
  (hugs what precedes), and so on → `he said " hi " then` = `he said "hi" then`. An
  odd count just leaves the last one acting as an opener (no crash).
- **Keep spaces (default):** everything else (incl. `/ \ # $ £ € @ & * + - = < > | ~ ^ ' § •`) → `hot ascii slash cold` = `hot / cold`

Also: before an inline symbol, whisper's own trailing `,`/`.`/`;`/`:` on the
previous word is **stripped** (so `over, ascii slash under` = `over / under`, and
`item.` + `ascii full stop` = `item.` not `item..`). Newlines are exempt, so a
period before a line break (list items) survives. Inserted newlines never carry
surrounding spaces.

> This is the **#1 thing you'll want to tune.** e.g. you may want `$`/`@`/`#`
> attached (`$50`, `@user`, `#tag`) — move them between the sets in
> `CommandProcessor`. It's a deliberate, predictable default, not a guess at every
> case; flag the ones that annoy and we adjust.

---

## The primer

`CommandProcessor.primer` is appended to your `prompt.txt` (when `voice_commands`
is on) so whisper reliably emits the control words. It's appended *last* because
whisper truncates the initial prompt to its tail. Measured effect: it flips the
garbled "Modasci" → "mode ascii". The symbol *names* already self-recognise, so
the primer is short and focused on the `mode …` words.

---

## Known limitations / rough edges

- **`cap` collides with ordinary English.** "the salary cap is high" → "the salary
  Is high" (it eats "cap" and capitalises "is"). High-collision; if it bites,
  we'll gate it differently or drop it. (Bare structural words can collide too,
  but `newline`/`new paragraph` are rare in prose.)
- **Letter-spelling is NOT supported.** Whisper reconstructs words from spelled
  letters ("L I K E" → "like", "F O O" → "f00"), and no prompt fixes it. Hand-edit
  non-word identifiers in the box.
- **Symbol spacing is a fixed default** (above), not context-aware.
- **Trailing punctuation on a matched word is dropped** — a trigger token like
  "paren," matches "paren" and the comma is lost. Rare mid-utterance.
- **`smartJoin` runs after this** and may re-case the chunk's first letter, so a
  leading `cap` at the very start of a chunk can be undone.
- These are all expected v1 edges. The intended workflow: use it, **flag** the
  painful cases (the flag captures audio + box-before/after), and we revise the
  tables/spacing/primer.

---

## How to revise

1. Edit the tables in `Shoum/CommandProcessor.swift` (`symbols`, `bareWords`,
   the spacing sets) and/or `primer`.
2. `./upgrade.sh` to rebuild + reinstall.
3. Update this file to match.

A future agent: start here, then read `CommandProcessor.swift`. The processing
order and the spacing model are the two things to hold in your head.

## Possible next steps (not built)

- An **editable lexicon UI** in Settings (a `{char(s) → trigger-words}` table +
  a bare-words field) instead of editing the Swift tables — the originally-imagined
  end state; deferred until the defaults settle from real use.
- Markdown styling spans (`bold on/off`, `italic on/off`, headings).
- Per-symbol spacing config.
