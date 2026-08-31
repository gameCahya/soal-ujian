"use client"

import { useEffect, useState } from "react"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabase"
import Toast from "@/components/Toast"
import { CheckCircle, Clock, AlertCircle, ArrowLeft, Pencil, Trash2, Check, X, Highlighter } from "lucide-react"
import ThemeToggle from "@/components/ThemeToggle"
import DownloadDropdown from "@/components/DownloadDropdown"
import { ambilUjianPsat, labelUjian, pesanError, type UjianPsat } from "@/lib/ujian"

/** Ujian yang dibuka dari dashboard, dioper lewat localStorage. */
const VALIDASI_UJIAN_KEY = "psat_validasi_ujian_id"

interface UjianSummary {
  id: string          // ujian_id
  mapel_id: string | null
  nama: string        // nama mata pelajaran
  level: string | null
  submitted: number
  needs_revision: number
  approved: number
}

const TIPE_LABELS: Record<string, string> = {
  pilgan: "Pilgan",
  ceklist: "Ceklist",
  essay: "Essay",
  isian_singkat: "Isian Singkat",
  benar_salah: "Benar/Salah",
}

const TIPE_COLORS: Record<string, { bg: string; accent: string }> = {
  pilgan:        { bg: "#ECE4FF", accent: "#6d28d9" },
  ceklist:       { bg: "#DAF5E7", accent: "#15803d" },
  essay:         { bg: "#FFE3D0", accent: "#c2410c" },
  isian_singkat: { bg: "#FFF5C6", accent: "#92400e" },
  benar_salah:   { bg: "#D8ECFF", accent: "#1d4ed8" },
}

const KESULITAN_COLORS: Record<string, { bg: string; text: string }> = {
  mudah:  { bg: "#d1fae5", text: "#065f46" },
  sedang: { bg: "#fef9c3", text: "#854d0e" },
  sulit:  { bg: "#fee2e2", text: "#991b1b" },
}

interface HighlightItem {
  id: string
  field: string   // "pertanyaan" | "pilihan_0" | "pilihan_1" | ...
  text: string
  color: "yellow" | "red"
  note: string
  occurrenceIndex?: number  // which occurrence to highlight (0-indexed)
}

function applyHighlights(html: string, highlights: HighlightItem[], field: string): string {
  const relevant = highlights.filter(h => h.field === field)
  if (!relevant.length) return html
  let result = html
  for (const h of relevant) {
    const escaped = h.text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    const bg = h.color === "red" ? "#fecaca" : "#fef08a"
    const targetIndex = h.occurrenceIndex ?? 0
    let count = 0
    // Split by HTML tags, only replace inside text nodes
    const parts = result.split(/(<[^>]+>)/)
    result = parts.map(part => {
      if (part.startsWith("<")) return part
      return part.replace(new RegExp(escaped, "g"), match => {
        const isTarget = count === targetIndex
        count++
        return isTarget
          ? `<mark style="background:${bg};border-radius:3px;padding:0 2px;cursor:help" title="${h.note || "Ditandai validator"}">${match}</mark>`
          : match
      })
    }).join("")
  }
  return result
}

export default function ValidasiPage() {
  const router = useRouter()
  const [user, setUser] = useState<any>(null)
  const [ujianSummaries, setUjianSummaries] = useState<UjianSummary[]>([])
  const [selectedUjian, setSelectedUjian] = useState<UjianSummary | null>(null)
  const [soalList, setSoalList] = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [loadingSoal, setLoadingSoal] = useState(false)
  const [saving, setSaving] = useState(false)
  const [toast, setToast] = useState<{ message: string; type: "success" | "error" | "info" } | null>(null)
  const [revisionNotes, setRevisionNotes] = useState<Record<string, string>>({})
  const [editingNote, setEditingNote] = useState<{ soalId: string; index: number; text: string } | null>(null)
  const [validatorMapelIds, setValidatorMapelIds] = useState<string[] | null>(null)
  const [guruMap, setGuruMap] = useState<Record<string, { nama: string }>>({})
  const [filterGuru, setFilterGuru] = useState<string | null>(null)
  const [filterStatusValidasi, setFilterStatusValidasi] = useState<string | null>(null)
  const [highlightPopover, setHighlightPopover] = useState<{ soalId: string; field: string; text: string; x: number; y: number; occurrenceIndex: number } | null>(null)
  const [highlightColor, setHighlightColor] = useState<"yellow" | "red">("yellow")
  const [highlightNote, setHighlightNote] = useState("")
  const [savingHighlight, setSavingHighlight] = useState(false)

  useEffect(() => {
    async function load() {
      const { data: { user: u } } = await supabase.auth.getUser()
      if (!u) { router.push("/login"); return }

      const { data: profile } = await supabase
        .from("profiles")
        .select("role, nama, no_hp")
        .eq("id", u.id)
        .single()

      if (!profile || !["admin", "validator"].includes(profile.role)) {
        setToast({ message: "Akses ditolak", type: "error" })
        setTimeout(() => router.push("/dashboard"), 1500)
        return
      }

      if (profile.role === "validator") {
        const { data: guruData } = await supabase
          .from("psat_guru_data")
          .select("bank, no_rekening, unit_sekolah")
          .eq("profile_id", u.id)
          .maybeSingle()

        const missingFields: string[] = []
        if (!profile.nama || profile.nama === u.id) missingFields.push("Nama")
        if (!profile.no_hp) missingFields.push("No HP")
        if (!guruData?.unit_sekolah) missingFields.push("Unit Sekolah")
        if (!guruData?.bank) missingFields.push("Bank")
        if (!guruData?.no_rekening) missingFields.push("No Rekening")

        if (missingFields.length > 0) {
          setToast({ message: `Lengkapi profil dulu: ${missingFields.join(", ")}`, type: "info" })
          setTimeout(() => router.push("/dashboard/profile"), 1500)
          return
        }
      }

      setUser({ ...u, nama: profile.nama })

      let assignedMapelIds: string[] | null = null
      if (profile.role === "validator") {
        const { data: vmRows } = await supabase
          .from("psat_validator_mapel")
          .select("mapel_id")
          .eq("validator_id", u.id)
        assignedMapelIds = vmRows?.map((r: any) => r.mapel_id) ?? []
        setValidatorMapelIds(assignedMapelIds)
      }

      // Antrean validasi kini per ujian (mapel × kelas), bukan per mapel —
      // dari sinilah kelas soal berasal sekarang.
      let ujianRows: UjianPsat[] = []
      try {
        ujianRows = await ambilUjianPsat()
      } catch (e) {
        setToast({ message: "Gagal memuat daftar ujian: " + pesanError(e), type: "error" })
      }

      const { data: soalCounts } = await supabase
        .from("bank_soal")
        .select("ujian_id, status")
        .in("status", ["submitted", "needs_revision", "approved"])

      if (soalCounts) {
        let summaries: UjianSummary[] = ujianRows.map(u => ({
          id: u.ujian_id,
          mapel_id: u.psat_mapel_id,
          nama: u.mapel_nama || u.ujian_nama,
          level: u.level,
          submitted: soalCounts.filter(s => s.ujian_id === u.ujian_id && s.status === "submitted").length,
          needs_revision: soalCounts.filter(s => s.ujian_id === u.ujian_id && s.status === "needs_revision").length,
          approved: soalCounts.filter(s => s.ujian_id === u.ujian_id && s.status === "approved").length,
        })).filter(m => m.submitted + m.needs_revision + m.approved > 0)

        // Penugasan validator masih per mata pelajaran
        if (assignedMapelIds !== null) {
          summaries = summaries.filter(m => m.mapel_id && assignedMapelIds!.includes(m.mapel_id))
        }

        setUjianSummaries(summaries)

        const savedUjianId = localStorage.getItem(VALIDASI_UJIAN_KEY)
        if (savedUjianId) {
          localStorage.removeItem(VALIDASI_UJIAN_KEY)
          const found = summaries.find(m => m.id === savedUjianId)
          if (found) openUjian(found)
        }
      }

      setLoading(false)
    }
    load()
  }, [router])

  const openUjian = async (ujian: UjianSummary, initialStatus?: string) => {
    setSelectedUjian(ujian)
    setLoadingSoal(true)
    setSoalList([])
    setGuruMap({})
    setFilterGuru(null)
    setFilterStatusValidasi(initialStatus ?? null)
    setRevisionNotes({})

    const { data: soal, error: soalError } = await supabase
      .from("bank_soal")
      .select("id,pertanyaan,tipe,tingkat_kesulitan,bobot,bab_id_text,created_at,pilihan,pilihan_gambar,status,revision_notes,revision_history,guru_id,highlights")
      .eq("ujian_id", ujian.id)
      .in("status", ["submitted", "needs_revision", "approved"])
      .order("created_at", { ascending: true })

    if (soalError) {
      setToast({ message: "Gagal memuat soal: " + soalError.message, type: "error" })
    } else {
      const soalData = soal ?? []
      setSoalList(soalData)

      // Hanya nama yang diambil dari profil. Kelas datang dari ujian, supaya
      // soal lama tidak ikut berpindah kelas saat guru ganti kelas.
      const guruIds = [...new Set(soalData.map((s: any) => s.guru_id).filter(Boolean))]
      if (guruIds.length > 0) {
        const { data: profiles } = await supabase
          .from("profiles")
          .select("id, nama")
          .in("id", guruIds)
        if (profiles) {
          const map: Record<string, { nama: string }> = {}
          profiles.forEach((p: any) => { map[p.id] = { nama: p.nama || "Guru" } })
          setGuruMap(map)
        }
      }
    }
    setLoadingSoal(false)
  }

  const handleStatusChange = async (soalId: string, newStatus: string) => {
    setSaving(true)
    const notes = revisionNotes[soalId] || ""
    const validatorName = user?.nama || "Validator"
    const fullNotes = newStatus === "approved"
      ? `[${validatorName}] Approved`
      : notes ? `[${validatorName}] ${notes}` : `[${validatorName}] Review`

    const currentSoal = soalList.find(s => s.id === soalId)
    const newHistory = [...(currentSoal?.revision_history || []), fullNotes]

    const { error } = await supabase
      .from("bank_soal")
      .update({ status: newStatus, revision_notes: fullNotes, revision_history: newHistory, updated_at: new Date().toISOString() })
      .eq("id", soalId)

    setSaving(false)

    if (error) {
      setToast({ message: "Error: " + error.message, type: "error" })
    } else {
      setToast({ message: "Status diperbarui!", type: "success" })
      setSoalList(prev => prev.map(s =>
        s.id === soalId ? { ...s, status: newStatus, revision_notes: fullNotes, revision_history: newHistory } : s
      ))
      setUjianSummaries(prev => prev.map(m => {
        if (m.id !== selectedUjian?.id) return m
        const old = soalList.find(s => s.id === soalId)
        if (!old) return m
        const dec = (k: keyof UjianSummary) => Math.max(0, (m[k] as number) - 1)
        const inc = (k: keyof UjianSummary) => (m[k] as number) + 1
        const updated = { ...m }
        if (old.status === "submitted") updated.submitted = dec("submitted")
        if (old.status === "needs_revision") updated.needs_revision = dec("needs_revision")
        if (old.status === "approved") updated.approved = dec("approved")
        if (newStatus === "submitted") updated.submitted = inc("submitted")
        if (newStatus === "needs_revision") updated.needs_revision = inc("needs_revision")
        if (newStatus === "approved") updated.approved = inc("approved")
        return updated
      }))
      setRevisionNotes(prev => ({ ...prev, [soalId]: "" }))

      supabase.auth.getSession().then(({ data: { session } }) => {
        if (!session) return

        if (newStatus === "needs_revision" && currentSoal?.guru_id && selectedUjian) {
          fetch("/api/notifications/whatsapp", {
            method: "POST",
            headers: { "Content-Type": "application/json", "Authorization": `Bearer ${session.access_token}` },
            body: JSON.stringify({
              type: "needs_revision",
              guruId: currentSoal.guru_id,
              mapelNama: labelUjian({ mapel_nama: selectedUjian.nama, level: selectedUjian.level }),
              catatanRevisi: notes || "Mohon periksa kembali soal Anda.",
            }),
          }).catch(() => {})
        }

        if (newStatus === "approved" && currentSoal?.guru_id && selectedUjian) {
          // Hitung updatedList manual karena setSoalList bersifat async
          const updatedList = soalList.map(s => s.id === soalId ? { ...s, status: newStatus } : s)
          const guruSoal = updatedList.filter(s => s.guru_id === currentSoal.guru_id)
          const allApproved = guruSoal.length > 0 && guruSoal.every(s => s.status === "approved")

          if (allApproved) {
            fetch("/api/notifications/whatsapp", {
              method: "POST",
              headers: { "Content-Type": "application/json", "Authorization": `Bearer ${session.access_token}` },
              body: JSON.stringify({
                type: "guru_all_approved",
                guruId: currentSoal.guru_id,
                mapelNama: labelUjian({ mapel_nama: selectedUjian.nama, level: selectedUjian.level }),
                totalSoal: guruSoal.length,
              }),
            }).catch(() => {})
          }
        }
      })
    }
  }

  const getRevisionNotes = (notes: string | null) => {
    if (!notes) return ""
    if (notes.includes("Approved")) return "Approved"
    const match = notes.match(/^\[([^\]]+)\]\s*(.*)/)
    return match ? match[2] : notes
  }

  const handleEditNote = async (soalId: string, index: number, newText: string) => {
    const soal = soalList.find(s => s.id === soalId)
    if (!soal) return
    setSaving(true)
    const oldItem = soal.revision_history[index]
    const prefix = oldItem.match(/^(\[[^\]]+\]\s*)/)?.[1] ?? ""
    const newHistory = soal.revision_history.map((h: string, i: number) => i === index ? prefix + newText : h)
    const newNotes = newHistory[newHistory.length - 1]
    const { error } = await supabase.from("bank_soal")
      .update({ revision_notes: newNotes, revision_history: newHistory, updated_at: new Date().toISOString() })
      .eq("id", soalId)
    setSaving(false)
    if (error) {
      setToast({ message: "Gagal mengedit: " + error.message, type: "error" })
    } else {
      setSoalList(prev => prev.map(s => s.id === soalId ? { ...s, revision_notes: newNotes, revision_history: newHistory } : s))
      setEditingNote(null)
      setToast({ message: "Catatan diperbarui!", type: "success" })
    }
  }

  const handleDeleteNote = async (soalId: string, index: number) => {
    const soal = soalList.find(s => s.id === soalId)
    if (!soal) return
    setSaving(true)
    const newHistory = soal.revision_history.filter((_: any, i: number) => i !== index)
    const newNotes = newHistory.length > 0 ? newHistory[newHistory.length - 1] : null
    const { error } = await supabase.from("bank_soal")
      .update({ revision_notes: newNotes, revision_history: newHistory, updated_at: new Date().toISOString() })
      .eq("id", soalId)
    setSaving(false)
    if (error) {
      setToast({ message: "Gagal menghapus: " + error.message, type: "error" })
    } else {
      setSoalList(prev => prev.map(s => s.id === soalId ? { ...s, revision_notes: newNotes, revision_history: newHistory } : s))
      setToast({ message: "Catatan dihapus!", type: "success" })
    }
  }

  const handleTextSelect = (soalId: string, field: string) => (e: React.MouseEvent) => {
    const selection = window.getSelection()
    const text = selection?.toString().trim()
    if (!text || text.length < 2) return
    const range = selection!.getRangeAt(0)
    const rect = range.getBoundingClientRect()

    // Count which occurrence of `text` was selected
    const container = e.currentTarget as HTMLElement
    const walker = document.createTreeWalker(container, NodeFilter.SHOW_TEXT)
    let charOffset = 0
    let node = walker.nextNode() as Text | null
    while (node) {
      if (node === range.startContainer) { charOffset += range.startOffset; break }
      charOffset += node.length
      node = walker.nextNode() as Text | null
    }
    const fullText = container.innerText || container.textContent || ""
    const escaped = text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    const occurrenceIndex = (fullText.slice(0, charOffset).match(new RegExp(escaped, "g")) || []).length

    setHighlightPopover({ soalId, field, text, x: rect.left + rect.width / 2, y: rect.bottom + 8, occurrenceIndex })
    setHighlightColor("yellow")
    setHighlightNote("")
  }

  const handleSaveHighlight = async () => {
    if (!highlightPopover) return
    const soal = soalList.find(s => s.id === highlightPopover.soalId)
    if (!soal) return
    setSavingHighlight(true)
    const newHighlight: HighlightItem = {
      id: Date.now().toString(),
      field: highlightPopover.field,
      text: highlightPopover.text,
      color: highlightColor,
      note: highlightNote.trim(),
      occurrenceIndex: highlightPopover.occurrenceIndex,
    }
    const updated = [...(soal.highlights || []), newHighlight]
    const { error } = await supabase.from("bank_soal").update({ highlights: updated }).eq("id", highlightPopover.soalId)
    setSavingHighlight(false)
    if (!error) {
      setSoalList(prev => prev.map(s => s.id === highlightPopover.soalId ? { ...s, highlights: updated } : s))
      setHighlightPopover(null)
      window.getSelection()?.removeAllRanges()
    }
  }

  const handleDeleteHighlight = async (soalId: string, highlightId: string) => {
    const soal = soalList.find(s => s.id === soalId)
    if (!soal) return
    const updated = (soal.highlights || []).filter((h: HighlightItem) => h.id !== highlightId)
    const { error } = await supabase.from("bank_soal").update({ highlights: updated }).eq("id", soalId)
    if (!error) setSoalList(prev => prev.map(s => s.id === soalId ? { ...s, highlights: updated } : s))
  }

  if (loading) {
    return (
      <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh" }} className="flex items-center justify-center">
        <div className="font-display text-xl" style={{ color: "var(--pp-ink-2)" }}>Memuat...</div>
      </div>
    )
  }

  const availableGuru = [...new Map(
    soalList.map(s => [s.guru_id, guruMap[s.guru_id]?.nama || s.guru_id])
  ).entries()] as [string, string][]

  // Filter kelas tidak lagi diperlukan: memilih ujian sudah menetapkan kelasnya
  const filteredSoal = soalList
    .filter(s => !filterStatusValidasi || s.status === filterStatusValidasi)

  return (
    <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh" }}>
      {/* Header */}
      <header
        className="sticky top-0 z-10"
        style={{ backgroundColor: "var(--pp-card)", borderBottom: "1.5px solid var(--pp-ink)" }}
      >
        <div className="max-w-6xl mx-auto px-4 py-3 flex items-center justify-between gap-3">
          {/* Brand + breadcrumb */}
          <div className="flex items-center gap-3 min-w-0">
            <div style={{
              width: 40, height: 40, flexShrink: 0,
              backgroundColor: "var(--pp-primary)",
              border: "1.5px dashed rgba(255,255,255,0.45)",
              borderRadius: 12,
              boxShadow: "2px 2px 0 0 var(--pp-ink)",
              display: "flex", alignItems: "center", justifyContent: "center",
            }}>
              <span className="font-display font-bold text-sm text-white">V</span>
            </div>
            <div className="flex items-center gap-2 min-w-0">
              <span className="font-display font-semibold text-base" style={{ color: "var(--pp-ink)" }}>
                Validasi Soal
              </span>
              {selectedUjian && (
                <>
                  <span style={{ color: "var(--pp-line)", fontSize: 18 }}>/</span>
                  <span
                    className="text-sm font-medium truncate"
                    style={{ color: "var(--pp-muted)" }}
                  >
                    {labelUjian({ mapel_nama: selectedUjian.nama, level: selectedUjian.level })}
                  </span>
                </>
              )}
            </div>
          </div>
          <ThemeToggle />
        </div>
      </header>

      {/* Back link */}
      <div className="max-w-6xl mx-auto px-4 pt-4 pb-1">
        <button
          onClick={() => router.push("/dashboard")}
          className="flex items-center gap-1.5 text-sm hover:opacity-70 transition-opacity"
          style={{ color: "var(--pp-muted)" }}
        >
          <ArrowLeft className="w-4 h-4" />
          Kembali ke Dashboard
        </button>
      </div>

      <main className="max-w-6xl mx-auto px-4 py-4 pb-12 space-y-6">

        {/* Mapel grid */}
        <div>
          <div className="text-xs font-bold uppercase mb-3" style={{ color: "var(--pp-muted)", letterSpacing: "0.12em" }}>
            Pilih Mata Pelajaran
          </div>

          {validatorMapelIds !== null && validatorMapelIds.length === 0 ? (
            <div
              style={{
                border: "1.5px dashed var(--pp-ink)",
                borderRadius: 22,
                padding: "48px 24px",
                textAlign: "center",
                color: "var(--pp-muted)",
              }}
            >
              Belum ada mata pelajaran yang ditugaskan. Hubungi admin.
            </div>
          ) : ujianSummaries.length === 0 ? (
            <div
              style={{
                border: "1.5px dashed var(--pp-ink)",
                borderRadius: 22,
                padding: "48px 24px",
                textAlign: "center",
                color: "var(--pp-muted)",
              }}
            >
              Belum ada soal yang disubmit.
            </div>
          ) : (
            <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-3">
              {ujianSummaries.map(m => {
                const isActive = selectedUjian?.id === m.id
                const hasPending = m.submitted + m.needs_revision > 0
                const allApproved = m.approved > 0 && m.submitted === 0 && m.needs_revision === 0

                let cardBg = "var(--pp-card)"
                if (isActive) cardBg = "var(--pp-lemon)"
                else if (hasPending) cardBg = "#FFF0E6"
                else if (allApproved) cardBg = "#EDFAF3"

                return (
                  <button
                    key={m.id}
                    onClick={() => openUjian(m)}
                    className="text-left"
                    style={{
                      backgroundColor: cardBg,
                      border: "1.5px solid var(--pp-ink)",
                      borderRadius: 18,
                      padding: "14px 16px",
                      boxShadow: isActive ? "none" : "3px 3px 0 0 var(--pp-ink)",
                      transform: isActive ? "translate(2px,2px)" : "none",
                      transition: "all 100ms",
                      cursor: "pointer",
                    }}
                  >
                    <div className="flex items-start justify-between gap-1 mb-2.5">
                      <span className="text-sm font-semibold leading-snug" style={{ color: "var(--pp-ink)" }}>
                        {m.nama}
                      </span>
                      {m.level && (
                        <span
                          className="text-xs px-1.5 py-0.5 rounded-full shrink-0 font-medium"
                          style={{ backgroundColor: "var(--pp-bg)", color: "var(--pp-muted)", border: "1px solid var(--pp-line)" }}
                        >
                          Kelas {m.level}
                        </span>
                      )}
                    </div>
                    <div className="flex flex-wrap gap-1.5">
                      {m.submitted > 0 && (
                        <button
                          onClick={e => { e.stopPropagation(); openUjian(m, "submitted") }}
                          className="flex items-center gap-1 text-xs font-semibold px-2 py-0.5 rounded-full"
                          style={{ backgroundColor: "var(--pp-lemon)", color: "#92400e", border: "1px solid var(--pp-ink)", cursor: "pointer" }}
                        >
                          <Clock className="w-3 h-3" /> {m.submitted}
                        </button>
                      )}
                      {m.needs_revision > 0 && (
                        <button
                          onClick={e => { e.stopPropagation(); openUjian(m, "needs_revision") }}
                          className="flex items-center gap-1 text-xs font-semibold px-2 py-0.5 rounded-full"
                          style={{ backgroundColor: "var(--pp-pink)", color: "#be123c", border: "1px solid var(--pp-ink)", cursor: "pointer" }}
                        >
                          <AlertCircle className="w-3 h-3" /> {m.needs_revision}
                        </button>
                      )}
                      {m.approved > 0 && (
                        <button
                          onClick={e => { e.stopPropagation(); openUjian(m, "approved") }}
                          className="flex items-center gap-1 text-xs font-semibold px-2 py-0.5 rounded-full"
                          style={{ backgroundColor: "var(--pp-mint)", color: "#15803d", border: "1px solid var(--pp-ink)", cursor: "pointer" }}
                        >
                          <CheckCircle className="w-3 h-3" /> {m.approved}
                        </button>
                      )}
                    </div>
                  </button>
                )
              })}
            </div>
          )}
        </div>

        {/* Soal list */}
        {selectedUjian && (
          <div
            style={{
              backgroundColor: "var(--pp-card)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 22,
              boxShadow: "6px 6px 0 0 var(--pp-ink)",
              overflow: "hidden",
            }}
          >
            {/* List header */}
            <div
              style={{
                backgroundColor: "var(--pp-lemon)",
                borderBottom: "1.5px solid var(--pp-ink)",
                padding: "14px 20px",
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
                flexWrap: "wrap",
                gap: 10,
              }}
            >
              <div>
                <div className="text-xs font-bold uppercase" style={{ color: "var(--pp-muted)", letterSpacing: "0.1em" }}>
                  Daftar Soal
                </div>
                <div className="font-display font-semibold text-lg" style={{ color: "var(--pp-ink)" }}>
                  {selectedUjian.nama}
                </div>
              </div>
              <div className="flex items-center gap-2 flex-wrap">
                {selectedUjian.submitted > 0 && (
                  <span className="flex items-center gap-1 text-xs font-semibold px-2.5 py-1 rounded-full"
                    style={{ backgroundColor: "var(--pp-lemon)", color: "#92400e", border: "1.5px solid var(--pp-ink)" }}>
                    <Clock className="w-3.5 h-3.5" /> {selectedUjian.submitted} menunggu
                  </span>
                )}
                {selectedUjian.needs_revision > 0 && (
                  <span className="flex items-center gap-1 text-xs font-semibold px-2.5 py-1 rounded-full"
                    style={{ backgroundColor: "var(--pp-pink)", color: "#be123c", border: "1.5px solid var(--pp-ink)" }}>
                    <AlertCircle className="w-3.5 h-3.5" /> {selectedUjian.needs_revision} revisi
                  </span>
                )}
                {selectedUjian.approved > 0 && (
                  <span className="flex items-center gap-1 text-xs font-semibold px-2.5 py-1 rounded-full"
                    style={{ backgroundColor: "var(--pp-mint)", color: "#15803d", border: "1.5px solid var(--pp-ink)" }}>
                    <CheckCircle className="w-3.5 h-3.5" /> {selectedUjian.approved} approved
                  </span>
                )}
                {!loadingSoal && soalList.length > 0 && (
                  <DownloadDropdown
                    soalList={soalList}
                    filename={`soal-${selectedUjian.nama}`}
                    meta={{ judul: `Soal ${selectedUjian.nama}`, tanggal: new Date().toISOString() }}
                  />
                )}
              </div>

              {/* Filter status */}
              {!loadingSoal && soalList.length > 0 && (
                <div
                  style={{
                    borderTop: "1.5px solid var(--pp-ink)",
                    backgroundColor: "var(--pp-bg)",
                    padding: "10px 20px",
                    display: "flex",
                    alignItems: "center",
                    flexWrap: "wrap",
                    gap: 6,
                  }}
                >
                  {(() => {
                    const countByStatus = {
                      submitted: soalList.filter(s => s.status === "submitted").length,
                      needs_revision: soalList.filter(s => s.status === "needs_revision").length,
                      approved: soalList.filter(s => s.status === "approved").length,
                    }
                    const pills = [
                      { key: "submitted",      label: "Dikirim", bg: "var(--pp-lemon)", activeBg: "#92400e", color: "#92400e", activeColor: "#fff" },
                      { key: "needs_revision", label: "Revisi",  bg: "var(--pp-pink)",  activeBg: "#be123c", color: "#be123c", activeColor: "#fff" },
                      { key: "approved",       label: "Approved", bg: "var(--pp-mint)",  activeBg: "#15803d", color: "#15803d", activeColor: "#fff" },
                    ]
                    return pills.map(pill => {
                      const count = countByStatus[pill.key as keyof typeof countByStatus]
                      if (!count) return null
                      const active = filterStatusValidasi === pill.key
                      return (
                        <button
                          key={pill.key}
                          onClick={() => setFilterStatusValidasi(active ? null : pill.key)}
                          className="text-xs px-2.5 py-1 rounded-full font-semibold transition-all flex items-center gap-1"
                          style={{
                            backgroundColor: active ? pill.activeBg : pill.bg,
                            color: active ? pill.activeColor : pill.color,
                            border: `1.5px solid ${active ? pill.activeBg : "var(--pp-line)"}`,
                            cursor: "pointer",
                          }}
                        >
                          {pill.label} ({count})
                        </button>
                      )
                    })
                  })()}

                  {filterStatusValidasi && (
                    <>
                      <button
                        onClick={() => setFilterStatusValidasi(null)}
                        className="text-xs px-2.5 py-1 rounded-full transition-all"
                        style={{
                          backgroundColor: "var(--pp-bg)",
                          color: "var(--pp-muted)",
                          border: "1.5px solid var(--pp-line)",
                          cursor: "pointer",
                        }}
                      >
                        × Reset
                      </button>
                      <span className="text-xs ml-auto" style={{ color: "var(--pp-muted)" }}>
                        {filteredSoal.length} / {soalList.length} soal
                      </span>
                    </>
                  )}
                </div>
              )}
            </div>

            {loadingSoal ? (
              <div className="p-10 text-center" style={{ color: "var(--pp-muted)" }}>
                Memuat soal...
              </div>
            ) : soalList.length === 0 ? (
              <div className="p-10 text-center" style={{ color: "var(--pp-muted)" }}>
                Belum ada soal untuk mata pelajaran ini.
              </div>
            ) : filteredSoal.length === 0 ? (
              <div className="p-10 text-center" style={{ color: "var(--pp-muted)" }}>
                Tidak ada soal yang cocok dengan filter.
              </div>
            ) : (
              <div>
                {filteredSoal.map((soal, index) => {
                  const tipeColor = TIPE_COLORS[soal.tipe] || TIPE_COLORS["pilgan"]
                  const kesColor = KESULITAN_COLORS[soal.tingkat_kesulitan] || KESULITAN_COLORS["mudah"]

                  const statusStyle =
                    soal.status === "approved"      ? { bg: "var(--pp-mint)",  text: "#15803d",  label: "Approved" } :
                    soal.status === "needs_revision" ? { bg: "var(--pp-pink)",  text: "#be123c",  label: "Revisi" } :
                                                       { bg: "var(--pp-lemon)", text: "#92400e",  label: "Dikirim" }

                  const rowBg = index % 2 === 0 ? "var(--pp-card)" : "var(--pp-bg)"

                  return (
                    <div
                      key={soal.id}
                      style={{
                        borderTop: index > 0 ? "1.5px solid var(--pp-line)" : "none",
                        padding: "20px 24px",
                        backgroundColor: rowBg,
                      }}
                    >
                      {/* Top row: pills + status */}
                      <div className="flex items-start justify-between gap-3 mb-3 flex-wrap">
                        <div className="flex items-center gap-1.5 flex-wrap">
                          {/* Number badge */}
                          <span
                            className="w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold font-display shrink-0"
                            style={{
                              backgroundColor: "var(--pp-lemon)",
                              color: "var(--pp-ink)",
                              border: "1.5px solid var(--pp-ink)",
                            }}
                          >
                            {index + 1}
                          </span>
                          <span
                            className="text-xs px-2 py-0.5 rounded-full font-semibold"
                            style={{ backgroundColor: tipeColor.bg, color: tipeColor.accent, border: "1px solid var(--pp-ink)" }}
                          >
                            {TIPE_LABELS[soal.tipe] || soal.tipe}
                          </span>
                          <span
                            className="text-xs px-2 py-0.5 rounded-full font-semibold capitalize"
                            style={{ backgroundColor: kesColor.bg, color: kesColor.text, border: "1px solid var(--pp-ink)" }}
                          >
                            {soal.tingkat_kesulitan}
                          </span>
                          <span
                            className="text-xs px-2 py-0.5 rounded-full font-medium"
                            style={{ backgroundColor: "var(--pp-bg)", color: "var(--pp-ink-2)", border: "1px solid var(--pp-line)" }}
                          >
                            {soal.bab_id_text}
                          </span>
                          <span
                            className="text-xs px-2 py-0.5 rounded-full"
                            style={{ backgroundColor: "var(--pp-bg)", color: "var(--pp-muted)", border: "1px solid var(--pp-line)" }}
                          >
                            Bobot: {soal.bobot}
                          </span>
                          {guruMap[soal.guru_id] && (
                            <span
                              className="text-xs px-2 py-0.5 rounded-full font-semibold"
                              style={{ backgroundColor: "var(--pp-peach)", color: "var(--pp-ink)", border: "1px solid var(--pp-ink)" }}
                            >
                              {selectedUjian?.level ? `Kelas ${selectedUjian.level} · ` : ""}{guruMap[soal.guru_id].nama}
                            </span>
                          )}
                        </div>
                        <span
                          className="text-xs px-2.5 py-1 rounded-full font-semibold shrink-0"
                          style={{
                            backgroundColor: statusStyle.bg,
                            color: statusStyle.text,
                            border: "1.5px solid var(--pp-ink)",
                          }}
                        >
                          {statusStyle.label}
                        </span>
                      </div>

                      {/* Pertanyaan */}
                      <div
                        className="text-sm rich-html mb-3 select-text"
                        style={{ color: "var(--pp-ink)", paddingLeft: 4, cursor: "text" }}
                        onMouseUp={handleTextSelect(soal.id, "pertanyaan")}
                        dangerouslySetInnerHTML={{ __html: applyHighlights(soal.pertanyaan, soal.highlights || [], "pertanyaan") }}
                      />

                      {/* Pilihan */}
                      {soal.pilihan && soal.pilihan.length > 0 && (
                        <div className="mb-3 space-y-1.5 pl-1">
                          {soal.pilihan.map((p: any, i: number) => {
                            const gambarUrl = soal.pilihan_gambar?.[p.id ?? i] || ""
                            const field = `pilihan_${i}`
                            return (
                            <div
                              key={i}
                              className="flex items-start gap-2 text-xs rounded-lg px-2.5 py-1.5 select-text"
                              style={{
                                backgroundColor: p.benar ? "#f0fdf4" : "var(--pp-bg)",
                                border: `1px solid ${p.benar ? "#86efac" : "var(--pp-line)"}`,
                                cursor: "text",
                              }}
                            >
                              <span
                                className="font-bold shrink-0 mt-0.5"
                                style={{ color: p.benar ? "#15803d" : "var(--pp-muted)" }}
                              >
                                {String.fromCharCode(65 + i)}.
                              </span>
                              <div className="flex-1 min-w-0" onMouseUp={handleTextSelect(soal.id, field)}>
                                {p.teks && (
                                  <span
                                    className="rich-html"
                                    style={{ color: p.benar ? "#15803d" : "var(--pp-ink)" }}
                                    dangerouslySetInnerHTML={{ __html: applyHighlights(p.teks, soal.highlights || [], field) }}
                                  />
                                )}
                                {gambarUrl && (
                                  <img
                                    src={gambarUrl}
                                    alt={`Pilihan ${String.fromCharCode(65 + i)}`}
                                    style={{ maxWidth: 180, maxHeight: 110, marginTop: p.teks ? 4 : 0, borderRadius: 6, objectFit: "contain", display: "block" }}
                                  />
                                )}
                              </div>
                              {p.benar && (
                                <span
                                  className="text-xs px-1.5 py-0.5 rounded-full font-semibold shrink-0"
                                  style={{ backgroundColor: "var(--pp-mint)", color: "#15803d" }}
                                >
                                  Benar
                                </span>
                              )}
                            </div>
                          )})}
                        </div>
                      )}

                      {/* Highlights list */}
                      {soal.highlights && soal.highlights.length > 0 && (
                        <div className="mb-3 pl-1">
                          <div className="text-xs font-medium mb-1.5 flex items-center gap-1" style={{ color: "var(--pp-muted)" }}>
                            <Highlighter className="w-3 h-3" />
                            Teks ditandai ({soal.highlights.length})
                          </div>
                          <div className="flex flex-wrap gap-1.5">
                            {soal.highlights.map((h: HighlightItem) => (
                              <div
                                key={h.id}
                                className="flex items-center gap-1.5 text-xs px-2 py-0.5 rounded-full"
                                style={{
                                  backgroundColor: h.color === "red" ? "#fecaca" : "#fef08a",
                                  border: "1px solid var(--pp-ink)",
                                  color: "var(--pp-ink)",
                                }}
                                title={h.note || undefined}
                              >
                                <span>"{h.text.length > 30 ? h.text.slice(0, 30) + "…" : h.text}"</span>
                                {h.note && (
                                  <span style={{ color: "var(--pp-muted)" }}>
                                    — {h.note.length > 20 ? h.note.slice(0, 20) + "…" : h.note}
                                  </span>
                                )}
                                <button
                                  onClick={() => handleDeleteHighlight(soal.id, h.id)}
                                  style={{ lineHeight: 1, padding: 1, borderRadius: "50%", backgroundColor: "transparent", cursor: "pointer", border: "none" }}
                                >
                                  <X className="w-3 h-3" />
                                </button>
                              </div>
                            ))}
                          </div>
                        </div>
                      )}

                      {/* Catatan revisi sebelumnya */}
                      {soal.revision_notes && (() => {
                        const lastIndex = (soal.revision_history?.length ?? 1) - 1
                        const isEditing = editingNote?.soalId === soal.id && editingNote?.index === lastIndex
                        const parsedText = getRevisionNotes(soal.revision_notes)
                        const validatorName = soal.revision_notes.match(/^\[([^\]]+)\]/)?.[1] || "Validator"
                        return (
                          <div className="mb-3 pl-1">
                            {isEditing ? (
                              <div className="flex gap-2 items-start">
                                <textarea
                                  rows={2}
                                  className="flex-1 text-xs resize-none"
                                  style={{ border: "1.5px solid var(--pp-primary)", borderRadius: 8, padding: "6px 10px", backgroundColor: "var(--pp-card)", color: "var(--pp-ink)", outline: "none" }}
                                  value={editingNote!.text}
                                  onChange={e => setEditingNote(prev => prev ? { ...prev, text: e.target.value } : prev)}
                                />
                                <button onClick={() => handleEditNote(soal.id, lastIndex, editingNote!.text)} disabled={saving}
                                  style={{ padding: "5px 8px", borderRadius: 8, border: "1.5px solid var(--pp-ink)", backgroundColor: "var(--pp-mint)", color: "#15803d" }}>
                                  <Check className="w-3.5 h-3.5" />
                                </button>
                                <button onClick={() => setEditingNote(null)}
                                  style={{ padding: "5px 8px", borderRadius: 8, border: "1.5px solid var(--pp-ink)", backgroundColor: "var(--pp-bg)", color: "var(--pp-muted)" }}>
                                  <X className="w-3.5 h-3.5" />
                                </button>
                              </div>
                            ) : (
                              <div className="flex items-start justify-between gap-2 px-3 py-2 rounded-lg text-xs"
                                style={{ backgroundColor: soal.status === "approved" ? "#f0fdf4" : "#fff0f5", border: `1px solid ${soal.status === "approved" ? "#86efac" : "var(--pp-pink)"}`, color: soal.status === "approved" ? "#15803d" : "#be123c" }}>
                                <span><span className="font-semibold">{validatorName}:</span> {parsedText}</span>
                                <div className="flex gap-1 shrink-0">
                                  <button onClick={() => setEditingNote({ soalId: soal.id, index: lastIndex, text: parsedText })}
                                    style={{ padding: "2px 6px", borderRadius: 6, border: "1.5px solid currentColor", backgroundColor: "transparent", opacity: 0.7 }}>
                                    <Pencil className="w-3 h-3" />
                                  </button>
                                  <button onClick={() => handleDeleteNote(soal.id, lastIndex)} disabled={saving}
                                    style={{ padding: "2px 6px", borderRadius: 6, border: "1.5px solid currentColor", backgroundColor: "transparent", opacity: 0.7 }}>
                                    <Trash2 className="w-3 h-3" />
                                  </button>
                                </div>
                              </div>
                            )}
                          </div>
                        )
                      })()}

                      {/* History */}
                      {soal.revision_history && soal.revision_history.length > 0 && (
                        <details className="mb-3 pl-1">
                          <summary
                            className="text-xs cursor-pointer font-medium"
                            style={{ color: "var(--pp-muted)" }}
                          >
                            Riwayat ({soal.revision_history.length} catatan)
                          </summary>
                          <div className="mt-2 space-y-1">
                            {soal.revision_history.map((h: string, i: number) => {
                              const isEditing = editingNote?.soalId === soal.id && editingNote?.index === i
                              const hText = getRevisionNotes(h)
                              const hValidator = h.match(/^\[([^\]]+)\]/)?.[1] || "Validator"
                              return (
                                <div
                                  key={i}
                                  className="text-xs px-2.5 py-1.5 rounded-lg flex items-start justify-between gap-2"
                                  style={{ backgroundColor: "var(--pp-bg)", border: "1px solid var(--pp-line)", color: "var(--pp-ink-2)" }}
                                >
                                  {isEditing ? (
                                    <div className="flex gap-2 items-start flex-1">
                                      <textarea
                                        rows={2}
                                        className="flex-1 text-xs resize-none"
                                        style={{ border: "1.5px solid var(--pp-primary)", borderRadius: 8, padding: "4px 8px", backgroundColor: "var(--pp-card)", color: "var(--pp-ink)", outline: "none" }}
                                        value={editingNote!.text}
                                        onChange={e => setEditingNote(prev => prev ? { ...prev, text: e.target.value } : prev)}
                                      />
                                      <button onClick={() => handleEditNote(soal.id, i, editingNote!.text)} disabled={saving}
                                        style={{ padding: "4px 6px", borderRadius: 6, border: "1.5px solid var(--pp-ink)", backgroundColor: "var(--pp-mint)", color: "#15803d" }}>
                                        <Check className="w-3 h-3" />
                                      </button>
                                      <button onClick={() => setEditingNote(null)}
                                        style={{ padding: "4px 6px", borderRadius: 6, border: "1.5px solid var(--pp-ink)", backgroundColor: "var(--pp-bg)", color: "var(--pp-muted)" }}>
                                        <X className="w-3 h-3" />
                                      </button>
                                    </div>
                                  ) : (
                                    <>
                                      <span><span className="font-semibold">{hValidator}:</span> {hText}</span>
                                      <div className="flex gap-1 shrink-0">
                                        <button onClick={() => setEditingNote({ soalId: soal.id, index: i, text: hText })}
                                          style={{ padding: "2px 5px", borderRadius: 5, border: "1px solid var(--pp-line)", backgroundColor: "transparent" }}>
                                          <Pencil className="w-3 h-3" />
                                        </button>
                                        <button onClick={() => handleDeleteNote(soal.id, i)} disabled={saving}
                                          style={{ padding: "2px 5px", borderRadius: 5, border: "1px solid var(--pp-line)", backgroundColor: "transparent" }}>
                                          <Trash2 className="w-3 h-3" />
                                        </button>
                                      </div>
                                    </>
                                  )}
                                </div>
                              )
                            })}
                          </div>
                        </details>
                      )}

                      {/* Action area */}
                      <div className="flex gap-3 items-start pl-1">
                        <textarea
                          value={revisionNotes[soal.id] ?? ""}
                          onChange={e => setRevisionNotes(prev => ({ ...prev, [soal.id]: e.target.value }))}
                          placeholder="Catatan revisi (opsional untuk approve)..."
                          rows={2}
                          className="flex-1 text-sm resize-none"
                          style={{
                            border: "1.5px solid var(--pp-ink)",
                            borderRadius: 10,
                            padding: "8px 12px",
                            backgroundColor: "var(--pp-card)",
                            color: "var(--pp-ink)",
                            outline: "none",
                          }}
                          onFocus={e => { e.target.style.borderColor = "var(--pp-primary)"; e.target.style.boxShadow = "2px 2px 0 0 var(--pp-primary)" }}
                          onBlur={e => { e.target.style.borderColor = "var(--pp-ink)"; e.target.style.boxShadow = "none" }}
                        />
                        <div className="flex flex-col gap-2 shrink-0">
                          <button
                            onClick={() => handleStatusChange(soal.id, "needs_revision")}
                            disabled={saving}
                            style={{
                              backgroundColor: "var(--pp-pink)",
                              color: "var(--pp-ink)",
                              border: "1.5px solid var(--pp-ink)",
                              borderRadius: 10,
                              padding: "8px 14px",
                              fontSize: 13,
                              fontWeight: 600,
                              boxShadow: "2px 2px 0 0 var(--pp-ink)",
                              cursor: saving ? "not-allowed" : "pointer",
                              opacity: saving ? 0.6 : 1,
                              display: "flex", alignItems: "center", gap: 5,
                            }}
                          >
                            <AlertCircle className="w-3.5 h-3.5" />
                            Revisi
                          </button>
                          <button
                            onClick={() => handleStatusChange(soal.id, "approved")}
                            disabled={saving}
                            style={{
                              backgroundColor: "var(--pp-mint)",
                              color: "var(--pp-ink)",
                              border: "1.5px solid var(--pp-ink)",
                              borderRadius: 10,
                              padding: "8px 14px",
                              fontSize: 13,
                              fontWeight: 600,
                              boxShadow: "2px 2px 0 0 var(--pp-ink)",
                              cursor: saving ? "not-allowed" : "pointer",
                              opacity: saving ? 0.6 : 1,
                              display: "flex", alignItems: "center", gap: 5,
                            }}
                          >
                            <CheckCircle className="w-3.5 h-3.5" />
                            Approve
                          </button>
                        </div>
                      </div>

                      {/* Tanggal */}
                      <div className="mt-2 pl-1 text-xs" style={{ color: "var(--pp-muted)" }}>
                        {new Date(soal.created_at).toLocaleDateString("id-ID", { day: "numeric", month: "long", year: "numeric" })}
                      </div>
                    </div>
                  )
                })}
              </div>
            )}
          </div>
        )}
      </main>

      {/* Highlight popover */}
      {highlightPopover && (
        <div
          style={{
            position: "fixed",
            left: highlightPopover.x,
            top: highlightPopover.y,
            transform: "translateX(-50%)",
            zIndex: 9999,
            backgroundColor: "var(--pp-card)",
            border: "1.5px solid var(--pp-ink)",
            borderRadius: 14,
            padding: "12px 14px",
            boxShadow: "4px 4px 0 0 var(--pp-ink)",
            minWidth: 220,
            maxWidth: 300,
          }}
        >
          <div className="text-xs font-semibold mb-2" style={{ color: "var(--pp-muted)" }}>
            Highlight teks:
          </div>
          <div
            className="text-xs mb-3 px-2 py-1 rounded"
            style={{ backgroundColor: "#fef9c3", color: "var(--pp-ink)", border: "1px solid var(--pp-line)", maxHeight: 48, overflow: "hidden" }}
          >
            "{highlightPopover.text.length > 60 ? highlightPopover.text.slice(0, 60) + "…" : highlightPopover.text}"
          </div>
          <div className="flex items-center gap-2 mb-3">
            <span className="text-xs" style={{ color: "var(--pp-muted)" }}>Warna:</span>
            <button
              onClick={() => setHighlightColor("yellow")}
              style={{
                width: 22, height: 22, borderRadius: "50%",
                backgroundColor: "#fef08a",
                border: highlightColor === "yellow" ? "2.5px solid var(--pp-ink)" : "2px solid var(--pp-line)",
                boxShadow: highlightColor === "yellow" ? "1px 1px 0 0 var(--pp-ink)" : "none",
                cursor: "pointer",
              }}
            />
            <button
              onClick={() => setHighlightColor("red")}
              style={{
                width: 22, height: 22, borderRadius: "50%",
                backgroundColor: "#fecaca",
                border: highlightColor === "red" ? "2.5px solid var(--pp-ink)" : "2px solid var(--pp-line)",
                boxShadow: highlightColor === "red" ? "1px 1px 0 0 var(--pp-ink)" : "none",
                cursor: "pointer",
              }}
            />
            <span className="text-xs" style={{ color: "var(--pp-muted)" }}>
              {highlightColor === "yellow" ? "Kuning" : "Merah"}
            </span>
          </div>
          <textarea
            value={highlightNote}
            onChange={e => setHighlightNote(e.target.value)}
            placeholder="Catatan (opsional)..."
            rows={2}
            className="w-full text-xs resize-none mb-3"
            style={{
              border: "1.5px solid var(--pp-line)",
              borderRadius: 8,
              padding: "6px 8px",
              backgroundColor: "var(--pp-bg)",
              color: "var(--pp-ink)",
              outline: "none",
              display: "block",
            }}
          />
          <div className="flex gap-2">
            <button
              onClick={handleSaveHighlight}
              disabled={savingHighlight}
              className="flex-1 text-xs font-semibold py-1.5 rounded-lg flex items-center justify-center gap-1"
              style={{
                backgroundColor: "var(--pp-primary)",
                color: "#fff",
                border: "1.5px solid var(--pp-ink)",
                boxShadow: "2px 2px 0 0 var(--pp-ink)",
                cursor: savingHighlight ? "not-allowed" : "pointer",
                opacity: savingHighlight ? 0.6 : 1,
              }}
            >
              <Highlighter className="w-3 h-3" />
              Simpan
            </button>
            <button
              onClick={() => { setHighlightPopover(null); window.getSelection()?.removeAllRanges() }}
              className="text-xs px-3 py-1.5 rounded-lg"
              style={{
                backgroundColor: "var(--pp-bg)",
                color: "var(--pp-muted)",
                border: "1.5px solid var(--pp-line)",
                cursor: "pointer",
              }}
            >
              Batal
            </button>
          </div>
        </div>
      )}

      {toast && <Toast message={toast.message} type={toast.type} onClose={() => setToast(null)} />}
    </div>
  )
}
