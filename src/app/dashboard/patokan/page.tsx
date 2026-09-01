"use client"

import React, { useEffect, useState } from "react"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabase"
import { Copy, ArrowLeft, Save, RotateCcw, Inbox } from "lucide-react"
import ThemeToggle from "@/components/ThemeToggle"
import Toast from "@/components/Toast"
import {
  TIPE_OPTIONS,
  KESULITAN_OPTIONS,
  TIPE_LABELS,
  KESULITAN_LABELS,
  TIPE_COLORS,
  BOBOT_DEFAULT,
  gridKosong,
  labelUjian,
  ambilUjianAktif,
  ambilCalonPenulis,
  tetapkanPenulis,
  simpanPatokanUjian,
  validasiGridTarget,
  pesanError,
  type UjianAktif,
  type PatokanUjianRow,
  type CalonPenulis,
} from "@/lib/ujian"

interface MataPelajaran {
  id: string
  nama: string
  kode: string | null
}

// TIPE_COLORS & BOBOT_DEFAULT dipakai dari lib/ujian.

type PatokanMap = Record<string, Record<string, number>>
type BobotMap = Record<string, Record<string, number>>

const buildEmpty = gridKosong

function buildEmptyBobot(): Record<string, number> {
  const b: Record<string, number> = {}
  TIPE_OPTIONS.forEach(t => KESULITAN_OPTIONS.forEach(k => {
    b[`${t}_${k}`] = BOBOT_DEFAULT[t]?.[k] ?? 1.0
  }))
  return b
}

export default function AdminPage() {
  const router = useRouter()
  const [user, setUser] = useState<any>(null)
  const [mataPelajaran, setMataPelajaran] = useState<MataPelajaran[]>([])
  const [loading, setLoading] = useState(true)
  const [toast, setToast] = useState<{ message: string; type: "success" | "error" } | null>(null)
  const [activeTab, setActiveTab] = useState<"patokan" | "bobot">("patokan")

  // Target dipetakan per ujian (mapel × kelas), bukan lagi per mapel
  const [ujianList, setUjianList] = useState<UjianAktif[]>([])
  const [patokanMap, setPatokanMap] = useState<PatokanMap>({})
  const [saving, setSaving] = useState(false)
  const [savePressed, setSavePressed] = useState(false)
  /** Calon penulis + penunjukan yang berlaku, per ujian. */
  const [calonPenulis, setCalonPenulis] = useState<Record<string, CalonPenulis[]>>({})
  const [menyimpanPenulis, setMenyimpanPenulis] = useState<string | null>(null)

  const [bobotMap, setBobotMap] = useState<BobotMap>({})
  const [customBobotMapels, setCustomBobotMapels] = useState<Set<string>>(new Set())
  const [selectedBobotMapel, setSelectedBobotMapel] = useState("")
  const [savingBobot, setSavingBobot] = useState(false)
  const [showCopyModal, setShowCopyModal] = useState(false)
  const [copyTargets, setCopyTargets] = useState<Set<string>>(new Set())
  const [copyingBobot, setCopyingBobot] = useState(false)

  /** Ujian yang matriksnya sudah disubmit guru. Menimpa pagunya membatalkan
   *  invarian Σ per bab = pagu tanpa gurunya tahu, jadi harus dikonfirmasi. */
  const [matriksTerkunci, setMatriksTerkunci] = useState<Set<string>>(new Set())
  /** Ujian yang panel "salin pagu ke…"-nya sedang terbuka, dan tujuannya. */
  const [salinDari, setSalinDari] = useState<string | null>(null)
  const [salinKe, setSalinKe] = useState<Set<string>>(new Set())

  /** Muat calon penulis tiap ujian sekali daftar ujian siap. */
  const muatCalonPenulis = async (daftar: UjianAktif[]) => {
    const hasil: Record<string, CalonPenulis[]> = {}
    await Promise.all(daftar.map(async u => {
      try { hasil[u.ujian_id] = await ambilCalonPenulis(u.ujian_id) } catch { hasil[u.ujian_id] = [] }
    }))
    setCalonPenulis(hasil)
  }

  const ubahPenulis = async (ujianId: string, profileId: string) => {
    setMenyimpanPenulis(ujianId)
    try {
      await tetapkanPenulis(ujianId, profileId || null, user?.id ?? null)
      setCalonPenulis(prev => ({
        ...prev,
        [ujianId]: (prev[ujianId] || []).map(c => ({ ...c, ditunjuk: c.profile_id === profileId })),
      }))
      setToast({ message: profileId ? "Penulis ditetapkan" : "Penunjukan dilepas", type: "success" })
    } catch (e) {
      setToast({ message: "Gagal: " + pesanError(e), type: "error" })
    } finally {
      setMenyimpanPenulis(null)
    }
  }

  useEffect(() => {
    async function load() {
      const { data: { user: u } } = await supabase.auth.getUser()
      if (!u) { router.push("/login"); return }
      setUser(u)

      const { data: mapels } = await supabase.from("mata_pelajaran").select("id, nama, kode").order("nama")
      if (!mapels) { setLoading(false); return }
      setMataPelajaran(mapels)
      if (mapels.length > 0) setSelectedBobotMapel(mapels[0].id)

      // Ujian pada siklus aktif yang soalnya ditentukan super admin
      let ujians: UjianAktif[] = []
      try {
        ujians = await ambilUjianAktif()
      } catch (e) {
        setToast({ message: "Gagal memuat daftar ujian: " + pesanError(e), type: "error" })
      }
      setUjianList(ujians)
      void muatCalonPenulis(ujians)

      const pMap: PatokanMap = {}
      ujians.forEach(u => { pMap[u.ujian_id] = buildEmpty() })

      if (ujians.length > 0) {
        const { data: patokanRows } = await supabase
          .from("psat_patokan_ujian")
          .select("ujian_id, tipe, tingkat_kesulitan, jumlah_keluar, jumlah_bank")
          .in("ujian_id", ujians.map(u => u.ujian_id))

        ;(patokanRows as (PatokanUjianRow & { ujian_id: string })[] | null)?.forEach(row => {
          const g = pMap[row.ujian_id]
          if (!g) return
          g[`${row.tipe}_${row.tingkat_kesulitan}_keluar`] = row.jumlah_keluar ?? 0
          g[`${row.tipe}_${row.tingkat_kesulitan}_bank`] = row.jumlah_bank ?? 0
        })

        // Matriks yang sudah disubmit: menyalin pagu ke sana diam-diam membuat
        // Σ per bab tidak lagi sama dengan pagu, dan gurunya tidak diberi tahu.
        const { data: submitRows } = await supabase
          .from("psat_matrix_input")
          .select("ujian_id")
          .in("ujian_id", ujians.map(u => u.ujian_id))
          .eq("is_submitted", true)
        setMatriksTerkunci(new Set((submitRows ?? []).map((r: { ujian_id: string }) => r.ujian_id)))
      }
      setPatokanMap(pMap)

      const { data: bobotRows } = await supabase.from("bobot_config").select("mapel_id, tipe, kesulitan, bobot")
      const bMap: BobotMap = {}
      const customSet = new Set<string>()
      mapels.forEach(m => { bMap[m.id] = buildEmptyBobot() })
      if (bobotRows) {
        bobotRows.forEach((row: any) => {
          if (bMap[row.mapel_id]) {
            bMap[row.mapel_id][`${row.tipe}_${row.kesulitan}`] = Number(row.bobot)
            customSet.add(row.mapel_id)
          }
        })
      }
      setBobotMap(bMap)
      setCustomBobotMapels(customSet)
      setLoading(false)
    }
    load()
  }, [router])

  const showToast = (message: string, type: "success" | "error") => {
    setToast({ message, type })
    setTimeout(() => setToast(null), 3000)
  }

  const handlePatokanChange = (ujianId: string, field: string, value: number) => {
    setPatokanMap(prev => ({ ...prev, [ujianId]: { ...prev[ujianId], [field]: value } }))
  }

  /**
   * Ujian lain dengan mata pelajaran yang sama — tingkat lain dari mapel ini.
   * Dengan 3 level per mapel, mengetik ulang 15 sel untuk tiap tingkat berarti
   * ratusan angka; hampir selalu tingkat 8 dan 9 memakai pagu yang sama dengan 7.
   */
  const tujuanSalin = (sumber: UjianAktif) =>
    ujianList.filter(u => u.ujian_id !== sumber.ujian_id && u.mapel_id === sumber.mapel_id)

  const bukaSalin = (ujianId: string) => {
    setSalinDari(prev => (prev === ujianId ? null : ujianId))
    setSalinKe(new Set())
  }

  /**
   * Salin grid ke ujian lain — murni operasi state.
   *
   * Halaman ini menahan SEMUA grid di satu `patokanMap` dan menyimpannya sekali
   * lewat tombol "Simpan", jadi menyalin tidak perlu menyentuh basis data sama
   * sekali. Hasilnya juga bisa disunting dulu sebelum disimpan, dan dibatalkan
   * cukup dengan memuat ulang halaman tanpa menekan Simpan.
   */
  const terapkanSalin = (sumber: UjianAktif) => {
    if (salinKe.size === 0) return

    const terkunci = Array.from(salinKe).filter(id => matriksTerkunci.has(id))
    if (terkunci.length > 0) {
      const nama = terkunci
        .map(id => {
          const u = ujianList.find(x => x.ujian_id === id)
          return u ? `${u.mapel_nama ?? u.ujian_nama}${u.level ? ` kelas ${u.level}` : ""}` : id
        })
        .join(", ")
      if (!confirm(
        `Matriks ${nama} sudah disubmit guru. Mengubah pagunya membuat pembagian per bab ` +
        `tidak lagi sama dengan pagu, dan matriks itu akan ditolak saat dikirim ke LMS ` +
        `sampai gurunya membagi ulang.\n\nTetap salin?`
      )) return
    }

    const grid = patokanMap[sumber.ujian_id] || buildEmpty()
    setPatokanMap(prev => {
      const next = { ...prev }
      salinKe.forEach(id => { next[id] = { ...grid } })
      return next
    })
    setSalinDari(null)
    setSalinKe(new Set())
    showToast(`Pagu disalin ke ${salinKe.size} ujian — tekan Simpan untuk menerapkannya`, "success")
  }

  const handleSavePatokan = async () => {
    if (!user) return

    // Database menolak keluar > bank lewat CHECK; tangkap di sini supaya
    // pesannya menyebut sel mana yang salah, bukan sekadar constraint violation.
    const salah = ujianList.flatMap(u => {
      const errs = validasiGridTarget(patokanMap[u.ujian_id] || buildEmpty())
      return errs.map(e => `${labelUjian(u)} — ${e}`)
    })
    if (salah.length > 0) {
      showToast(salah[0], "error")
      return
    }

    setSaving(true)
    let hasError = false
    for (const u of ujianList) {
      try {
        await simpanPatokanUjian(u.ujian_id, patokanMap[u.ujian_id] || buildEmpty(), user.id)
      } catch {
        hasError = true
      }
    }
    setSaving(false)
    showToast(hasError ? "Sebagian gagal disimpan" : "Semua target berhasil disimpan!", hasError ? "error" : "success")
  }

  const handleBobotChange = (mapelId: string, tipe: string, kesulitan: string, value: number) => {
    setBobotMap(prev => ({ ...prev, [mapelId]: { ...prev[mapelId], [`${tipe}_${kesulitan}`]: value } }))
  }

  const handleSaveBobot = async () => {
    if (!selectedBobotMapel) return
    setSavingBobot(true)
    const rows = TIPE_OPTIONS.flatMap(t =>
      KESULITAN_OPTIONS.map(k => ({
        mapel_id: selectedBobotMapel, tipe: t, kesulitan: k,
        bobot: bobotMap[selectedBobotMapel]?.[`${t}_${k}`] ?? (BOBOT_DEFAULT[t]?.[k] ?? 1.0),
      }))
    )
    const { error: delErr } = await supabase.from("bobot_config").delete().eq("mapel_id", selectedBobotMapel)
    if (!delErr) {
      const { error: insErr } = await supabase.from("bobot_config").insert(rows)
      if (!insErr) {
        setCustomBobotMapels(prev => new Set([...prev, selectedBobotMapel]))
        showToast("Bobot berhasil disimpan!", "success")
      } else {
        showToast("Gagal menyimpan bobot", "error")
      }
    } else {
      showToast("Gagal menyimpan bobot", "error")
    }
    setSavingBobot(false)
  }

  const handleResetBobot = async () => {
    if (!selectedBobotMapel) return
    setSavingBobot(true)
    const { error } = await supabase.from("bobot_config").delete().eq("mapel_id", selectedBobotMapel)
    if (!error) {
      setBobotMap(prev => ({ ...prev, [selectedBobotMapel]: buildEmptyBobot() }))
      setCustomBobotMapels(prev => { const next = new Set(prev); next.delete(selectedBobotMapel); return next })
      showToast("Bobot direset ke nilai default", "success")
    } else {
      showToast("Gagal reset bobot", "error")
    }
    setSavingBobot(false)
  }

  const handleCopyBobot = async () => {
    if (copyTargets.size === 0 || !selectedBobotMapel) return
    setCopyingBobot(true)
    const allRows = Array.from(copyTargets).flatMap(targetMapelId =>
      TIPE_OPTIONS.flatMap(t =>
        KESULITAN_OPTIONS.map(k => ({
          mapel_id: targetMapelId, tipe: t, kesulitan: k,
          bobot: bobotMap[selectedBobotMapel]?.[`${t}_${k}`] ?? BOBOT_DEFAULT[t]?.[k] ?? 1.0,
        }))
      )
    )
    const { error: delErr } = await supabase.from("bobot_config").delete().in("mapel_id", Array.from(copyTargets))
    if (!delErr) {
      const { error: insErr } = await supabase.from("bobot_config").insert(allRows)
      if (!insErr) {
        const newBobotMap = { ...bobotMap }
        const newCustomSet = new Set(customBobotMapels)
        copyTargets.forEach(id => { newBobotMap[id] = { ...bobotMap[selectedBobotMapel] }; newCustomSet.add(id) })
        setBobotMap(newBobotMap)
        setCustomBobotMapels(newCustomSet)
        setShowCopyModal(false)
        showToast(`Bobot disalin ke ${copyTargets.size} mapel`, "success")
      } else {
        showToast("Gagal menyalin bobot", "error")
      }
    } else {
      showToast("Gagal menyalin bobot", "error")
    }
    setCopyingBobot(false)
  }

  if (loading) {
    return (
      <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh" }} className="flex items-center justify-center">
        <div className="font-display text-xl" style={{ color: "var(--pp-ink-2)" }}>Memuat...</div>
      </div>
    )
  }

  const selectedMapelName = mataPelajaran.find(m => m.id === selectedBobotMapel)?.nama ?? ""
  const isCustom = customBobotMapels.has(selectedBobotMapel)

  return (
    <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh" }}>
      <header
        className="sticky top-0 z-10"
        style={{ backgroundColor: "var(--pp-card)", borderBottom: "1.5px solid var(--pp-ink)" }}
      >
        <div className="max-w-full mx-auto px-4 py-3 flex items-center justify-between gap-3">
          <div className="flex items-center gap-3 min-w-0">
            <div style={{
              width: 40, height: 40, flexShrink: 0,
              backgroundColor: "var(--pp-primary)",
              border: "1.5px dashed rgba(255,255,255,0.45)",
              borderRadius: 12,
              boxShadow: "2px 2px 0 0 var(--pp-ink)",
              display: "flex", alignItems: "center", justifyContent: "center",
            }}>
              <span className="font-display font-bold text-sm text-white">A</span>
            </div>
            <div>
              <div className="font-display font-semibold text-base" style={{ color: "var(--pp-ink)" }}>
                Admin Panel
              </div>
              <div className="flex gap-1 mt-0.5">
                {(["patokan", "bobot"] as const).map(tab => (
                  <button
                    key={tab}
                    onClick={() => setActiveTab(tab)}
                    className="text-xs font-semibold px-2.5 py-0.5 rounded-full transition-colors"
                    style={activeTab === tab
                      ? { backgroundColor: "var(--pp-lemon)", color: "var(--pp-ink)", border: "1.5px solid var(--pp-ink)" }
                      : { backgroundColor: "transparent", color: "var(--pp-muted)", border: "1.5px solid transparent" }
                    }
                  >
                    {tab === "patokan" ? "Patokan Soal" : "Bobot Soal"}
                  </button>
                ))}
              </div>
            </div>
          </div>
          <div className="flex items-center gap-2 shrink-0">
            <ThemeToggle />
            {activeTab === "patokan" && (
              <button
                onClick={handleSavePatokan}
                disabled={saving}
                onMouseDown={() => setSavePressed(true)}
                onMouseUp={() => setSavePressed(false)}
                onMouseLeave={() => setSavePressed(false)}
                className="flex items-center gap-1.5 text-sm font-semibold px-4 py-2 rounded-[10px] disabled:opacity-50"
                style={{
                  backgroundColor: "var(--pp-ink)",
                  color: "#fff",
                  border: "1.5px solid var(--pp-ink)",
                  boxShadow: savePressed ? "none" : "3px 3px 0 0 rgba(0,0,0,0.4)",
                  transform: savePressed ? "translate(2px,2px)" : "none",
                  transition: "box-shadow 80ms, transform 80ms",
                }}
              >
                <Save className="w-3.5 h-3.5" />
                {saving ? "Menyimpan..." : "Simpan Semua"}
              </button>
            )}
          </div>
        </div>
      </header>

      <div className="max-w-full px-4 pt-4 pb-1">
        <button
          onClick={() => router.push("/dashboard")}
          className="flex items-center gap-1.5 text-sm hover:opacity-70 transition-opacity"
          style={{ color: "var(--pp-muted)" }}
        >
          <ArrowLeft className="w-4 h-4" />
          Kembali ke Dashboard
        </button>
      </div>

      {/* ===== TAB PATOKAN ===== */}
      {activeTab === "patokan" && ujianList.length === 0 && (
        <main className="px-4 py-4 pb-12">
          <div
            className="text-center px-6 py-12"
            style={{
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 22,
              boxShadow: "6px 6px 0 0 var(--pp-ink)",
              backgroundColor: "var(--pp-card)",
            }}
          >
            <Inbox className="w-10 h-10 mx-auto mb-3" style={{ color: "var(--pp-muted)" }} />
            <div className="font-display font-semibold text-base mb-1" style={{ color: "var(--pp-ink)" }}>
              Belum ada ujian aktif
            </div>
            <p className="text-sm max-w-md mx-auto" style={{ color: "var(--pp-muted)" }}>
              Target soal diisi per ujian. Super admin perlu membuat ujian (UTS/UAS) di LMS
              pada siklus yang sedang aktif lebih dulu — daftarnya akan muncul di sini otomatis.
            </p>
          </div>
        </main>
      )}

      {activeTab === "patokan" && ujianList.length > 0 && (
        <main className="px-4 py-4 pb-12 overflow-x-auto">
          <div
            style={{
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 22,
              boxShadow: "6px 6px 0 0 var(--pp-ink)",
              overflow: "hidden",
              minWidth: 1000,
            }}
          >
            <table className="text-sm border-collapse w-full">
              <thead>
                <tr style={{ backgroundColor: "var(--pp-lemon)", borderBottom: "1.5px solid var(--pp-ink)" }}>
                  <th
                    className="px-3 py-2.5 text-left font-display font-semibold"
                    style={{ color: "var(--pp-ink)", borderRight: "1.5px solid var(--pp-ink)" }}
                    rowSpan={2}
                  >
                    Ujian
                  </th>
                  <th
                    className="px-3 py-2.5 text-left font-display font-semibold"
                    style={{ color: "var(--pp-ink)", borderRight: "1.5px solid var(--pp-ink)" }}
                    rowSpan={2}
                  >
                    Tingkat
                  </th>
                  {TIPE_OPTIONS.map(tipe => (
                    <th
                      key={tipe}
                      className="px-3 py-2 text-center font-semibold"
                      style={{
                        backgroundColor: TIPE_COLORS[tipe].bg,
                        color: TIPE_COLORS[tipe].accent,
                        borderLeft: "1.5px solid var(--pp-ink)",
                        borderRight: "1.5px solid var(--pp-ink)",
                      }}
                      colSpan={2}
                    >
                      {TIPE_LABELS[tipe]}
                    </th>
                  ))}
                  <th
                    className="px-3 py-2 text-center font-semibold"
                    style={{ color: "#15803d", backgroundColor: "var(--pp-mint)", borderLeft: "1.5px solid var(--pp-ink)" }}
                    colSpan={2}
                  >
                    Total
                  </th>
                </tr>
                <tr style={{ backgroundColor: "var(--pp-lemon)", borderBottom: "1.5px solid var(--pp-ink)" }}>
                  {TIPE_OPTIONS.map(tipe => (
                    <React.Fragment key={tipe}>
                      <th className="px-2 py-1 text-center text-xs font-semibold" style={{ color: "#15803d", borderLeft: "1.5px solid var(--pp-ink)", borderRight: "1px solid var(--pp-line)" }}>Soal</th>
                      <th className="px-2 py-1 text-center text-xs font-semibold" style={{ color: "#b45309", borderRight: "1.5px solid var(--pp-ink)" }}>Bank</th>
                    </React.Fragment>
                  ))}
                  <th className="px-2 py-1 text-center text-xs font-semibold" style={{ color: "#15803d", borderLeft: "1.5px solid var(--pp-ink)", borderRight: "1px solid var(--pp-line)" }}>Soal</th>
                  <th className="px-2 py-1 text-center text-xs font-semibold" style={{ color: "#b45309" }}>Bank</th>
                </tr>
              </thead>
              <tbody>
                {ujianList.map((ujian, mi) => {
                  const p = patokanMap[ujian.ujian_id] || buildEmpty()
                  const rowBg = mi % 2 === 0 ? "var(--pp-card)" : "var(--pp-bg)"
                  return (
                    <React.Fragment key={ujian.ujian_id}>
                      {KESULITAN_OPTIONS.map((kesulitan, ki) => {
                        const rowSoal = TIPE_OPTIONS.reduce((s, t) => s + (p[`${t}_${kesulitan}_keluar`] || 0), 0)
                        const rowBank = TIPE_OPTIONS.reduce((s, t) => s + (p[`${t}_${kesulitan}_bank`] || 0), 0)
                        return (
                          <tr key={`${ujian.ujian_id}-${kesulitan}`} style={{ backgroundColor: rowBg }}>
                            {ki === 0 && (
                              <td
                                className="px-3 py-2 font-semibold text-sm"
                                style={{
                                  color: "var(--pp-ink)",
                                  verticalAlign: "middle",
                                  borderRight: "1.5px solid var(--pp-ink)",
                                  borderBottom: "1.5px solid var(--pp-ink)",
                                }}
                                rowSpan={KESULITAN_OPTIONS.length + 1}
                              >
                                {ujian.mapel_nama || ujian.ujian_nama}
                                {ujian.level && (
                                  <span
                                    className="ml-1.5 text-xs px-1.5 py-0.5 rounded-full font-medium"
                                    style={{ backgroundColor: "var(--pp-lemon)", color: "var(--pp-ink)", border: "1px solid var(--pp-ink)" }}
                                  >
                                    Kelas {ujian.level}
                                  </span>
                                )}
                                {ujian.kelas_list && ujian.kelas_list.length > 0 && (
                                  <div className="text-xs font-normal mt-1" style={{ color: "var(--pp-muted)" }}>
                                    {ujian.kelas_list.join(", ")}
                                  </div>
                                )}

                                {/* Penanggung jawab matriks. Tanpa ini, SEMUA guru
                                    mapel+tingkat ini mengisi matriksnya sendiri dan
                                    jumlahnya berlipat sebanyak jumlah guru. */}
                                <div className="mt-2 font-normal">
                                  <label className="block text-[11px] mb-0.5" style={{ color: "var(--pp-muted)" }}>
                                    Penulis matriks
                                  </label>
                                  <select
                                    value={(calonPenulis[ujian.ujian_id] || []).find(c => c.ditunjuk)?.profile_id ?? ""}
                                    disabled={menyimpanPenulis === ujian.ujian_id}
                                    onChange={e => ubahPenulis(ujian.ujian_id, e.target.value)}
                                    className="text-xs px-2 py-1 w-full max-w-[200px]"
                                    style={{
                                      border: "1px solid var(--pp-ink)",
                                      borderRadius: 10,
                                      backgroundColor: "var(--pp-card)",
                                      color: "var(--pp-ink)",
                                    }}
                                  >
                                    <option value="">— belum ditunjuk —</option>
                                    {(calonPenulis[ujian.ujian_id] || []).map(c => (
                                      <option key={c.profile_id} value={c.profile_id}>
                                        {c.nama || c.profile_id.slice(0, 8)}{c.sudah_isi ? " • sudah mengisi" : ""}
                                      </option>
                                    ))}
                                  </select>
                                  {(calonPenulis[ujian.ujian_id]?.filter(c => c.sudah_isi).length ?? 0) > 1 &&
                                   !(calonPenulis[ujian.ujian_id] || []).some(c => c.ditunjuk) && (
                                    <div className="text-[11px] mt-1" style={{ color: "#b45309" }}>
                                      {calonPenulis[ujian.ujian_id].filter(c => c.sudah_isi).length} guru sudah mengisi —
                                      tunjuk satu, kalau tidak matriksnya tidak bisa dikirim ke LMS.
                                    </div>
                                  )}
                                </div>

                                {/* Salin pagu ke tingkat lain mapel yang sama.
                                    Tiap mapel punya 3 tingkat × 15 sel; tanpa ini
                                    pengisian awal satu event berarti ratusan angka
                                    diketik ulang. */}
                                {tujuanSalin(ujian).length > 0 && (
                                  <div className="mt-2 font-normal">
                                    <button
                                      onClick={() => bukaSalin(ujian.ujian_id)}
                                      className="text-[11px] px-2 py-1"
                                      style={{
                                        border: "1px dashed var(--pp-ink)",
                                        borderRadius: 10,
                                        backgroundColor: "transparent",
                                        color: "var(--pp-ink-2)",
                                      }}
                                    >
                                      ⧉ Salin pagu ke…
                                    </button>

                                    {salinDari === ujian.ujian_id && (
                                      <div
                                        className="mt-1.5 p-2"
                                        style={{
                                          border: "1.5px solid var(--pp-ink)",
                                          borderRadius: 12,
                                          backgroundColor: "var(--pp-card)",
                                        }}
                                      >
                                        {tujuanSalin(ujian).map(t => (
                                          <label
                                            key={t.ujian_id}
                                            className="flex items-start gap-1.5 text-[11px] mb-1 cursor-pointer"
                                            style={{ color: "var(--pp-ink)" }}
                                          >
                                            <input
                                              type="checkbox"
                                              checked={salinKe.has(t.ujian_id)}
                                              onChange={e => setSalinKe(prev => {
                                                const next = new Set(prev)
                                                if (e.target.checked) next.add(t.ujian_id)
                                                else next.delete(t.ujian_id)
                                                return next
                                              })}
                                              className="mt-0.5"
                                            />
                                            <span>
                                              {t.level ? `Kelas ${t.level}` : t.ujian_nama}
                                              {matriksTerkunci.has(t.ujian_id) && (
                                                <span style={{ color: "#b45309" }}> • matriks sudah disubmit</span>
                                              )}
                                            </span>
                                          </label>
                                        ))}
                                        <button
                                          onClick={() => terapkanSalin(ujian)}
                                          disabled={salinKe.size === 0}
                                          className="mt-1 text-[11px] px-2 py-1 w-full font-semibold"
                                          style={{
                                            border: "1.5px solid var(--pp-ink)",
                                            borderRadius: 10,
                                            backgroundColor: salinKe.size > 0 ? "var(--pp-lemon)" : "transparent",
                                            color: salinKe.size > 0 ? "var(--pp-ink)" : "var(--pp-muted)",
                                          }}
                                        >
                                          Terapkan ({salinKe.size})
                                        </button>
                                      </div>
                                    )}
                                  </div>
                                )}
                              </td>
                            )}
                            <td
                              className="px-3 py-1.5 text-xs capitalize font-medium"
                              style={{ color: "var(--pp-ink-2)", borderRight: "1.5px solid var(--pp-ink)", borderBottom: "1px solid var(--pp-line)" }}
                            >
                              {kesulitan}
                            </td>
                            {TIPE_OPTIONS.map(tipe => (
                              <React.Fragment key={tipe}>
                                <td className="px-1 py-1" style={{ borderLeft: "1.5px solid var(--pp-ink)", borderBottom: "1px solid var(--pp-line)" }}>
                                  <input
                                    type="number" min="0"
                                    value={p[`${tipe}_${kesulitan}_keluar`] || 0}
                                    onChange={e => handlePatokanChange(ujian.ujian_id, `${tipe}_${kesulitan}_keluar`, parseInt(e.target.value) || 0)}
                                    className="w-14 px-1 py-0.5 rounded-[6px] text-xs text-center"
                                    style={{ backgroundColor: "var(--pp-bg)", border: "1.5px solid var(--pp-line)", color: "var(--pp-ink)", outline: "none" }}
                                    onFocus={e => { e.currentTarget.style.border = "1.5px solid var(--pp-primary)"; e.currentTarget.style.boxShadow = "2px 2px 0 0 var(--pp-primary)" }}
                                    onBlur={e => { e.currentTarget.style.border = "1.5px solid var(--pp-line)"; e.currentTarget.style.boxShadow = "none" }}
                                  />
                                </td>
                                <td className="px-1 py-1" style={{ borderRight: "1.5px solid var(--pp-ink)", borderBottom: "1px solid var(--pp-line)" }}>
                                  <input
                                    type="number" min="0"
                                    value={p[`${tipe}_${kesulitan}_bank`] || 0}
                                    onChange={e => handlePatokanChange(ujian.ujian_id, `${tipe}_${kesulitan}_bank`, parseInt(e.target.value) || 0)}
                                    className="w-14 px-1 py-0.5 rounded-[6px] text-xs text-center"
                                    style={{ backgroundColor: "var(--pp-bg)", border: "1.5px solid var(--pp-line)", color: "var(--pp-ink)", outline: "none" }}
                                    onFocus={e => { e.currentTarget.style.border = "1.5px solid var(--pp-primary)"; e.currentTarget.style.boxShadow = "2px 2px 0 0 var(--pp-primary)" }}
                                    onBlur={e => { e.currentTarget.style.border = "1.5px solid var(--pp-line)"; e.currentTarget.style.boxShadow = "none" }}
                                  />
                                </td>
                              </React.Fragment>
                            ))}
                            <td className="px-2 py-1 text-center text-xs font-bold" style={{ borderLeft: "1.5px solid var(--pp-ink)", borderBottom: "1px solid var(--pp-line)", color: "#15803d" }}>{rowSoal}</td>
                            <td className="px-2 py-1 text-center text-xs font-bold" style={{ borderBottom: "1px solid var(--pp-line)", color: "#b45309" }}>{rowBank}</td>
                          </tr>
                        )
                      })}
                      <tr style={{ backgroundColor: "var(--pp-mint)", borderBottom: "1.5px solid var(--pp-ink)" }}>
                        <td className="px-3 py-1.5 text-xs font-bold" style={{ color: "var(--pp-ink)", borderRight: "1.5px solid var(--pp-ink)" }}>
                          Total
                        </td>
                        {TIPE_OPTIONS.map(tipe => {
                          const colSoal = KESULITAN_OPTIONS.reduce((s, k) => s + (p[`${tipe}_${k}_keluar`] || 0), 0)
                          const colBank = KESULITAN_OPTIONS.reduce((s, k) => s + (p[`${tipe}_${k}_bank`] || 0), 0)
                          return (
                            <React.Fragment key={tipe}>
                              <td className="px-2 py-1 text-center text-xs font-bold" style={{ borderLeft: "1.5px solid var(--pp-ink)", color: "#15803d" }}>{colSoal}</td>
                              <td className="px-2 py-1 text-center text-xs font-bold" style={{ borderRight: "1.5px solid var(--pp-ink)", color: "#b45309" }}>{colBank}</td>
                            </React.Fragment>
                          )
                        })}
                        <td className="px-2 py-1 text-center text-xs font-bold" style={{ borderLeft: "1.5px solid var(--pp-ink)", color: "#15803d" }}>
                          {TIPE_OPTIONS.reduce((s, t) => s + KESULITAN_OPTIONS.reduce((ss, k) => ss + (p[`${t}_${k}_keluar`] || 0), 0), 0)}
                        </td>
                        <td className="px-2 py-1 text-center text-xs font-bold" style={{ color: "#b45309" }}>
                          {TIPE_OPTIONS.reduce((s, t) => s + KESULITAN_OPTIONS.reduce((ss, k) => ss + (p[`${t}_${k}_bank`] || 0), 0), 0)}
                        </td>
                      </tr>
                    </React.Fragment>
                  )
                })}
              </tbody>
              <tfoot>
                {(() => {
                  const grand: Record<string, number> = {}
                  Object.values(patokanMap).forEach(p => {
                    TIPE_OPTIONS.forEach(t => KESULITAN_OPTIONS.forEach(k => {
                      grand[`${t}_${k}_keluar`] = (grand[`${t}_${k}_keluar`] || 0) + (p[`${t}_${k}_keluar`] || 0)
                      grand[`${t}_${k}_bank`]   = (grand[`${t}_${k}_bank`]   || 0) + (p[`${t}_${k}_bank`]   || 0)
                    }))
                  })
                  const grandSoal = TIPE_OPTIONS.reduce((s, t) => s + KESULITAN_OPTIONS.reduce((ss, k) => ss + (grand[`${t}_${k}_keluar`] || 0), 0), 0)
                  const grandBank = TIPE_OPTIONS.reduce((s, t) => s + KESULITAN_OPTIONS.reduce((ss, k) => ss + (grand[`${t}_${k}_bank`]   || 0), 0), 0)
                  return (
                    <tr style={{ backgroundColor: "#dbeafe", borderTop: "1.5px solid var(--pp-ink)" }}>
                      <td colSpan={2} className="px-3 py-2 text-sm font-display font-bold" style={{ color: "var(--pp-ink)", borderRight: "1.5px solid var(--pp-ink)" }}>
                        Grand Total
                      </td>
                      {TIPE_OPTIONS.map(tipe => {
                        const colSoal = KESULITAN_OPTIONS.reduce((s, k) => s + (grand[`${tipe}_${k}_keluar`] || 0), 0)
                        const colBank = KESULITAN_OPTIONS.reduce((s, k) => s + (grand[`${tipe}_${k}_bank`]   || 0), 0)
                        return (
                          <React.Fragment key={tipe}>
                            <td className="px-2 py-2 text-center text-sm font-bold" style={{ borderLeft: "1.5px solid var(--pp-ink)", color: "#15803d" }}>{colSoal}</td>
                            <td className="px-2 py-2 text-center text-sm font-bold" style={{ borderRight: "1.5px solid var(--pp-ink)", color: "#b45309" }}>{colBank}</td>
                          </React.Fragment>
                        )
                      })}
                      <td className="px-2 py-2 text-center text-sm font-bold" style={{ borderLeft: "1.5px solid var(--pp-ink)", color: "#15803d" }}>{grandSoal}</td>
                      <td className="px-2 py-2 text-center text-sm font-bold" style={{ color: "#b45309" }}>{grandBank}</td>
                    </tr>
                  )
                })()}
              </tfoot>
            </table>
          </div>
        </main>
      )}

      {/* ===== TAB BOBOT ===== */}
      {activeTab === "bobot" && (
        <main className="px-4 py-4 pb-12 max-w-4xl space-y-5">
          <div
            style={{
              backgroundColor: "var(--pp-lemon)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 16,
              padding: "12px 18px",
              boxShadow: "3px 3px 0 0 var(--pp-ink)",
              fontSize: 14,
              color: "var(--pp-ink-2)",
            }}
          >
            Bobot menentukan nilai per soal. Setiap mata pelajaran bisa punya bobot berbeda. Jika mapel belum dikonfigurasi, nilai default sistem digunakan.
          </div>

          {/* Pilih mapel */}
          <div
            style={{
              backgroundColor: "var(--pp-card)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 16,
              padding: "14px 20px",
              boxShadow: "3px 3px 0 0 var(--pp-ink)",
            }}
          >
            <div className="flex flex-wrap items-center gap-3">
              <label className="text-sm font-semibold" style={{ color: "var(--pp-ink)" }}>Mata Pelajaran:</label>
              <select
                value={selectedBobotMapel}
                onChange={e => setSelectedBobotMapel(e.target.value)}
                className="px-3 py-1.5 rounded-[10px] text-sm font-medium"
                style={{
                  backgroundColor: "var(--pp-bg)",
                  border: "1.5px solid var(--pp-ink)",
                  color: "var(--pp-ink)",
                  boxShadow: "2px 2px 0 0 var(--pp-ink)",
                }}
              >
                {mataPelajaran.map(m => (
                  <option key={m.id} value={m.id}>
                    {m.nama}{m.kode ? ` (${m.kode})` : ""}{customBobotMapels.has(m.id) ? " ✦" : ""}
                  </option>
                ))}
              </select>
              <span
                className="text-xs px-2.5 py-1 rounded-full font-semibold"
                style={isCustom
                  ? { backgroundColor: "var(--pp-mint)", color: "#15803d", border: "1.5px solid var(--pp-ink)" }
                  : { backgroundColor: "var(--pp-bg)", color: "var(--pp-muted)", border: "1.5px solid var(--pp-line)" }
                }
              >
                {isCustom ? "Kustom" : "Default"}
              </span>
            </div>
          </div>

          {/* Grid bobot */}
          {selectedBobotMapel && (
            <div
              style={{
                backgroundColor: "var(--pp-card)",
                border: "1.5px solid var(--pp-ink)",
                borderRadius: 22,
                boxShadow: "4px 4px 0 0 var(--pp-ink)",
                overflow: "hidden",
              }}
            >
              <div style={{ backgroundColor: "var(--pp-lemon)", borderBottom: "1.5px solid var(--pp-ink)", padding: "12px 20px" }}>
                <div className="font-display font-semibold text-base" style={{ color: "var(--pp-ink)" }}>
                  Konfigurasi Bobot — {selectedMapelName}
                </div>
              </div>
              <table className="text-sm w-full border-collapse">
                <thead>
                  <tr style={{ backgroundColor: "var(--pp-bg)", borderBottom: "1.5px solid var(--pp-ink)" }}>
                    <th className="px-4 py-2.5 text-left font-semibold" style={{ color: "var(--pp-ink)", borderRight: "1.5px solid var(--pp-ink)" }}>
                      Tipe Soal
                    </th>
                    {KESULITAN_OPTIONS.map(k => (
                      <th key={k} className="px-4 py-2.5 text-center font-semibold" style={{ color: "var(--pp-ink)", borderRight: "1.5px solid var(--pp-line)" }}>
                        {KESULITAN_LABELS[k]}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {TIPE_OPTIONS.map((tipe, ti) => {
                    const { bg, accent } = TIPE_COLORS[tipe]
                    return (
                      <tr key={tipe} style={{ borderBottom: "1px solid var(--pp-line)" }}>
                        <td className="px-4 py-2 font-semibold text-sm" style={{ backgroundColor: bg, color: accent, borderRight: "1.5px solid var(--pp-ink)" }}>
                          {TIPE_LABELS[tipe]}
                        </td>
                        {KESULITAN_OPTIONS.map(k => {
                          const val = bobotMap[selectedBobotMapel]?.[`${tipe}_${k}`] ?? BOBOT_DEFAULT[tipe]?.[k] ?? 1.0
                          const defVal = BOBOT_DEFAULT[tipe]?.[k] ?? 1.0
                          const isModified = val !== defVal
                          return (
                            <td key={k} className="px-3 py-1.5 text-center" style={{ backgroundColor: ti % 2 === 0 ? "var(--pp-card)" : "var(--pp-bg)", borderRight: "1.5px solid var(--pp-line)" }}>
                              <div className="flex flex-col items-center gap-0.5">
                                <input
                                  type="number" min="0" step="0.5"
                                  value={val}
                                  onChange={e => handleBobotChange(selectedBobotMapel, tipe, k, parseFloat(e.target.value) || 0)}
                                  className="w-20 px-2 py-1 rounded-[8px] text-center text-sm"
                                  style={{
                                    backgroundColor: "var(--pp-bg)",
                                    border: isModified ? "1.5px solid var(--pp-primary)" : "1.5px solid var(--pp-line)",
                                    color: "var(--pp-ink)",
                                    boxShadow: isModified ? "2px 2px 0 0 var(--pp-primary)" : "none",
                                    outline: "none",
                                  }}
                                />
                                {isModified && (
                                  <span className="text-xs" style={{ color: "var(--pp-muted)" }}>default: {defVal}</span>
                                )}
                              </div>
                            </td>
                          )
                        })}
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}

          {/* Action buttons */}
          <div className="flex flex-wrap gap-3">
            <button
              onClick={handleSaveBobot}
              disabled={savingBobot || !selectedBobotMapel}
              className="flex items-center gap-1.5 py-2 px-5 rounded-[10px] text-sm font-semibold disabled:opacity-50"
              style={{
                backgroundColor: "var(--pp-ink)", color: "#fff",
                border: "1.5px solid var(--pp-ink)",
                boxShadow: "3px 3px 0 0 rgba(0,0,0,0.35)",
              }}
            >
              <Save className="w-3.5 h-3.5" />
              {savingBobot ? "Menyimpan..." : `Simpan — ${selectedMapelName}`}
            </button>
            <button
              onClick={() => { setCopyTargets(new Set()); setShowCopyModal(true) }}
              disabled={savingBobot || !selectedBobotMapel}
              className="flex items-center gap-1.5 py-2 px-4 rounded-[10px] text-sm font-semibold disabled:opacity-50"
              style={{
                backgroundColor: "var(--pp-card)", color: "var(--pp-ink)",
                border: "1.5px solid var(--pp-ink)",
                boxShadow: "3px 3px 0 0 var(--pp-ink)",
              }}
            >
              <Copy className="w-3.5 h-3.5" /> Salin ke Mapel Lain...
            </button>
            {isCustom && (
              <button
                onClick={handleResetBobot}
                disabled={savingBobot}
                className="flex items-center gap-1.5 py-2 px-4 rounded-[10px] text-sm font-semibold disabled:opacity-50"
                style={{
                  backgroundColor: "var(--pp-pink)", color: "#be123c",
                  border: "1.5px solid var(--pp-ink)",
                  boxShadow: "3px 3px 0 0 var(--pp-ink)",
                }}
              >
                <RotateCcw className="w-3.5 h-3.5" /> Reset ke Default
              </button>
            )}
          </div>

          {/* Default reference */}
          <div
            style={{
              backgroundColor: "var(--pp-card)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 16,
              padding: "16px 20px",
              boxShadow: "3px 3px 0 0 var(--pp-ink)",
            }}
          >
            <p className="text-xs font-display font-semibold mb-3" style={{ color: "var(--pp-ink)" }}>
              Nilai Default Sistem (referensi)
            </p>
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
              {TIPE_OPTIONS.map(tipe => {
                const { bg, accent } = TIPE_COLORS[tipe]
                return (
                  <div key={tipe}>
                    <div
                      className="text-xs font-semibold px-2 py-1 rounded-[6px] mb-1.5 inline-block"
                      style={{ backgroundColor: bg, color: accent, border: "1px solid var(--pp-ink)" }}
                    >
                      {TIPE_LABELS[tipe]}
                    </div>
                    {KESULITAN_OPTIONS.map(k => (
                      <p key={k} className="text-xs" style={{ color: "var(--pp-ink-2)" }}>
                        {KESULITAN_LABELS[k]}: <strong>{BOBOT_DEFAULT[tipe]?.[k] ?? "-"}</strong>
                      </p>
                    ))}
                  </div>
                )
              })}
            </div>
          </div>

          {/* Ringkasan */}
          <div>
            <p className="text-sm font-display font-semibold mb-3" style={{ color: "var(--pp-ink)" }}>
              Ringkasan ({customBobotMapels.size} dari {mataPelajaran.length} mapel dikustomisasi)
            </p>
            <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-5 gap-2">
              {mataPelajaran.map(m => {
                const isSelected = selectedBobotMapel === m.id
                const isKustom = customBobotMapels.has(m.id)
                return (
                  <button
                    key={m.id}
                    onClick={() => setSelectedBobotMapel(m.id)}
                    className="text-left px-3 py-2 rounded-[12px] text-xs transition-all"
                    style={{
                      border: "1.5px solid var(--pp-ink)",
                      backgroundColor: isSelected ? "var(--pp-ink)" : isKustom ? "var(--pp-mint)" : "var(--pp-card)",
                      color: isSelected ? "#fff" : "var(--pp-ink)",
                      boxShadow: isSelected ? "none" : "2px 2px 0 0 var(--pp-ink)",
                      transform: isSelected ? "translate(2px,2px)" : "none",
                    }}
                  >
                    <span className="font-semibold block truncate">{m.nama}</span>
                    <span style={{ color: isSelected ? "rgba(255,255,255,0.7)" : "var(--pp-muted)", fontSize: 10 }}>
                      {isKustom ? "Kustom" : "Default"}
                    </span>
                  </button>
                )
              })}
            </div>
          </div>
        </main>
      )}

      {/* Modal Salin Bobot */}
      {showCopyModal && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center p-4"
          style={{ backgroundColor: "rgba(0,0,0,0.55)" }}
          onClick={e => { if (e.target === e.currentTarget) setShowCopyModal(false) }}
        >
          <div
            className="w-full max-w-md"
            style={{
              backgroundColor: "var(--pp-card)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 22,
              boxShadow: "6px 6px 0 0 var(--pp-ink)",
              overflow: "hidden",
            }}
          >
            <div style={{ backgroundColor: "var(--pp-lilac)", borderBottom: "1.5px solid var(--pp-ink)", padding: "16px 20px" }}>
              <div className="font-display font-semibold text-base" style={{ color: "var(--pp-ink)" }}>
                Salin Bobot ke Mapel Lain
              </div>
              <div className="text-xs mt-0.5" style={{ color: "var(--pp-ink-2)" }}>
                Bobot dari <strong>{selectedMapelName}</strong> akan diterapkan ke mapel yang dipilih.
              </div>
            </div>

            <div className="p-5 space-y-4">
              <div className="flex gap-2">
                <button
                  onClick={() => setCopyTargets(new Set(mataPelajaran.filter(m => m.id !== selectedBobotMapel).map(m => m.id)))}
                  className="text-xs px-3 py-1.5 rounded-full font-semibold"
                  style={{ backgroundColor: "var(--pp-ink)", color: "#fff", border: "1.5px solid var(--pp-ink)" }}
                >
                  Pilih Semua
                </button>
                <button
                  onClick={() => setCopyTargets(new Set())}
                  className="text-xs px-3 py-1.5 rounded-full font-semibold"
                  style={{ backgroundColor: "var(--pp-bg)", color: "var(--pp-muted)", border: "1.5px solid var(--pp-line)" }}
                >
                  Batalkan Semua
                </button>
              </div>

              <div className="grid grid-cols-2 gap-2 max-h-56 overflow-y-auto pr-1">
                {mataPelajaran.filter(m => m.id !== selectedBobotMapel).map(m => {
                  const checked = copyTargets.has(m.id)
                  const isKustom = customBobotMapels.has(m.id)
                  return (
                    <label
                      key={m.id}
                      className="flex items-start gap-2 px-3 py-2 rounded-[10px] cursor-pointer"
                      style={{
                        border: "1.5px solid var(--pp-ink)",
                        backgroundColor: checked ? "var(--pp-lemon)" : "var(--pp-bg)",
                        boxShadow: checked ? "none" : "2px 2px 0 0 var(--pp-ink)",
                        transform: checked ? "translate(2px,2px)" : "none",
                        transition: "all 80ms",
                      }}
                    >
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={e => {
                          setCopyTargets(prev => {
                            const next = new Set(prev)
                            if (e.target.checked) next.add(m.id)
                            else next.delete(m.id)
                            return next
                          })
                        }}
                        className="mt-0.5 shrink-0"
                      />
                      <div className="min-w-0">
                        <span className="text-xs font-semibold block truncate" style={{ color: "var(--pp-ink)" }}>{m.nama}</span>
                        {isKustom && <span className="text-xs" style={{ color: "#b45309" }}>Kustom</span>}
                      </div>
                    </label>
                  )
                })}
              </div>

              {(() => {
                const willOverwrite = Array.from(copyTargets).filter(id => customBobotMapels.has(id)).length
                return willOverwrite > 0 ? (
                  <div
                    className="text-xs px-3 py-2 rounded-[10px]"
                    style={{ backgroundColor: "var(--pp-peach)", color: "var(--pp-ink)", border: "1.5px solid var(--pp-ink)" }}
                  >
                    {willOverwrite} mapel sudah punya bobot kustom dan akan di-overwrite.
                  </div>
                ) : null
              })()}
            </div>

            <div className="flex gap-3 px-5 py-4" style={{ borderTop: "1.5px solid var(--pp-ink)" }}>
              <button
                onClick={() => setShowCopyModal(false)}
                disabled={copyingBobot}
                className="flex-1 py-2 px-4 rounded-[10px] text-sm font-semibold disabled:opacity-50"
                style={{ backgroundColor: "var(--pp-bg)", color: "var(--pp-ink)", border: "1.5px solid var(--pp-ink)" }}
              >
                Batal
              </button>
              <button
                onClick={handleCopyBobot}
                disabled={copyTargets.size === 0 || copyingBobot}
                className="flex-1 py-2 px-4 rounded-[10px] text-sm font-semibold disabled:opacity-50"
                style={{
                  backgroundColor: "var(--pp-ink)", color: "#fff",
                  border: "1.5px solid var(--pp-ink)",
                  boxShadow: "3px 3px 0 0 rgba(0,0,0,0.3)",
                }}
              >
                {copyingBobot ? "Menerapkan..." : `Terapkan (${copyTargets.size} mapel)`}
              </button>
            </div>
          </div>
        </div>
      )}

      {toast && <Toast message={toast.message} type={toast.type} onClose={() => setToast(null)} />}
    </div>
  )
}
