# `scripts/`

Scripts utilitaires hors-Airflow (rapports d'intégrité, opérations
ponctuelles, export de docs).

## Export d'une doc markdown en PDF — `export-doc-pdf.sh`

Convertit un fichier markdown du repo en PDF stylé, en passant par
`pandoc → chromium headless`. Les blocs ` ```mermaid ` sont rendus en SVG via
`mermaid-cli` et inlinés dans le PDF (vectoriel, pas pixellisé).

### Usage

```bash
# Sortie par défaut : <doc>.pdf à côté du source
./scripts/export-doc-pdf.sh docs/flux-globaux.md

# Sortie personnalisée
./scripts/export-doc-pdf.sh docs/flux-globaux.md /tmp/flux.pdf
```

Le script marche pour **n'importe quel `.md`** du repo (pas juste
`flux-globaux.md`).

### Pré-requis

| Outil | Comment vérifier | Install si absent |
|---|---|---|
| `pandoc` (≥ 3.x) | `pandoc --version` | `apt install pandoc` |
| `google-chrome` ou `chromium` | `which google-chrome` | `apt install chromium-browser` |
| Node.js + `npx` | `npx --version` | `apt install nodejs npm` |
| `python3` | `python3 --version` | déjà fourni avec le système |

`mermaid-cli` est téléchargé à la volée via `npx -y` (premier appel ~30 s,
ensuite caché dans `~/.npm`). Pas d'install globale nécessaire.

### Limitations connues

- **Diagrammes** : seuls les blocs ` ```mermaid ` sont rendus. Les diagrammes
  ASCII (`┌─┐│`) passent en bloc de code monospace — préférer Mermaid pour
  un rendu propre.
- **Tableaux très larges** : le CSS (`scripts/export-doc.css`) force
  `word-wrap` sur les cellules. Au-delà de ~8 colonnes ça reste compact mais
  lisible ; pour les très grosses matrices, envisager un `landscape` (à
  ajouter au CSS via `@page { size: A4 landscape; }`).
- **Headers/footers PDF** : désactivés (`--no-pdf-header-footer`). Si la
  numérotation de page est nécessaire, retirer ce flag ou implémenter un
  template HTML avec compteur CSS `@page`.

### Fichiers associés

- `scripts/export-doc-pdf.sh` — pipeline bash
- `scripts/export-doc.css` — feuille de style print A4
