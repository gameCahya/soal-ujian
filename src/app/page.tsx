import {
  BookOpen, TrendingUp, CheckCircle, Clock, AlertCircle,
  Download, LayoutGrid, ArrowRight,
} from "lucide-react"
import { supabase } from "@/lib/supabase"
import type { UjianPsat } from "@/lib/ujian"
import ThemeToggle from "@/components/ThemeToggle"

export const revalidate = 300

interface GuruProgress {
  profile_id: string
  guru_nama: string | null
  guru_kelas: string | null
  guru_unit_sekolah: string | null
  ujian_id: string
  ujian_nama: string | null
  mapel_id: string
  mapel_nama: string
  mapel_kode: string | null
  total: number
  approved: number
  submitted: number
  draft: number
  needs_revision: number
  patokan_bank_total: number
  has_matrix: boolean
  glossary_url: string | null
  kisi_kisi_url: string | null
}

const AVATAR_COLORS = [
  { bg: "#FFB68A", text: "#6B2D00" },
  { bg: "#9DE3C4", text: "#0E4A2F" },
  { bg: "#C9B8FF", text: "#2E1A6B" },
  { bg: "#FFE072", text: "#5A4500" },
  { bg: "#FFA6C5", text: "#6B0E33" },
]

const STAT_VARIANTS = {
  lemon: { bg: "#FFF5C6", iconBg: "#FFE072", iconColor: "#5A4500", blob: "#FFE072" },
  lilac: { bg: "#ECE4FF", iconBg: "#C9B8FF", iconColor: "#2E1A6B", blob: "#C9B8FF" },
  mint:  { bg: "#DAF5E7", iconBg: "#9DE3C4", iconColor: "#0E4A2F", blob: "#9DE3C4" },
  peach: { bg: "#FFE3D0", iconBg: "#FFB68A", iconColor: "#6B2D00", blob: "#FFB68A" },
  pink:  { bg: "#FFD9E6", iconBg: "#FFA6C5", iconColor: "#6B0E33", blob: "#FFA6C5" },
}

function getInitials(name: string | null): string {
  if (!name) return "?"
  const parts = name.trim().split(" ")
  if (parts.length === 1) return parts[0][0].toUpperCase()
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
}

function getBarGradient(pct: number, hasPatokan: boolean): string {
  if (!hasPatokan || pct === 0) return "#E0D8CF"
  if (pct >= 80) return "linear-gradient(90deg, #9DE3C4, #34A86E)"
  if (pct >= 40) return "linear-gradient(90deg, #FFE072, #C99A14)"
  return "linear-gradient(90deg, #FFC9C9, #DC4F4F)"
}

export default async function HomePage() {
  // Sejak data bercakupan ujian, halaman ini menampilkan satu siklus saja —
  // yang aktif kalau sudah ada datanya, kalau belum siklus terbaru yang ada.
  const { data: ujianData } = await supabase.rpc("get_ujian_psat")
  const semuaUjian: UjianPsat[] = (ujianData as UjianPsat[]) ?? []
  const siklus = semuaUjian.find(u => u.event_aktif) ?? semuaUjian[0]
  const ujianSiklus = siklus
    ? semuaUjian.filter(u => u.event_id === siklus.event_id).map(u => u.ujian_id)
    : []

  const { data, error } = await supabase.rpc("get_public_guru_progress")
  const semuaRows: GuruProgress[] = (data as GuruProgress[]) ?? []
  const rows = ujianSiklus.length > 0
    ? semuaRows.filter(r => ujianSiklus.includes(r.ujian_id))
    : semuaRows

  const labelSiklus = siklus
    ? [siklus.event_nama, siklus.tahun_ajaran].filter(Boolean).join(" · ")
    : null

  const totalSoal      = rows.reduce((s, r) => s + Number(r.total), 0)
  const totalDraft     = rows.reduce((s, r) => s + Number(r.draft), 0)
  const totalApproved  = rows.reduce((s, r) => s + Number(r.approved), 0)
  const totalSubmitted = rows.reduce((s, r) => s + Number(r.submitted), 0)
  const totalRevision  = rows.reduce((s, r) => s + Number(r.needs_revision), 0)

  return (
    <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh" }}>

      {/* Decorative bg shapes */}
      <div className="fixed inset-0 pointer-events-none overflow-hidden" aria-hidden>
        <div style={{
          position: "absolute", top: "380px", right: "-60px",
          width: "120px", height: "120px", borderRadius: "50%",
          border: "1.5px solid var(--pp-ink)", background: "var(--pp-lemon)", opacity: 0.35,
        }} />
        <div style={{
          position: "absolute", top: "120px", right: "320px",
          width: "28px", height: "28px", background: "var(--pp-peach)",
          opacity: 0.6, transform: "rotate(15deg)",
          clipPath: "polygon(50% 0,61% 35%,98% 35%,68% 57%,79% 91%,50% 70%,21% 91%,32% 57%,2% 35%,39% 35%)",
        }} />
        <div style={{
          position: "absolute", top: "220px", right: "80px",
          width: "28px", height: "28px", background: "var(--pp-lilac)",
          opacity: 0.6, transform: "rotate(-8deg)",
          clipPath: "polygon(50% 0,61% 35%,98% 35%,68% 57%,79% 91%,50% 70%,21% 91%,32% 57%,2% 35%,39% 35%)",
        }} />
      </div>

      {/* Header */}
      <header className="sticky top-0 z-10" style={{ backgroundColor: "var(--pp-card)", borderBottom: "1px solid var(--pp-line)" }}>
        <div className="max-w-7xl mx-auto px-6 md:px-8 py-4 flex items-center justify-between gap-4">
          {/* Brand */}
          <div className="flex items-center gap-3 min-w-0">
            <div style={{
              width: "44px", height: "44px", borderRadius: "14px",
              backgroundColor: "var(--pp-primary)",
              display: "grid", placeItems: "center",
              color: "white", position: "relative",
              boxShadow: "0 4px 0 0 #1A2F8B",
              flexShrink: 0,
            }}>
              <BookOpen className="w-5 h-5" />
              <div style={{
                position: "absolute", inset: "6px", borderRadius: "10px",
                border: "1.5px dashed rgba(255,255,255,0.45)",
                pointerEvents: "none",
              }} />
            </div>
            <div className="min-w-0">
              <div className="font-bold text-sm leading-tight truncate" style={{ color: "var(--pp-ink)" }}>
                Portal Validasi Soal PSAT Al Abidin
              </div>
              <div className="text-xs mt-0.5 hidden sm:block" style={{ color: "var(--pp-muted)" }}>
                Progress upload soal ujian{labelSiklus ? ` — ${labelSiklus}` : ""}
              </div>
            </div>
          </div>

          {/* Nav actions */}
          <div className="flex items-center gap-2 shrink-0">
            <div className="[&_button]:rounded-full [&_button]:text-xs [&_button]:px-3 [&_button]:py-2"
                 style={{ color: "var(--pp-ink-2)" }}>
              <ThemeToggle />
            </div>
            <a
              href="/login"
              className="flex items-center gap-2 text-sm font-semibold"
              style={{
                backgroundColor: "var(--pp-ink)", color: "#FFFFFF",
                padding: "10px 18px", borderRadius: "999px",
                boxShadow: "0 3px 0 0 rgba(0,0,0,0.5)",
                textDecoration: "none", whiteSpace: "nowrap",
              }}
            >
              Masuk
              <ArrowRight className="w-3.5 h-3.5" />
            </a>
          </div>
        </div>
      </header>

      {/* Hero */}
      <section className="max-w-7xl mx-auto px-6 md:px-8 pt-10 pb-6 relative">
        <div className="grid grid-cols-1 lg:grid-cols-[1.4fr_1fr] gap-8 items-end">
          <div>
            {/* Eyebrow */}
            <span className="inline-flex items-center gap-2 text-xs font-semibold px-3 py-1.5 rounded-full"
                  style={{
                    backgroundColor: "#E8EDFF", border: "1px solid #D5DEFF",
                    color: "var(--pp-primary)", letterSpacing: "0.08em", textTransform: "uppercase",
                  }}>
              <span style={{ width: "6px", height: "6px", borderRadius: "50%", backgroundColor: "var(--pp-primary)", flexShrink: 0 }} />
              Update tiap 5 menit · Live progress
            </span>

            {/* Title */}
            <h1 className="font-display font-semibold mt-4 mb-3"
                style={{ fontSize: "clamp(38px, 5vw, 64px)", lineHeight: 1.02, letterSpacing: "-0.025em", color: "var(--pp-ink)" }}>
              Setiap guru, setiap{" "}
              <em style={{ fontStyle: "italic", color: "var(--pp-primary)" }}>soal</em>,<br />
              terpantau{" "}
              <span className="squiggle-underline">jelas.</span>
            </h1>

            <p style={{ color: "var(--pp-ink-2)", fontSize: "17px", lineHeight: 1.55, maxWidth: "540px", margin: 0 }}>
              Dashboard publik untuk memantau perkembangan unggahan soal PSAT dari seluruh guru SMP Al Abidin. Transparan, real-time, dan dirancang untuk membuat proses validasi terasa lebih ringan.
            </p>
          </div>

          {/* Doodle cards */}
          <div className="hidden lg:flex flex-col items-end gap-3">
            {rows.length > 0 && (
              <div className="doodle-card" style={{ transform: "rotate(-2deg)" }}>
                <div className="flex" style={{ marginRight: "4px" }}>
                  {rows.slice(0, 4).map((g, i) => {
                    const col = AVATAR_COLORS[i % AVATAR_COLORS.length]
                    return (
                      <div key={g.profile_id} style={{
                        width: "32px", height: "32px", borderRadius: "50%",
                        border: "2px solid var(--pp-card)", marginRight: "-8px",
                        backgroundColor: col.bg, color: col.text,
                        display: "grid", placeItems: "center",
                        fontWeight: 700, fontSize: "11px", flexShrink: 0, zIndex: 4 - i,
                        position: "relative",
                      }}>
                        {getInitials(g.guru_nama)}
                      </div>
                    )
                  })}
                  {rows.length > 4 && (
                    <div style={{
                      width: "32px", height: "32px", borderRadius: "50%",
                      border: "2px solid var(--pp-card)", marginRight: "-8px",
                      backgroundColor: "#FFA6C5", color: "#6B0E33",
                      display: "grid", placeItems: "center",
                      fontWeight: 700, fontSize: "11px", flexShrink: 0, position: "relative",
                    }}>
                      +{rows.length - 4}
                    </div>
                  )}
                </div>
                <div style={{ fontSize: "12px", color: "var(--pp-ink-2)", paddingLeft: "8px" }}>
                  <strong style={{ color: "var(--pp-ink)" }}>{rows.length} guru aktif</strong><br />
                  tahun ini
                </div>
              </div>
            )}

            <div className="doodle-card" style={{ transform: "rotate(1.5deg)", width: "280px" }}>
              <div style={{
                width: "42px", height: "42px", borderRadius: "12px",
                backgroundColor: "var(--pp-mint)", border: "1.5px solid var(--pp-ink)",
                display: "grid", placeItems: "center", flexShrink: 0,
              }}>
                <CheckCircle className="w-5 h-5" style={{ color: "#0E4A2F" }} />
              </div>
              <div style={{ fontSize: "12px", color: "var(--pp-ink-2)" }}>
                <strong style={{ color: "var(--pp-ink)" }}>{totalApproved} soal di-approve</strong><br />
                dari total {totalSoal} soal
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Stats */}
      <section className="max-w-7xl mx-auto px-6 md:px-8 pb-7">
        <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
          <StatCard value={totalSoal}      label="Total Soal"      variant="lemon" icon={<TrendingUp className="w-5 h-5" />} />
          <StatCard value={totalDraft}     label="Draft"           variant="lilac" icon={<AlertCircle className="w-5 h-5" />} />
          <StatCard value={totalApproved}  label="Approved"        variant="mint"  icon={<CheckCircle className="w-5 h-5" />} />
          <StatCard value={totalSubmitted} label="Menunggu Review" variant="peach" icon={<Clock className="w-5 h-5" />} />
          <StatCard value={totalRevision}  label="Perlu Revisi"    variant="pink"  icon={<AlertCircle className="w-5 h-5" />} />
        </div>
      </section>

      {/* Progress table */}
      <section className="max-w-7xl mx-auto px-6 md:px-8 pb-14">
        <div className="rounded-[28px] overflow-hidden shadow-hard-lg"
             style={{ backgroundColor: "var(--pp-card)", border: "1.5px solid var(--pp-ink)" }}>

          {/* Card header */}
          <div className="px-7 py-5 flex items-center justify-between"
               style={{ borderBottom: "1.5px solid var(--pp-ink)", background: "linear-gradient(180deg, #FFF8F0 0%, #FFFFFF 100%)" }}>
            <h2 className="font-display font-semibold flex items-center gap-2.5"
                style={{ fontSize: "22px", letterSpacing: "-0.01em", color: "var(--pp-ink)", margin: 0 }}>
              <span style={{
                width: "14px", height: "14px", borderRadius: "4px",
                backgroundColor: "var(--pp-peach)", border: "1.5px solid var(--pp-ink)", flexShrink: 0,
              }} />
              Progress per akun guru
            </h2>
            <span className="text-xs font-semibold px-3 py-1.5 rounded-full"
                  style={{ backgroundColor: "var(--pp-ink)", color: "white" }}>
              {rows.length} akun aktif
            </span>
          </div>

          {error ? (
            <div className="p-8 text-center text-sm" style={{ color: "#dc2626" }}>
              Gagal memuat data. Silakan coba lagi.
            </div>
          ) : rows.length === 0 ? (
            <div className="p-8 text-center text-sm" style={{ color: "var(--pp-muted)" }}>
              Belum ada data tersedia.
            </div>
          ) : (
            <>
              {/* Mobile: card list */}
              <div className="block md:hidden">
                {rows.map((row, i) => {
                  const total   = Number(row.total)
                  const patokan = Number(row.patokan_bank_total)
                  const hasP    = patokan > 0
                  const pct     = hasP ? Math.min(100, Math.round((total / patokan) * 100)) : 0
                  const col     = AVATAR_COLORS[i % AVATAR_COLORS.length]

                  return (
                    <div key={row.profile_id} className="p-5 space-y-3"
                         style={{ borderBottom: i < rows.length - 1 ? "1px solid var(--pp-line)" : "none" }}>
                      <div className="flex items-center gap-3">
                        <div style={{
                          width: "36px", height: "36px", borderRadius: "50%",
                          backgroundColor: col.bg, color: col.text,
                          display: "grid", placeItems: "center",
                          fontWeight: 700, fontSize: "12px",
                          border: "1.5px solid var(--pp-ink)", flexShrink: 0,
                        }}>
                          {getInitials(row.guru_nama)}
                        </div>
                        <div>
                          <div className="font-semibold text-sm" style={{ color: "var(--pp-ink)" }}>
                            {row.mapel_nama}
                            {row.mapel_kode && (
                              <span className="ml-2 text-xs px-1.5 py-0.5 rounded"
                                    style={{ backgroundColor: "#FFE3D0", color: "#6B2D00", fontWeight: 600 }}>
                                {row.mapel_kode}
                              </span>
                            )}
                          </div>
                          <div className="text-xs mt-0.5" style={{ color: "var(--pp-muted)" }}>
                            {row.guru_nama ?? "—"}
                            {row.guru_kelas && ` · Kls ${row.guru_kelas}`}
                          </div>
                        </div>
                      </div>

                      <div>
                        <div style={{
                          height: "10px", borderRadius: "999px",
                          backgroundColor: "#F4ECDF", border: "1.5px solid var(--pp-ink)", overflow: "hidden",
                        }}>
                          <div style={{ height: "100%", width: `${pct}%`, background: getBarGradient(pct, hasP) }} />
                        </div>
                        <div className="text-xs mt-1.5" style={{ color: "var(--pp-ink-2)", fontVariantNumeric: "tabular-nums" }}>
                          {hasP ? `${total}/${patokan} soal · ${pct}%` : `${total}/— patokan belum diset`}
                        </div>
                      </div>

                      <StatusRow row={row} />

                      <div className="flex items-center gap-1.5">
                        <IconBtn href={row.glossary_url} title="Download Glossary" newTab><Download className="w-3.5 h-3.5" /></IconBtn>
                        <IconBtn href={row.kisi_kisi_url} title="Download Kisi-kisi" newTab><Download className="w-3.5 h-3.5" /></IconBtn>
                        <IconBtn href={row.has_matrix ? `/matrix/${row.ujian_id}/${row.profile_id}` : null} title="Lihat Matrix"><LayoutGrid className="w-3.5 h-3.5" /></IconBtn>
                      </div>
                    </div>
                  )
                })}
              </div>

              {/* Desktop: table */}
              <div className="hidden md:block overflow-x-auto">
                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                  <thead>
                    <tr style={{ backgroundColor: "#FFF4E5", borderBottom: "1.5px solid var(--pp-ink)" }}>
                      {["Mata Pelajaran", "Guru", "Progress", "Status", "Aksi"].map(h => (
                        <th key={h} style={{
                          textAlign: "left", padding: "14px 22px",
                          fontSize: "11px", fontWeight: 700,
                          textTransform: "uppercase", letterSpacing: "0.1em",
                          color: "var(--pp-ink-2)",
                        }}>
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((row, i) => {
                      const total   = Number(row.total)
                      const patokan = Number(row.patokan_bank_total)
                      const hasP    = patokan > 0
                      const pct     = hasP ? Math.min(100, Math.round((total / patokan) * 100)) : 0
                      const col     = AVATAR_COLORS[i % AVATAR_COLORS.length]

                      return (
                        <tr key={row.profile_id}
                            style={{ borderBottom: i < rows.length - 1 ? "1px solid var(--pp-line)" : "none" }}>

                          {/* Mapel */}
                          <td style={{ padding: "18px 22px", verticalAlign: "middle", fontSize: "14px" }}>
                            <span className="font-semibold" style={{ color: "var(--pp-ink)" }}>{row.mapel_nama}</span>
                            {row.mapel_kode && (
                              <span className="ml-2 text-xs px-2 py-0.5 rounded"
                                    style={{ backgroundColor: "#FFE3D0", color: "#6B2D00", fontWeight: 600 }}>
                                {row.mapel_kode}
                              </span>
                            )}
                          </td>

                          {/* Guru */}
                          <td style={{ padding: "18px 22px", verticalAlign: "middle", fontSize: "14px" }}>
                            <div className="flex items-center gap-2.5">
                              <div style={{
                                width: "32px", height: "32px", borderRadius: "50%",
                                backgroundColor: col.bg, color: col.text,
                                display: "grid", placeItems: "center",
                                fontWeight: 700, fontSize: "12px",
                                border: "1.5px solid var(--pp-ink)", flexShrink: 0,
                              }}>
                                {getInitials(row.guru_nama)}
                              </div>
                              <div>
                                <div className="font-medium" style={{ color: "var(--pp-ink)" }}>
                                  {row.guru_nama ?? "—"}
                                  {row.guru_kelas && (
                                    <span className="ml-2 text-xs px-2 py-0.5 rounded-full font-semibold"
                                          style={{ backgroundColor: "#ECE4FF", color: "#2E1A6B", border: "1px solid #C9B8FF" }}>
                                      Kls {row.guru_kelas}
                                    </span>
                                  )}
                                </div>
                                {row.guru_unit_sekolah && (
                                  <div className="text-xs mt-0.5" style={{ color: "var(--pp-muted)" }}>
                                    {row.guru_unit_sekolah}
                                  </div>
                                )}
                              </div>
                            </div>
                          </td>

                          {/* Progress */}
                          <td style={{ padding: "18px 22px", verticalAlign: "middle" }}>
                            <div style={{ width: "180px" }}>
                              <div style={{
                                height: "10px", borderRadius: "999px",
                                backgroundColor: "#F4ECDF", border: "1.5px solid var(--pp-ink)", overflow: "hidden",
                              }}>
                                <div style={{ height: "100%", width: `${pct}%`, background: getBarGradient(pct, hasP) }} />
                              </div>
                              <div className="text-xs mt-1.5" style={{ color: "var(--pp-ink-2)", fontVariantNumeric: "tabular-nums" }}>
                                {hasP ? `${total} / ${patokan} soal · ${pct}%` : `${total}/— belum diset`}
                              </div>
                            </div>
                          </td>

                          {/* Status */}
                          <td style={{ padding: "18px 22px", verticalAlign: "middle" }}>
                            <StatusRow row={row} />
                          </td>

                          {/* Aksi */}
                          <td style={{ padding: "18px 22px", verticalAlign: "middle" }}>
                            <div className="flex items-center gap-1.5">
                              <IconBtn href={row.glossary_url} title="Download Glossary" newTab><Download className="w-3.5 h-3.5" /></IconBtn>
                              <IconBtn href={row.kisi_kisi_url} title="Download Kisi-kisi" newTab><Download className="w-3.5 h-3.5" /></IconBtn>
                              <IconBtn href={row.has_matrix ? `/matrix/${row.ujian_id}/${row.profile_id}` : null} title="Lihat Matrix"><LayoutGrid className="w-3.5 h-3.5" /></IconBtn>
                            </div>
                          </td>
                        </tr>
                      )
                    })}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </div>
      </section>

      <footer className="text-center pb-7" style={{ fontSize: "12px", color: "var(--pp-muted)" }}>
        © 2026 <strong style={{ color: "var(--pp-ink-2)" }}>PSAT SMP Al Abidin</strong> · Dibuat dengan teliti oleh tim akademik
      </footer>
    </div>
  )
}

function StatCard({ value, label, variant, icon }: {
  value: number
  label: string
  variant: keyof typeof STAT_VARIANTS
  icon: React.ReactNode
}) {
  const v = STAT_VARIANTS[variant]
  return (
    <div className="relative overflow-hidden shadow-hard-md" style={{
      borderRadius: "22px",
      padding: "22px 20px",
      border: "1.5px solid var(--pp-ink)",
      backgroundColor: v.bg,
      minHeight: "150px",
    }}>
      <div style={{
        position: "absolute", right: "-20px", top: "-20px",
        width: "90px", height: "90px", borderRadius: "50%",
        backgroundColor: v.blob, opacity: 0.5,
      }} />
      <div style={{
        width: "36px", height: "36px", borderRadius: "12px",
        backgroundColor: v.iconBg, color: v.iconColor,
        display: "grid", placeItems: "center",
        marginBottom: "28px", position: "relative",
      }}>
        {icon}
      </div>
      <div className="font-display font-semibold relative"
           style={{ fontSize: "44px", lineHeight: 1, letterSpacing: "-0.03em", color: "var(--pp-ink)" }}>
        {value}
      </div>
      <div className="font-medium relative mt-1.5" style={{ fontSize: "13px", color: "var(--pp-ink-2)" }}>
        {label}
      </div>
    </div>
  )
}

function StatusRow({ row }: { row: GuruProgress }) {
  const approved      = Number(row.approved)
  const submitted     = Number(row.submitted)
  const draft         = Number(row.draft)
  const needsRevision = Number(row.needs_revision)

  return (
    <div className="flex flex-col gap-0.5" style={{ fontSize: "12px", fontVariantNumeric: "tabular-nums" }}>
      <span className="flex items-center gap-1.5">
        <span style={{ width: "7px", height: "7px", borderRadius: "2px", backgroundColor: "#34A86E", flexShrink: 0 }} />
        <strong>{approved}</strong>&nbsp;approved
      </span>
      <span className="flex items-center gap-1.5">
        <span style={{ width: "7px", height: "7px", borderRadius: "2px", backgroundColor: "#C99A14", flexShrink: 0 }} />
        <strong>{submitted}</strong>&nbsp;menunggu
      </span>
      {draft > 0 && (
        <span className="flex items-center gap-1.5" style={{ color: "var(--pp-muted)" }}>
          <span style={{ width: "7px", height: "7px", borderRadius: "2px", backgroundColor: "var(--pp-muted)", flexShrink: 0 }} />
          <strong>{draft}</strong>&nbsp;draft
        </span>
      )}
      {needsRevision > 0 && (
        <span className="flex items-center gap-1.5" style={{ color: "#DC4F4F" }}>
          <span style={{ width: "7px", height: "7px", borderRadius: "2px", backgroundColor: "#DC4F4F", flexShrink: 0 }} />
          <strong>{needsRevision}</strong>&nbsp;revisi
        </span>
      )}
    </div>
  )
}

function IconBtn({ href, children, title, newTab }: {
  href: string | null | undefined
  children: React.ReactNode
  title: string
  newTab?: boolean
}) {
  const base: React.CSSProperties = {
    width: "34px", height: "34px", borderRadius: "12px",
    border: "1.5px solid var(--pp-ink)",
    backgroundColor: "var(--pp-card)",
    display: "grid", placeItems: "center",
    boxShadow: "2px 2px 0 0 var(--pp-ink)",
    color: "var(--pp-ink)",
    textDecoration: "none",
    flexShrink: 0,
  }

  if (!href) {
    return (
      <span title={title} style={{ ...base, opacity: 0.3, boxShadow: "none", cursor: "not-allowed" }}>
        {children}
      </span>
    )
  }

  return (
    <a href={href} title={title}
       target={newTab ? "_blank" : undefined}
       rel={newTab ? "noopener noreferrer" : undefined}
       style={base}>
      {children}
    </a>
  )
}
