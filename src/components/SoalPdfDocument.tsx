import { Document, Page, Text, View, Image, StyleSheet } from '@react-pdf/renderer'
import type { SoalProcessed, PdfMeta } from '@/lib/downloadSoal'

interface Props {
  soalList: SoalProcessed[]
  meta: PdfMeta
}

const TIPE_LABEL: Record<string, string> = {
  pilgan: 'Pilgan',
  ceklist: 'Ceklist',
  essay: 'Essay',
  isian_singkat: 'Isian Singkat',
}

const KESULITAN_LABEL: Record<string, string> = {
  mudah: 'LOTS',
  sedang: 'MOTS',
  sulit: 'HOTS',
}

const LABELS = ['A', 'B', 'C', 'D', 'E']

const BADGE_BASE = { fontSize: 8, paddingHorizontal: 5, paddingVertical: 2, borderRadius: 3 }

const TIPE_ORDER = ['pilgan', 'ceklist', 'essay', 'isian_singkat', 'benar_salah', 'pilgan_kategori']
const KESULITAN_ORDER = ['mudah', 'sedang', 'sulit']
const TIPE_SHORT: Record<string, string> = { pilgan: 'PG', ceklist: 'CK', essay: 'ES', isian_singkat: 'IS', benar_salah: 'BS', pilgan_kategori: 'PK' }
const KESULITAN_SHORT: Record<string, string> = { mudah: 'L', sedang: 'M', sulit: 'H' }

const styles = StyleSheet.create({
  page: { padding: 30, fontSize: 10, fontFamily: 'Helvetica', color: '#1f2937' },
  header: { marginBottom: 12, paddingBottom: 12, borderBottomWidth: 1, borderBottomColor: '#e5e7eb' },
  title: { fontSize: 15, fontWeight: 'bold', marginBottom: 4 },
  subtitle: { fontSize: 9, color: '#6b7280' },
  subtitleGuru: { fontSize: 9.5, color: '#374151', marginBottom: 2, fontWeight: 'bold' },
  // Matrix table
  matrixSection: { marginBottom: 14, paddingBottom: 12, borderBottomWidth: 1, borderBottomColor: '#e5e7eb' },
  matrixTitle: { fontSize: 8.5, fontWeight: 'bold', color: '#374151', marginBottom: 5 },
  matrixTable: { borderWidth: 0.5, borderColor: '#d1d5db', borderRadius: 2 },
  matrixRow: { flexDirection: 'row', borderBottomWidth: 0.5, borderBottomColor: '#e5e7eb' },
  matrixHeaderRow: { backgroundColor: '#f3f4f6' },
  matrixLastRow: { borderBottomWidth: 0 },
  matrixBabCell: { flex: 3, paddingHorizontal: 5, paddingVertical: 3, fontSize: 7.5 },
  matrixDataCell: { flex: 1, paddingHorizontal: 2, paddingVertical: 3, fontSize: 7.5, textAlign: 'center', borderLeftWidth: 0.5, borderLeftColor: '#e5e7eb' },
  matrixTotalCell: { flex: 1, paddingHorizontal: 2, paddingVertical: 3, fontSize: 7.5, textAlign: 'center', borderLeftWidth: 0.5, borderLeftColor: '#d1d5db', fontWeight: 'bold', color: '#111827' },
  matrixHeaderText: { fontWeight: 'bold', color: '#374151' },
  // Soal
  soalWrap: { marginBottom: 14, paddingBottom: 14, borderBottomWidth: 0.5, borderBottomColor: '#e5e7eb' },
  soalMeta: { flexDirection: 'row', gap: 6, marginBottom: 6, flexWrap: 'wrap' },
  nomor: { fontSize: 11, fontWeight: 'bold', color: '#111827' },
  badgePilgan:      { ...BADGE_BASE, backgroundColor: '#dbeafe', color: '#1d4ed8' },
  badgeCeklist:     { ...BADGE_BASE, backgroundColor: '#ffedd5', color: '#c2410c' },
  badgeEssay:       { ...BADGE_BASE, backgroundColor: '#dcfce7', color: '#15803d' },
  badgeIsian:       { ...BADGE_BASE, backgroundColor: '#ede9fe', color: '#6d28d9' },
  badgeMudah:       { ...BADGE_BASE, backgroundColor: '#d1fae5', color: '#065f46' },
  badgeSedang:      { ...BADGE_BASE, backgroundColor: '#fef9c3', color: '#854d0e' },
  badgeSulit:       { ...BADGE_BASE, backgroundColor: '#fee2e2', color: '#991b1b' },
  badgeNeutral:     { ...BADGE_BASE, backgroundColor: '#f3f4f6', color: '#374151' },
  pertanyaan: { fontSize: 10.5, lineHeight: 1.6, marginBottom: 6 },
  gambar: { maxWidth: 280, maxHeight: 180, marginVertical: 6, objectFit: 'contain' },
  pilihanRow: { flexDirection: 'row', alignItems: 'flex-start', marginBottom: 3 },
  pilihanLabel: { width: 22, fontSize: 10 },
  pilihanTeks: { flex: 1, fontSize: 10, lineHeight: 1.5 },
  benar: { color: '#15803d', fontWeight: 'bold' },
  salah: { color: '#374151' },
  essayHint: { fontSize: 9, color: '#9ca3af', fontStyle: 'italic', marginTop: 4 },
  footer: { position: 'absolute', bottom: 18, left: 30, right: 30, textAlign: 'center', fontSize: 8, color: '#9ca3af' },
})

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const TIPE_STYLE: Record<string, any> = {
  pilgan:        styles.badgePilgan,
  ceklist:       styles.badgeCeklist,
  essay:         styles.badgeEssay,
  isian_singkat: styles.badgeIsian,
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const KESULITAN_STYLE: Record<string, any> = {
  mudah:  styles.badgeMudah,
  sedang: styles.badgeSedang,
  sulit:  styles.badgeSulit,
}

function MatrixTable({ matrixData }: { matrixData: NonNullable<PdfMeta['matrixData']> }) {
  // Kumpulkan kolom yang punya target > 0 di setidaknya satu bab
  const activeColumns: string[] = []
  for (const tipe of TIPE_ORDER) {
    for (const kesulitan of KESULITAN_ORDER) {
      const key = `${tipe}_${kesulitan}_keluar`
      if (matrixData.some(bab => (bab.data[key] || 0) > 0)) {
        activeColumns.push(`${tipe}_${kesulitan}`)
      }
    }
  }

  if (activeColumns.length === 0) return null

  const colLabel = (col: string) => {
    const parts = col.split('_')
    const kesulitan = parts[parts.length - 1]
    const tipe = parts.slice(0, -1).join('_')
    return `${TIPE_SHORT[tipe] ?? tipe}\n${KESULITAN_SHORT[kesulitan] ?? kesulitan}`
  }

  const getVal = (bab: typeof matrixData[0], col: string) =>
    bab.data[`${col}_keluar`] || 0

  const rowTotal = (bab: typeof matrixData[0]) =>
    activeColumns.reduce((sum, col) => sum + getVal(bab, col), 0)

  return (
    <View style={styles.matrixSection} wrap={false}>
      <Text style={styles.matrixTitle}>Distribusi Soal per Bab</Text>
      <View style={styles.matrixTable}>
        {/* Header */}
        <View style={[styles.matrixRow, styles.matrixHeaderRow]}>
          <Text style={[styles.matrixBabCell, styles.matrixHeaderText]}>Bab</Text>
          {activeColumns.map(col => (
            <Text key={col} style={[styles.matrixDataCell, styles.matrixHeaderText]}>
              {colLabel(col)}
            </Text>
          ))}
          <Text style={[styles.matrixTotalCell, styles.matrixHeaderText]}>Total</Text>
        </View>
        {/* Data rows */}
        {matrixData.map((bab, idx) => (
          <View
            key={bab.bab_id_text}
            style={[styles.matrixRow, idx === matrixData.length - 1 ? styles.matrixLastRow : {}]}
          >
            <Text style={styles.matrixBabCell}>{bab.bab_id_text}</Text>
            {activeColumns.map(col => {
              const val = getVal(bab, col)
              return (
                <Text key={col} style={styles.matrixDataCell}>
                  {val > 0 ? val : '—'}
                </Text>
              )
            })}
            <Text style={styles.matrixTotalCell}>{rowTotal(bab)}</Text>
          </View>
        ))}
      </View>
    </View>
  )
}

export default function SoalPdfDocument({ soalList, meta }: Props) {
  const tanggalFormatted = new Date(meta.tanggal).toLocaleDateString('id-ID', {
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  })

  return (
    <Document>
      <Page size="A4" style={styles.page}>
        <View style={styles.header}>
          <Text style={styles.title}>{meta.judul}</Text>
          {(meta.namaGuru || meta.kelas) && (
            <Text style={styles.subtitleGuru}>
              {[meta.namaGuru, meta.kelas].filter(Boolean).join(' · ')}
            </Text>
          )}
          <Text style={styles.subtitle}>
            Diekspor: {tanggalFormatted} | {soalList.length} soal
          </Text>
        </View>

        {meta.matrixData && meta.matrixData.length > 0 && (
          <MatrixTable matrixData={meta.matrixData} />
        )}

        {soalList.map((soal, idx) => (
          <View key={soal.id} style={styles.soalWrap} wrap={false}>
            <View style={styles.soalMeta}>
              <Text style={styles.nomor}>{idx + 1}.</Text>
              <Text style={TIPE_STYLE[soal.tipe] ?? styles.badgeNeutral}>{TIPE_LABEL[soal.tipe] ?? soal.tipe}</Text>
              <Text style={KESULITAN_STYLE[soal.tingkat_kesulitan] ?? styles.badgeNeutral}>{KESULITAN_LABEL[soal.tingkat_kesulitan] ?? soal.tingkat_kesulitan}</Text>
              <Text style={styles.badgeNeutral}>Bab: {soal.bab_id_text}</Text>
              <Text style={styles.badgeNeutral}>Bobot: {soal.bobot}</Text>
            </View>

            <Text style={styles.pertanyaan}>{soal.pertanyaan_text}</Text>

            {soal.pertanyaan_images.map((src, i) => (
              <Image key={i} src={src} style={styles.gambar} />
            ))}

            {soal.pilihan?.map(p => (
              <View key={p.id}>
                <View style={styles.pilihanRow}>
                  <Text style={[styles.pilihanLabel, p.benar ? styles.benar : styles.salah]}>
                    {p.benar ? '✓' : '-'} {LABELS[p.id]}.
                  </Text>
                  <Text style={[styles.pilihanTeks, p.benar ? styles.benar : styles.salah]}>
                    {p.teks_plain}
                  </Text>
                </View>
                {p.gambar_url && (
                  <Image src={p.gambar_url} style={[styles.gambar, { marginLeft: 22 }]} />
                )}
              </View>
            ))}

            {(!soal.pilihan || soal.pilihan.length === 0) && (
              <Text style={styles.essayHint}>
                {soal.tipe === 'isian_singkat' ? '(Isian singkat)' : '(Soal uraian — tulis jawaban)'}
              </Text>
            )}
          </View>
        ))}

        <Text
          style={styles.footer}
          render={({ pageNumber, totalPages }) =>
            `${meta.judul} — Hal ${pageNumber} dari ${totalPages}`
          }
          fixed
        />
      </Page>
    </Document>
  )
}
