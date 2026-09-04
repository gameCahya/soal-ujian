"use client"

import { useEffect, useRef } from "react"

interface MathHtmlProps extends React.HTMLAttributes<HTMLDivElement> {
  /** HTML soal/pilihan apa adanya (boleh sudah dilewatkan applyHighlights). */
  html: string
  /** Render sebagai <span> alih-alih <div> — untuk pilihan jawaban inline. */
  as?: "div" | "span"
}

/**
 * Merender HTML soal lalu menggambar setiap `span[data-latex]` dengan KaTeX.
 *
 * Cerminan `lms-new/components/editor-ui/MathContent.tsx` — sengaja: kedua
 * aplikasi harus memperlakukan bentuk simpan yang sama dengan cara yang sama.
 * KaTeX dijalankan SESUDAH HTML terpasang, langsung ke DOM, jadi ia tidak
 * bergantung pada apa pun yang lolos/tidak lolos penyaringan di hulu.
 */
export function MathHtml({ html, as = "div", ...rest }: MathHtmlProps) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    const spans = el.querySelectorAll<HTMLSpanElement>("span[data-latex]")
    if (spans.length === 0) return

    let batal = false
    import("katex").then(({ default: katex }) => {
      if (batal) return
      spans.forEach(span => {
        const latex = span.getAttribute("data-latex") ?? ""
        try {
          span.innerHTML = katex.renderToString(latex, {
            throwOnError: false, output: "html", displayMode: false,
          })
        } catch {
          // Rumus yang tak bisa dirender tetap terbaca sebagai sumbernya,
          // bukan menghilang — guru masih bisa memperbaikinya.
          span.textContent = latex
        }
      })
    })
    return () => { batal = true }
  }, [html])

  const Tag = as as React.ElementType
  return <Tag ref={ref} {...rest} dangerouslySetInnerHTML={{ __html: html }} />
}
