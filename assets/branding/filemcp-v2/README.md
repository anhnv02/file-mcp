# FileMCP identity / minimal

The compact B symbol has a 144 × 152 unit silhouette (about 21% shorter than the initial B). Its fold and monogram are positioned independently, with no nonuniform stretching.

The selected B direction combines a folded local document with a custom folded M monogram. The M uses custom polygon geometry with beveled shoulders, softly rounded corners and a deep central fold; it is not a font glyph. Primary artwork uses #DB0F30 with lighter/darker red shading and one rear sheet rotated by −10°. The macOS/Windows icon puts the crimson document on a white rounded surface. Black/white alternatives remain available. The filled monogram uses the same geometry at every size.

The shared editable source is `../render_filemcp_icon.swift`; no generated raster image is required to rebuild this identity.

## Files

- `wordmark-light.svg` / `.png`: primary horizontal logo for light surfaces.
- `wordmark-dark.svg` / `.png`: document symbol with white wordmark for dark surfaces.
- `wordmark-mono.svg` / `.png`: document symbol with black wordmark.
- `wordmark-white.svg` / `.png`: document symbol with white wordmark.
- `mark-*.svg` / `.png`: standalone transparent symbols in the same four treatments.
- `app-icon.svg`: editable vector artwork.
- `app-icon-{16,24,32,48,64,128,256,512,1024}.png`: transparent icon exports, including macOS canvas inset.
- `FileMCP.icns`: macOS application icon.
- `FileMCP.ico`: Windows application icon with seven PNG-compressed sizes, 16–256 px.
- `favicon.svg`: compact icon for web contexts, without the macOS canvas inset.
- `brand-board.png`: overview of the system and actual-size icon previews.
- `readme-hero.png`: repository README banner (1600 × 620 px), showing the current FileMCP app icon and an illustrative workspace connection panel.

All PNG logo exports have a transparent background. The app-icon PNGs retain transparency around the rounded icon surface. The white variants are intended for dark backgrounds.

## Palette

| Role | sRGB |
| --- | --- |
| Primary crimson | `#DB0F30` |
| Highlight | `#F45C75` |
| Shade | `#A90925` |
| Monochrome black | `#000000` |
| White | `#FFFFFF` |
| Gray (supporting layouts) | `#808080` |
| Paper (supporting layouts) | `#F5F5F5` |

## Usage

Preserve the document silhouette, fold and folded M monogram. Black and white marks are designed for light and dark surfaces respectively. Keep the supplied app-icon padding.

SVG assets are true vectors with transparent cutouts. Wordmark text remains editable and uses a system sans-serif font stack; no font files are distributed. PNG, ICNS and ICO exports render the same geometry. The macOS OAuth login page uses the same rounded-square application icon on light and dark surfaces.

## Rebuild

From the repository root on macOS:

```sh
bash build_brand_assets.sh
```

The script exports the kit, rebuilds the macOS icon, updates the Windows icon and legacy wordmark alias (`assets/branding/filemcp-logo.svg`), and packages `dist/FileMCP-brand-kit-v2.zip`. The root README displays `readme-hero.png`, a separately generated documentation asset that contains the current app icon. The normal macOS app build automatically renders the current app icon from `assets/branding/render_filemcp_icon.swift`.

To regenerate the README banner after changing the app icon, install Pillow in your development Python environment and run:

```sh
python3 assets/branding/render_readme_hero.py
```

The banner is a conceptual illustration, not a screenshot of the running application.

The M is 10% smaller than the initial monogram, with 1.8-unit corner rounding. The single rear layer uses #F6A9B8 with a subtle white edge. The front top edge is lowered by 12 units and the M raised by 6 units to reduce unused space above the monogram.
