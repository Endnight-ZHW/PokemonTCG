# Front-end icon set

These icons are original project assets drawn for this UI refactor. Every icon
uses an approximately 2 px rounded stroke and no embedded branding. General
24 × 24 icons use white artwork tinted by the Theme. Switches use a stable
40 × 24 track; switches, checkboxes, slider handles and `option_chevron.svg`
carry the cream palette directly because these native control decorations do
not all inherit Button icon tinting. Their visible strokes meet 3:1 contrast
on the cream surface. Keep their colors aligned with `DesignTokens` and run
the frontend theme accessibility contract after changes.

Keep icons paired with a visible text label in user-facing controls. Icons may
stand alone only for universally understood secondary actions when an explicit
tooltip and accessible description are also provided.
