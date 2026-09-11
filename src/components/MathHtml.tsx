"use client"

import { useEffect, useState } from "react"

interface MathHtmlProps extends React.HTMLAttributes<HTMLDivElement> {
  /** HTML soal/pilihan apa adanya (boleh sudah dilewatkan applyHighlights). */
  html: string
  /** Render sebagai <span> alih-alih <div> — untuk pilihan jawaban inline. */
  as?: "div" | "span"
}

// Entity HTML dasar yang mungkin muncul di NILAI atribut data-latex (mis. &amp;).
function decodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;/g, "'")
    .replace(/&amp;/g, "&")
}

// Soal disimpan sbg span KOSONG: <span class="math-inline" data-latex="\frac{1}{2}"></span>
// Node math bersifat atom (tak ada anak), jadi non-greedy [\s\S]*? aman.
const MATH_SPAN = /<span\b[^>]*\bdata-latex="([^"]*)"[^>]*>[\s\S]*?<\/span>/gi

/**
 * Merender HTML soal + rumus inline KaTeX.
 *
 * KENAPA "membakar" hasil KaTeX ke dalam string (bukan mengisi DOM setelah mount):
 * Versi lama menangkap daftar `span[data-latex]` LALU mengisinya di dalam
 * `import("katex").then(...)` yang ASINKRON. Bila komponen re-render di sela itu
 * (daftar validator sering: popover highlight, filter, muat bertahap), DOM
 * di-reset dan node yang ditangkap jadi BASI — KaTeX mengisi elemen yang sudah
 * terlepas, sehingga rumus TAK MUNCUL ("kadang hilang"). Dengan membakar hasil
 * KaTeX ke string yang dikendalikan React, tak ada lagi balapan timing.
 *
 * Cerminan `lms-new/components/editor-ui/MathContent.tsx` — kedua aplikasi harus
 * memperlakukan bentuk simpan yang sama dengan cara yang sama.
 */
export function MathHtml({ html, as = "div", ...rest }: MathHtmlProps) {
  // Tampilkan html apa adanya dulu; setelah KaTeX termuat, ganti dgn versi terbakar.
  const [out, setOut] = useState(html)

  useEffect(() => {
    // Tanpa rumus: tak perlu KaTeX sama sekali.
    if (!/data-latex=/.test(html)) { setOut(html); return }

    let batal = false
    setOut(html) // sementara (rumus kosong) sampai KaTeX termuat
    import("katex").then(({ default: katex }) => {
      if (batal) return
      const terbakar = html.replace(MATH_SPAN, (_utuh, latexRaw: string) => {
        const latex = decodeEntities(latexRaw)
        try {
          const inner = katex.renderToString(latex, {
            throwOnError: false, output: "html", displayMode: false,
          })
          return `<span class="math-inline">${inner}</span>`
        } catch {
          // Rumus tak terender tetap terbaca sbg sumbernya, bukan menghilang.
          return `<span class="math-inline">${latex}</span>`
        }
      })
      setOut(terbakar)
    })
    return () => { batal = true }
  }, [html])

  const Tag = as as React.ElementType
  return <Tag {...rest} dangerouslySetInnerHTML={{ __html: out }} />
}
