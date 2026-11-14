# Teaching Deck Hub

Open `index.html` in any browser to browse, search and filter your presentations.

## Adding a deck

1. Put the file in `decks/`, inside a sub-folder named after its category
   (e.g. `decks/Toxicology/Paracetamol Overdose.pptx`). Supported: `.pptx .ppt .key .pdf .odp .html`,
   or a folder containing an `index.html` (e.g. a reveal.js deck).
2. Run:

   ```bash
   python3 build_index.py
   ```

   Or leave it running so the hub refreshes by itself whenever `decks/` changes:

   ```bash
   python3 build_index.py --watch
   ```

## Where card details come from

| Field     | Sidecar JSON | PowerPoint (File › Properties) | HTML deck                  | Fallback               |
|-----------|--------------|--------------------------------|----------------------------|------------------------|
| Title     | `title`      | Title                          | `<title>`                  | file name              |
| Category  | `category`   | Category                       | `deck:category` meta       | sub-folder name        |
| Audience  | `audience`   | —                              | `deck:audience` meta       | (blank)                |
| Date      | `date`       | Created                        | `deck:date` meta           | file creation date     |
| Summary   | `summary`    | Comments / Subject             | `description` meta         | (blank)                |
| Tags      | `tags`       | Keywords                       | `deck:tags` meta           | (none)                 |

A sidecar is a `.json` file with the same name as the deck, sitting next to it
(`Paracetamol Overdose.json`). It wins over everything else; any field can be left out:

```json
{
  "audience": "Undergraduate (Year 5)",
  "summary": "Risk assessment with the treatment nomogram and NAC regimens.",
  "tags": ["toxicology", "NAC"]
}
```

The `decks/` folder currently holds six **sample** decks — delete them once you add your own.
