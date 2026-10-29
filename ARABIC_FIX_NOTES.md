# Arabic text fix notes

## Changes

- Expanded the Arabic-script joining table in `runtime/src/rtl_text.cpp` to cover additional Arabic Presentation Forms-A letters commonly used by Persian, Urdu, and regional Arabic-script translations (including peh, tteh, tcheh, keheh, gaf, heh variants, and yeh-barree).
- Added regression assertions for the new joining/form mappings and a joined peh sequence in `runtime/tools/rtl_text_test.cpp`.

## Validation

The standalone RTL/shaping regression test was compiled with GCC (`-std=c++17 -Wall -Wextra -Werror -UNDEBUG`) and passed.

## Important limitation

This validates the RTL shaping logic in isolation. It does not constitute an Xbox UWP build or in-game validation. The runtime can only render a contextual presentation form if the game's active message font contains that glyph; missing glyphs still fall back to the base character. If ordinary Arabic letters (such as ب، ت، س، ل، م) remain disconnected in-game, capture the runtime log with `WWHD_RTL_TRACE=1` and the language-pack font report so the active font and hook path can be diagnosed next.
