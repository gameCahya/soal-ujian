"use client"

import { useEffect, useState, useCallback } from "react"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabase"
import Toast from "@/components/Toast"
import ThemeToggle from "@/components/ThemeToggle"
import { driver } from "driver.js"
import "driver.js/dist/driver.css"
import {
  ArrowLeft, CircleHelp, BookOpen,
  User, Phone, Building2, GraduationCap,
  BookMarked, CreditCard, Hash, Check, ArrowRight,
} from "lucide-react"

interface PsatGuruData {
  id: string
  profile_id: string
  whatsapp: string | null
  no_rekening: string | null
  bank: string | null
  unit_sekolah: string | null
  mapel_id: string | null
}

interface MataPelajaran {
  id: string
  nama: string
  kode: string
}

const UNIT_OPTIONS = [
  "SMP I Al Abidin Surakarta",
  "SMP ABBS Surakarta",
  "SMPII Al Abidin Karanganyar",
  "SMPII Al Abidin Sukoharjo",
  "SMPII Al Abidin Klaten",
  "SMPII Al Abidin Boyolali",
  "SMPII Al Abidin Yogyakarta",
  "SMPII Al Abidin Salatiga",
]

const BANK_OPTIONS = ["CIMB", "MayBank"]

/* shared input style */
const inputBase = (hasError: boolean): React.CSSProperties => ({
  width: "100%",
  padding: "13px 16px",
  borderRadius: "14px",
  border: `1.5px solid ${hasError ? "#FFA6C5" : "var(--pp-ink)"}`,
  backgroundColor: hasError ? "#FFF0F5" : "var(--pp-card)",
  fontSize: "14px",
  color: "var(--pp-ink)",
  outline: "none",
  fontFamily: "inherit",
  boxSizing: "border-box" as const,
  transition: "border-color 0.15s, box-shadow 0.15s",
})

export default function ProfilePage() {
  const router = useRouter()
  const [user, setUser]               = useState<any>(null)
  const [role, setRole]               = useState<string>("guru")
  const [mataPelajaran, setMataPelajaran] = useState<MataPelajaran[]>([])
  const [loading, setLoading]         = useState(true)
  const [saving, setSaving]           = useState(false)
  const [toast, setToast]             = useState<{ message: string; type: "success" | "error" | "info" } | null>(null)
  const [errors, setErrors]           = useState<Record<string, boolean>>({})

  const [nama, setNama]               = useState("")
  const [noHp, setNoHp]               = useState("")
  const [noRekening, setNoRekening]   = useState("")
  const [bank, setBank]               = useState("")
  const [unitSekolah, setUnitSekolah] = useState("")
  const [kelas, setKelas]             = useState("")
  const [mapelId, setMapelId]         = useState("")

  const isValidator = role === "validator"
  const isAdmin     = role === "admin"
  const isGuruRole  = !isValidator && !isAdmin

  /* ── Driver.js tour ── */
  const startTour = useCallback(() => {
    const guruSteps = [
      { element: "#tour-profile-header", popover: { title: "Profil Saya", description: "Halaman ini untuk melengkapi data diri kamu. Data ini wajib diisi sebelum bisa mengisi matrix dan soal.", side: "bottom" as const } },
      { element: "#tour-nama", popover: { title: "Nama Lengkap", description: "Isi nama lengkap kamu sesuai identitas resmi.", side: "bottom" as const } },
      { element: "#tour-nohp", popover: { title: "Nomor HP", description: "Nomor WhatsApp aktif yang bisa dihubungi.", side: "bottom" as const } },
      { element: "#tour-unit", popover: { title: "Unit Sekolah", description: "Pilih unit sekolah tempat kamu mengajar.", side: "bottom" as const } },
      { element: "#tour-kelas", popover: { title: "Kelas", description: "Pilih kelas yang kamu ampu (7, 8, atau 9).", side: "bottom" as const } },
      { element: "#tour-mapel", popover: { title: "Mata Pelajaran", description: "Pilih mata pelajaran yang kamu ajarkan.", side: "top" as const } },
      { element: "#tour-bank", popover: { title: "Bank & No. Rekening", description: "Isi informasi rekening untuk keperluan pembayaran honorarium.", side: "top" as const } },
      { element: "#tour-simpan", popover: { title: "Simpan Data", description: "Setelah semua terisi, klik Simpan. Kamu akan diarahkan kembali ke dashboard.", side: "top" as const } },
    ]
    const validatorSteps = [
      { element: "#tour-profile-header", popover: { title: "Profil Saya", description: "Lengkapi data diri kamu sebelum bisa mulai memvalidasi soal.", side: "bottom" as const } },
      { element: "#tour-nama", popover: { title: "Nama Lengkap", description: "Isi nama lengkap kamu. Nama ini akan muncul di catatan validasi.", side: "bottom" as const } },
      { element: "#tour-nohp", popover: { title: "Nomor HP", description: "Nomor WhatsApp aktif yang bisa dihubungi.", side: "bottom" as const } },
      { element: "#tour-unit", popover: { title: "Unit Sekolah", description: "Pilih unit sekolah tempat kamu bertugas.", side: "bottom" as const } },
      { element: "#tour-bank", popover: { title: "Bank & No. Rekening", description: "Isi informasi rekening untuk keperluan pembayaran honorarium validasi.", side: "top" as const } },
      { element: "#tour-simpan", popover: { title: "Simpan Data", description: "Setelah terisi, klik Simpan. Kamu langsung bisa mulai memvalidasi soal.", side: "top" as const } },
    ]
    driver({ showProgress: true, steps: isValidator ? validatorSteps : guruSteps, nextBtnText: "Lanjut →", prevBtnText: "← Kembali", doneBtnText: "Selesai", progressText: "{{current}} dari {{total}}" }).drive()
  }, [isValidator])

  /* ── Load data ── */
  useEffect(() => {
    async function load() {
      const { data: { user: u } } = await supabase.auth.getUser()
      if (!u) { router.push("/login"); return }
      setUser(u)

      const { data: mapelData } = await supabase.from("mata_pelajaran").select("id, nama, kode").order("nama")
      if (mapelData) setMataPelajaran(mapelData)

      // Profil tidak lagi dibuat sendiri di sini — keanggotaan PSAT datang dari
      // flag di LMS. Kalau kosong, dashboard yang menjelaskan sebabnya.
      const { data: profileData } = await supabase.from("profiles").select("*").eq("id", u.id).maybeSingle()
      if (!profileData) { router.push("/dashboard"); return }

      const userRole = profileData?.role || "guru"
      setRole(userRole)
      setNama(profileData?.nama || u.user_metadata?.nama || "")
      setNoHp(profileData?.no_hp || u.user_metadata?.no_hp || "")
      setKelas(profileData?.kelas || "")

      const { data } = await supabase.from("psat_guru_data").select("*").eq("profile_id", u.id).maybeSingle()
      if (data) {
        setNoRekening(data.no_rekening || "")
        setBank(data.bank || "")
        setUnitSekolah(data.unit_sekolah || "")
        setMapelId(data.mapel_id || "")
      }
      setLoading(false)
    }
    load()
  }, [router])

  useEffect(() => {
    if (loading) return
    const key = `profile_tour_done_${role}`
    if (!localStorage.getItem(key)) {
      localStorage.setItem(key, "1")
      setTimeout(() => startTour(), 600)
    }
  }, [loading, role, startTour])

  /* ── Save ── */
  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault()
    setSaving(true)

    const fieldErrors: Record<string, boolean> = {
      nama: !nama.trim(),
      noHp: !noHp.trim(),
      unitSekolah: !unitSekolah,
      bank: !bank,
      noRekening: !noRekening.trim(),
    }
    if (isGuruRole) {
      fieldErrors.kelas   = !kelas
      fieldErrors.mapelId = !mapelId
    }
    setErrors(fieldErrors)

    if (Object.values(fieldErrors).some(Boolean)) {
      setToast({ message: "Lengkapi semua field yang ditandai.", type: "error" })
      setSaving(false)
      return
    }

    const { error: profileError } = await supabase
      .from("profiles")
      .update({ nama, no_hp: noHp, kelas: isGuruRole ? kelas : null })
      .eq("id", user.id)

    if (profileError) {
      setToast({ message: "Gagal simpan profil: " + profileError.message, type: "error" })
      setSaving(false)
      return
    }

    const { data: existing } = await supabase.from("psat_guru_data").select("id").eq("profile_id", user.id).maybeSingle()
    const payload = { whatsapp: noHp, no_rekening: noRekening, bank, unit_sekolah: unitSekolah, mapel_id: isGuruRole ? (mapelId || null) : null }

    let guruError
    if (existing) {
      const { error } = await supabase.from("psat_guru_data").update({ ...payload, updated_at: new Date().toISOString() }).eq("id", existing.id)
      guruError = error
    } else {
      const { error } = await supabase.from("psat_guru_data").insert({ profile_id: user.id, ...payload })
      guruError = error
    }

    if (guruError) {
      setToast({ message: "Gagal simpan data: " + guruError.message, type: "error" })
      setSaving(false)
      return
    }

    setSaving(false)
    setToast({ message: "Data berhasil disimpan!", type: "success" })
    setTimeout(() => router.push("/dashboard"), 1500)
  }

  /* ── Loading ── */
  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center" style={{ backgroundColor: "var(--pp-bg)" }}>
        <div className="font-display font-semibold text-xl" style={{ color: "var(--pp-ink)" }}>Memuat...</div>
      </div>
    )
  }

  const roleBadge = isAdmin
    ? { label: "Admin",     bg: "#FFD9E6", color: "#6B0E33", border: "#FFA6C5" }
    : isValidator
    ? { label: "Validator", bg: "#DAF5E7", color: "#0E4A2F", border: "#9DE3C4" }
    : { label: "Guru",      bg: "#ECE4FF", color: "#2E1A6B", border: "#C9B8FF" }

  /* initial avatar */
  const initial = (nama || user?.email || "?")[0].toUpperCase()
  const AVATAR_BG = ["#FFB68A","#9DE3C4","#C9B8FF","#FFE072","#FFA6C5"]
  const AVATAR_FG = ["#6B2D00","#0E4A2F","#2E1A6B","#5A4500","#6B0E33"]
  const ai = initial.charCodeAt(0) % 5
  const avatarBg = AVATAR_BG[ai], avatarFg = AVATAR_FG[ai]

  return (
    <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh" }}>

      {/* ── Header ── */}
      <header className="sticky top-0 z-10" style={{ backgroundColor: "var(--pp-card)", borderBottom: "1px solid var(--pp-line)" }}>
        <div className="max-w-3xl mx-auto px-6 py-4 flex items-center justify-between gap-4">
          <div id="tour-profile-header" className="flex items-center gap-3">
            {/* Brand mark */}
            <div style={{
              width: "44px", height: "44px", borderRadius: "14px",
              backgroundColor: "var(--pp-primary)",
              display: "grid", placeItems: "center",
              color: "white", position: "relative",
              boxShadow: "0 4px 0 0 #1A2F8B", flexShrink: 0,
            }}>
              <BookOpen className="w-5 h-5" />
              <div style={{ position: "absolute", inset: "6px", borderRadius: "10px", border: "1.5px dashed rgba(255,255,255,0.45)", pointerEvents: "none" }} />
            </div>
            <div>
              <div className="font-bold text-sm leading-tight" style={{ color: "var(--pp-ink)" }}>Profil Saya</div>
              <div className="text-xs mt-0.5" style={{ color: "var(--pp-muted)" }}>Lengkapi data diri sebelum melanjutkan</div>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <div className="[&_button]:rounded-full [&_button]:text-xs"><ThemeToggle /></div>
            <button
              onClick={startTour}
              className="flex items-center gap-1.5 text-sm font-medium px-3 py-2 rounded-full"
              style={{
                border: "1.5px solid var(--pp-ink)",
                backgroundColor: "var(--pp-card)",
                color: "var(--pp-ink)",
                boxShadow: "2px 2px 0 0 var(--pp-ink)",
                cursor: "pointer", fontFamily: "inherit",
              }}
              title="Panduan pengisian profil"
            >
              <CircleHelp className="w-4 h-4" />
              <span className="hidden sm:inline">Panduan</span>
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-3xl mx-auto px-6 py-8">

        {/* Back link */}
        <button
          onClick={() => router.push("/dashboard")}
          className="flex items-center gap-1.5 text-sm mb-6"
          style={{ color: "var(--pp-ink-2)", background: "none", border: "none", cursor: "pointer", padding: 0, fontFamily: "inherit" }}
        >
          <ArrowLeft className="w-4 h-4" />
          Kembali ke dashboard
        </button>

        <div className="rounded-[22px] overflow-hidden shadow-hard-lg" style={{ border: "1.5px solid var(--pp-ink)" }}>

          {/* Card header band */}
          <div className="px-8 py-6 flex items-center gap-4"
               style={{ backgroundColor: "#FFF5C6", borderBottom: "1.5px solid var(--pp-ink)" }}>
            <div style={{
              width: "56px", height: "56px", borderRadius: "50%",
              backgroundColor: avatarBg, color: avatarFg,
              display: "grid", placeItems: "center",
              fontWeight: 700, fontSize: "22px",
              border: "1.5px solid var(--pp-ink)", flexShrink: 0,
            }}>
              {initial}
            </div>
            <div>
              <h2 className="font-display font-semibold" style={{ fontSize: "20px", color: "var(--pp-head-ink)", margin: 0 }}>
                {nama || "Belum diisi"}
              </h2>
              <div className="flex items-center gap-2 mt-1.5 flex-wrap">
                <span style={{ fontSize: "13px", color: "var(--pp-ink-2)" }}>{user?.email}</span>
                <span style={{
                  fontSize: "11px", fontWeight: 700, padding: "2px 9px", borderRadius: "999px",
                  backgroundColor: roleBadge.bg, color: roleBadge.color,
                  border: `1px solid ${roleBadge.border}`,
                  textTransform: "uppercase", letterSpacing: "0.08em",
                }}>
                  {roleBadge.label}
                </span>
              </div>
            </div>
          </div>

          {/* Form */}
          <form onSubmit={handleSave} style={{ backgroundColor: "var(--pp-card)" }}>

            {/* ── Informasi Diri ── */}
            <Section label="Informasi Diri" icon={<User className="w-3.5 h-3.5" />}>
              <Field id="tour-nama" label="Nama Lengkap" required error={errors.nama}
                     icon={<User className="w-4 h-4" />}>
                <input
                  type="text"
                  value={nama}
                  onChange={e => { setNama(e.target.value); setErrors(p => ({ ...p, nama: false })) }}
                  placeholder="Nama lengkap sesuai identitas"
                  style={inputBase(errors.nama)}
                  onFocus={e => { e.currentTarget.style.borderColor = "var(--pp-primary)"; e.currentTarget.style.boxShadow = "3px 3px 0 0 var(--pp-primary)" }}
                  onBlur={e => { e.currentTarget.style.borderColor = errors.nama ? "#FFA6C5" : "var(--pp-ink)"; e.currentTarget.style.boxShadow = "none" }}
                />
              </Field>

              <Field label="Email" icon={<Hash className="w-4 h-4" />}>
                <input
                  type="email"
                  value={user?.email || ""}
                  readOnly
                  style={{ ...inputBase(false), opacity: 0.5, cursor: "not-allowed" }}
                />
              </Field>

              <Field id="tour-nohp" label="Nomor HP / WhatsApp" required error={errors.noHp}
                     icon={<Phone className="w-4 h-4" />}>
                <input
                  type="tel"
                  value={noHp}
                  onChange={e => { setNoHp(e.target.value); setErrors(p => ({ ...p, noHp: false })) }}
                  placeholder="08123456789"
                  style={inputBase(errors.noHp)}
                  onFocus={e => { e.currentTarget.style.borderColor = "var(--pp-primary)"; e.currentTarget.style.boxShadow = "3px 3px 0 0 var(--pp-primary)" }}
                  onBlur={e => { e.currentTarget.style.borderColor = errors.noHp ? "#FFA6C5" : "var(--pp-ink)"; e.currentTarget.style.boxShadow = "none" }}
                />
              </Field>
            </Section>

            {/* ── Data Sekolah ── */}
            <Section label="Data Sekolah" icon={<Building2 className="w-3.5 h-3.5" />}>
              <Field id="tour-unit" label="Unit Sekolah" required error={errors.unitSekolah}
                     icon={<Building2 className="w-4 h-4" />}>
                <select
                  value={unitSekolah}
                  onChange={e => { setUnitSekolah(e.target.value); setErrors(p => ({ ...p, unitSekolah: false })) }}
                  style={inputBase(errors.unitSekolah)}
                >
                  <option value="">Pilih Unit Sekolah</option>
                  {UNIT_OPTIONS.map(u => <option key={u} value={u}>{u}</option>)}
                </select>
              </Field>

              {isGuruRole && (
                <>
                  <Field id="tour-kelas" label="Kelas" required error={errors.kelas}
                         icon={<GraduationCap className="w-4 h-4" />}>
                    <select
                      value={kelas}
                      onChange={e => { setKelas(e.target.value); setErrors(p => ({ ...p, kelas: false })) }}
                      style={inputBase(errors.kelas)}
                    >
                      <option value="">Pilih Kelas</option>
                      <option value="7">Kelas 7</option>
                      <option value="8">Kelas 8</option>
                      <option value="9">Kelas 9</option>
                    </select>
                  </Field>

                  <Field id="tour-mapel" label="Mata Pelajaran" required error={errors.mapelId}
                         icon={<BookMarked className="w-4 h-4" />}>
                    <select
                      value={mapelId}
                      onChange={e => { setMapelId(e.target.value); setErrors(p => ({ ...p, mapelId: false })) }}
                      style={inputBase(errors.mapelId)}
                    >
                      <option value="">Pilih Mata Pelajaran</option>
                      {mataPelajaran.map(m => (
                        <option key={m.id} value={m.id}>{m.nama}{m.kode ? ` (${m.kode})` : ""}</option>
                      ))}
                    </select>
                  </Field>
                </>
              )}
            </Section>

            {/* ── Data Rekening ── */}
            <div id="tour-bank">
              <Section label="Data Rekening" icon={<CreditCard className="w-3.5 h-3.5" />} last>
                <Field label="Bank" required error={errors.bank} icon={<CreditCard className="w-4 h-4" />}>
                  <select
                    value={bank}
                    onChange={e => { setBank(e.target.value); setErrors(p => ({ ...p, bank: false })) }}
                    style={inputBase(errors.bank)}
                  >
                    <option value="">Pilih Bank</option>
                    {BANK_OPTIONS.map(b => <option key={b} value={b}>{b}</option>)}
                  </select>
                </Field>

                <Field label="Nomor Rekening" required error={errors.noRekening}
                       icon={<Hash className="w-4 h-4" />}>
                  <input
                    type="text"
                    value={noRekening}
                    onChange={e => { setNoRekening(e.target.value); setErrors(p => ({ ...p, noRekening: false })) }}
                    placeholder="Nomor rekening"
                    style={inputBase(errors.noRekening)}
                    onFocus={e => { e.currentTarget.style.borderColor = "var(--pp-primary)"; e.currentTarget.style.boxShadow = "3px 3px 0 0 var(--pp-primary)" }}
                    onBlur={e => { e.currentTarget.style.borderColor = errors.noRekening ? "#FFA6C5" : "var(--pp-ink)"; e.currentTarget.style.boxShadow = "none" }}
                  />
                </Field>
              </Section>
            </div>

            {/* ── Action buttons ── */}
            <div id="tour-simpan" className="px-8 py-6 flex gap-3"
                 style={{ borderTop: "1.5px solid var(--pp-line)" }}>
              <button
                type="submit"
                disabled={saving}
                className="flex items-center justify-center gap-2 font-semibold disabled:opacity-50"
                style={{
                  flex: 1, padding: "14px 18px", borderRadius: "14px",
                  backgroundColor: "var(--pp-head-ink)", color: "white",
                  border: "none", fontSize: "14px", letterSpacing: "0.02em",
                  boxShadow: "0 4px 0 0 rgba(0,0,0,0.4)",
                  cursor: saving ? "not-allowed" : "pointer",
                  fontFamily: "inherit",
                }}
                onMouseDown={e => { if (!saving) { e.currentTarget.style.transform = "translateY(2px)"; e.currentTarget.style.boxShadow = "0 2px 0 0 rgba(0,0,0,0.4)" }}}
                onMouseUp={e => { e.currentTarget.style.transform = ""; e.currentTarget.style.boxShadow = "0 4px 0 0 rgba(0,0,0,0.4)" }}
                onMouseLeave={e => { e.currentTarget.style.transform = ""; e.currentTarget.style.boxShadow = "0 4px 0 0 rgba(0,0,0,0.4)" }}
              >
                {saving ? "Menyimpan..." : (
                  <><Check className="w-4 h-4" /> Simpan Data</>
                )}
              </button>

              <button
                type="button"
                onClick={() => router.push("/dashboard")}
                className="flex items-center gap-2 font-medium"
                style={{
                  padding: "14px 18px", borderRadius: "14px",
                  border: "1.5px solid var(--pp-ink)",
                  backgroundColor: "var(--pp-card)",
                  color: "var(--pp-ink)", fontSize: "14px",
                  cursor: "pointer", fontFamily: "inherit",
                  whiteSpace: "nowrap",
                }}
              >
                Nanti Saja
                <ArrowRight className="w-4 h-4" />
              </button>
            </div>
          </form>
        </div>
      </main>

      {toast && <Toast message={toast.message} type={toast.type} onClose={() => setToast(null)} />}
    </div>
  )
}

/* ── Sub-components ── */

function Section({ label, icon, children, last }: {
  label: string
  icon: React.ReactNode
  children: React.ReactNode
  last?: boolean
}) {
  return (
    <div className="px-8 py-6 space-y-4"
         style={{ borderBottom: last ? "none" : "1.5px solid var(--pp-line)" }}>
      <div className="flex items-center gap-2 mb-5">
        <div style={{
          width: "24px", height: "24px", borderRadius: "6px",
          backgroundColor: "#FFE3D0", color: "#6B2D00",
          display: "grid", placeItems: "center", flexShrink: 0,
        }}>
          {icon}
        </div>
        <span style={{
          fontSize: "11px", fontWeight: 700,
          textTransform: "uppercase", letterSpacing: "0.1em",
          color: "var(--pp-ink-2)",
        }}>
          {label}
        </span>
        <div style={{ flex: 1, height: "1px", backgroundColor: "var(--pp-line)" }} />
      </div>
      {children}
    </div>
  )
}

function Field({ id, label, required, error, icon, children }: {
  id?: string
  label: string
  required?: boolean
  error?: boolean
  icon?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <div id={id}>
      <label className="flex items-center gap-1.5 mb-1.5 font-semibold uppercase"
             style={{ fontSize: "11px", color: error ? "#6B0E33" : "var(--pp-ink-2)", letterSpacing: "0.1em" }}>
        {icon && (
          <span style={{ color: error ? "#FFA6C5" : "var(--pp-muted)", flexShrink: 0 }}>{icon}</span>
        )}
        {label}
        {required && <span style={{ color: "#FFA6C5" }}>*</span>}
      </label>
      {children}
      {error && (
        <p className="mt-1 text-xs" style={{ color: "#6B0E33" }}>Field ini wajib diisi</p>
      )}
    </div>
  )
}
