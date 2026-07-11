# Noto Sans CJK SC

`NotoSansCJKsc-VF.ttf` is the complete Simplified Chinese language-specific
variable TrueType font from the official Noto CJK Sans 2.004 release.

- Upstream: https://github.com/notofonts/noto-cjk
- Release tag: `Sans2.004`
- Source file: `Sans/Variable/TTF/NotoSansCJKsc-VF.ttf`
- Download URL: https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004/Sans/Variable/TTF/NotoSansCJKsc-VF.ttf
- SHA-256: `990C807E79C25662A5A9ECF7F971BAEB2BF2EAB9A559E5ECF15CDFDB8561D21F`
- License: SIL Open Font License 1.1; see `OFL.txt` in this directory.

The project exposes the variable `wght` axis through Regular (400), Medium
(500), Semibold (600), and Bold (700) `FontVariation` resources. Compact UI
body text and HUD labels use Semibold, controls and headings use Bold, while
long-form rich text remains Medium. The TTF build is used instead of the CFF2
OTF build for reliable rendering on Windows. Godot stores the axis with the
integer OpenType tag `0x77676874` (`2003265652`); using a string `"wght"` key
does not select the axis and falls back to this font's Thin 100 default.
