# Third-party notices

Corral's own software is GPL-3.0-only. Dependencies and provider assets retain their respective terms.

| Component | Purpose | Upstream terms |
| --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal rendering | MIT; preserve its license when redistributing |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Official direct-download Mac updates | MIT; public self-builds do not use the maintainer update feed |
| [Mermaid](https://github.com/mermaid-js/mermaid) 12.0.0 | Local Mermaid diagram rendering | MIT; license in `Shared/Resources/ChatDiagrams/licenses/mermaid.txt` |
| [PlantUML](https://github.com/plantuml/plantuml) 1.2026.8 | Local PlantUML diagram rendering | GPL-3.0; license in `Shared/Resources/ChatDiagrams/licenses/plantuml.txt` |
| [DOMPurify](https://github.com/cure53/DOMPurify) 3.4.16 | Sanitize engine SVG before native conversion | Apache-2.0 or MPL-2.0; license in `Shared/Resources/ChatDiagrams/licenses/dompurify.txt` |
| [C4-PlantUML](https://github.com/plantuml-stdlib/C4-PlantUML) 2.13.0 | Bundled C4 diagram styles | MIT; license in `Shared/Resources/ChatDiagrams/licenses/c4.txt` |
| [Viz.js](https://github.com/mdaines/viz-js) / [Graphviz](https://gitlab.com/graphviz/graphviz) | PlantUML layout runtime | MIT / EPL-1.0; licenses in `licenses/viz.txt` and `licenses/graphviz.txt` |
| [Expat](https://github.com/libexpat/libexpat) | XML parser used by the local diagram runtime | MIT; license in `Shared/Resources/ChatDiagrams/licenses/expat.txt` |
| Apple frameworks | Native UI, cryptography, Keychain and platform services | Apple SDK and platform terms |
| Assistant-provider marks | Identify supported assistant runtimes | Provider ownership and brand terms; sources listed in `design/runtime-logos/SOURCES.md` |

Pinned dependency versions are in `project.yml`. The Corral name and floral-hat artwork are covered by BRAND_POLICY.md separately from the software license.

## Claude monochrome mark

The selected Mac filter uses the official one-color Claude symbol supplied in the [Anthropic press kit](https://www.anthropic.com/press-kit). Only the symbol is cropped from the full wordmark; its path is unchanged. Claude and its marks belong to Anthropic.
