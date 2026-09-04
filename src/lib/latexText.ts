// Cerminan `lms-new/lib/utils/latexText.ts`. Dua repo terpisah, jadi tidak bisa
// berbagi modul — perilakunya dijaga sama dan dikunci tes di sisi LMS.
/**
 * LaTeX → teks yang masih terbaca manusia.
 *
 * Dipakai untuk PDF naskah, JSON, dan Google Form — ketiganya jalur TEKS POLOS
 * (@react-pdf/renderer tidak mengerti HTML sama sekali). Tanpa penerjemah ini
 * node rumus tidak punya teks anak, jadi ia luruh jadi string kosong dan soal
 * tercetak berlubang: "Berapa nilai dari ?".
 *
 * Sengaja sederhana dan tidak berusaha jadi parser LaTeX lengkap — cukup untuk
 * bentuk yang bisa dihasilkan tombol editor, dan apa pun yang tak dikenali
 * dikembalikan apa adanya supaya guru masih bisa membacanya.
 */
export function latexKeTeks(latex: string): string {
  // Ambil satu kelompok {...} yang seimbang mulai dari posisi i (di '{').
  const ambilKurung = (src: string, i: number): [string, number] | null => {
    if (src[i] !== '{') return null
    let dalam = 0
    for (let j = i; j < src.length; j++) {
      if (src[j] === '{') dalam++
      else if (src[j] === '}') {
        dalam--
        if (dalam === 0) return [src.slice(i + 1, j), j + 1]
      }
    }
    return null
  }

  let out = ''
  let i = 0
  while (i < latex.length) {
    if (latex.startsWith('\\frac', i)) {
      const a = ambilKurung(latex, i + 5)
      const b = a ? ambilKurung(latex, a[1]) : null
      if (a && b) { out += `(${latexKeTeks(a[0])})/(${latexKeTeks(b[0])})`; i = b[1]; continue }
    }
    if (latex.startsWith('\\sqrt', i)) {
      let j = i + 5
      let pangkat = ''
      if (latex[j] === '[') {
        const tutup = latex.indexOf(']', j)
        if (tutup > -1) { pangkat = latex.slice(j + 1, tutup); j = tutup + 1 }
      }
      const isi = ambilKurung(latex, j)
      if (isi) {
        out += pangkat ? `akar-${pangkat}(${latexKeTeks(isi[0])})` : `\u221a(${latexKeTeks(isi[0])})`
        i = isi[1]
        continue
      }
    }
    if (latex.startsWith('\\square', i)) { out += '__'; i += 7; continue }
    if (latex.startsWith('\\times', i))  { out += '\u00d7'; i += 6; continue }
    if (latex.startsWith('\\div', i))    { out += '\u00f7'; i += 4; continue }
    if (latex.startsWith('\\pi', i))     { out += '\u03c0'; i += 3; continue }
    if (latex.startsWith('\\cdot', i))   { out += '\u22c5'; i += 5; continue }
    out += latex[i]
    i++
  }
  return out
}
