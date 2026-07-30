// Top-level function — called from the Lua filter for ::: {.borderless-table} divs.
// Must be at top level so Pandoc's #import "article.typ": * can pick it up.
#let borderless-table(body) = {
  show table: set table(stroke: none)
  // set (not show) is what actually suppresses the explicit table.hline() element
  set table.hline(stroke: none)
  // GFM tables always require a header row; for image side-by-side tables the
  // header is empty (| | |) and would just add blank space — hide it entirely.
  show table.header: _ => none
  body
}

#let conf(
  lang: "en",
  region: "DE",
  paper: "a4",
  margin: (top: 3cm, bottom: 3cm, inside: 2cm, outside: 2cm),
  cols: 1,
  font: ("Roboto Serif"),
  fontsize: 10pt,
  sectionnumbering: none,
  pagenumbering: "1",
  abstract-title: [Abstract],
  doc,
) = {
  set page(
    paper: paper,
    margin: margin,
    columns: cols,
    numbering: pagenumbering,
    header-ascent: 40% + 0pt,
    header: context {
      set text(10pt)
      if (here().page()) > 1 {  // skip first page
        if calc.odd(here().page()) {  // different headers on L/R pages
          align(right,smallcaps(all: true)[michaelrommel.com] )
        } else {
          align(left,smallcaps(all: true)[Michael Rommel] )
        }
      }
    },
  )
  set text(lang: lang,
    region: region,
    font: font,
    size: fontsize,
    alternates: false,
    discretionary-ligatures: false,
    historical-ligatures: true,
    number-type: "old-style",
    number-width: "proportional")
  set strong(delta: 200)
  set par(
    spacing: 16pt,  
    leading: 10pt, 
  )
  show raw: set block(inset: (left: 1em, top: 1em, right: 1em, bottom: 1em ))
  show raw: set text(size: 8pt, font: "VictorMono NF")

  show heading: set text(hyphenate: false)
  show heading.where(level: 1): it => align(left, block(above: 24pt, below: 16pt, width: 100% )[
        //#v(12pt) // space above 
        //#set par(leading: 16pt)
        //#set text(font: font, weight: "regular", style: "normal", size: 16pt)
        #block(it.body) 
        //#v(6pt) // space below 
      ])

  show heading.where(level: 2): it => align(left, block(above: 28pt, below: 16pt, width: 80%)[
        #block(it.body) 
      ])

  show heading.where(level: 3): it => align(left, block(above: 20pt, below: 16pt)[
        #block(it.body) 
      ])

  show quote.where(block: true): it => {
    block(
      stroke: (left: 4pt + rgb("#888888")),
      inset: (left: 1em, y: 0.5em),
      width: 100%,
      {
        // This resets the stroke and inset for any quote blocks 
        // nested *inside* this parent block container.
        set quote(block: true)
        show quote.where(block: true): set block(stroke: none, inset: 0pt)
        it.body
      }
    )
  }

  show regex("https?://\S+"): set text(style: "normal", rgb("#33d"))
  show link: set text(style: "normal", rgb("#111177"))
  show link: underline

  doc  // HERE is the actual body content
}
