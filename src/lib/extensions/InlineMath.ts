import { Node, mergeAttributes } from '@tiptap/react'
import { latexKeTeks } from '@/lib/latexText'

/**
 * Node rumus inline — cerminan `lms-new/lib/extensions/InlineMath.ts`.
 *
 * KENAPA BENTUKNYA HARUS `data-latex`, BUKAN MARKUP SENDIRI
 * Soal PSAT diimpor ke LMS dan dirender ke siswa lewat `sanitizeSoalHtml`,
 * yang daftar putihnya menentukan apa yang boleh lewat:
 *   - `<math>` & seluruh MathML DILARANG DUA KALI (bukan di ALLOWED_TAGS, dan
 *     ada di FORBID_TAGS). Lebih buruk, KEEP_CONTENT membuatnya tidak hilang
 *     bersih — `<mfrac><mn>1</mn><mn>2</mn></mfrac>` menjadi "12" di layar siswa.
 *   - KaTeX pra-render lolos sebagai <span>, tapi ALLOWED_STYLE membuang
 *     height/vertical-align/top/margin/border-bottom-width — persis properti
 *     yang membentuk garis pecahan dan vinculum akar. Tampil, tapi salah.
 *   - `<span data-latex>` LOLOS UTUH, dan itu dikunci tes di LMS.
 *
 * Pendahulu node ini, `mathFraction`, memancarkan `<span class="math-frac">`
 * yang bergantung pada CSS lokal PSAT. CSS itu TIDAK ADA di LMS, jadi setiap
 * pecahan akan tampil sebagai dua angka berdampingan begitu soalnya diimpor.
 * Belum ketahuan karena belum satu pun soal PSAT diimpor.
 *
 * Guru tidak pernah mengetik LaTeX — ia hanya format simpan. Antarmukanya tetap
 * tombol berisi kotak isian, lihat RichTextEditor.
 */
export const InlineMath = Node.create({
  name: 'inlineMath',
  group: 'inline',
  inline: true,
  atom: true,
  selectable: true,
  draggable: false,

  addAttributes() {
    return {
      latex: {
        default: '',
        parseHTML: (el) => (el as HTMLElement).getAttribute('data-latex') ?? '',
        renderHTML: (attrs) => ({ 'data-latex': attrs.latex }),
      },
    }
  },

  parseHTML() {
    return [{ tag: 'span[data-latex]' }]
  },

  /**
   * Tanpa ini `editor.getText()` mengembalikan string KOSONG untuk rumus —
   * node atom tidak punya teks anak. Semua turunan teks polos (kolom
   * pencarian, ekspor, cuplikan) akan menampilkan soal berlubang.
   */
  renderText({ node }) {
    return latexKeTeks(node.attrs.latex ?? '')
  },

  renderHTML({ node, HTMLAttributes }) {
    return ['span', mergeAttributes({ class: 'math-inline', 'data-latex': node.attrs.latex }, HTMLAttributes)]
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement('span')
      dom.setAttribute('data-latex', node.attrs.latex ?? '')
      dom.setAttribute('contenteditable', 'false')
      dom.className = 'math-inline'

      function render(latex: string) {
        import('katex').then(({ default: katex }) => {
          try {
            dom.innerHTML = katex.renderToString(latex, {
              throwOnError: false, output: 'html', displayMode: false,
            })
          } catch {
            dom.textContent = latex
          }
        })
      }

      render(node.attrs.latex ?? '')

      return {
        dom,
        update(updatedNode) {
          if (updatedNode.type !== node.type) return false
          dom.setAttribute('data-latex', updatedNode.attrs.latex ?? '')
          render(updatedNode.attrs.latex ?? '')
          return true
        },
      }
    }
  },
})
