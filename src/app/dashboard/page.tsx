"use client"

import { useEffect, useState } from "react"
import { useRouter } from "next/navigation"
import {
  Check, X,
  User, LayoutGrid, PenSquare, FileText,
  CheckSquare, Settings, Users, Bell,
  AlertCircle, CheckCircle, Lightbulb,
  LogOut, Lock, BookOpen, ArrowRight,
} from "lucide-react"
import { supabase } from "@/lib/supabase"
import ThemeToggle from "@/components/ThemeToggle"

const TIPE_OPTIONS     = ["pilgan", "ceklist", "essay"]
const KESULITAN_OPTIONS = ["mudah", "sedang", "sulit"]

interface UserData {
  id: string
  email: string
  nama: string | null
  username: string | null
  role: string | null
}

/* ── pastel colours per card slot ── */
const GURU_STEP_COLORS = [
  { bg: "#ECE4FF", iconBg: "#C9B8FF", iconColor: "#2E1A6B", blob: "#C9B8FF", border: "#C9B8FF" }, // lilac — Profil
  { bg: "#FFF5C6", iconBg: "#FFE072", iconColor: "#5A4500", blob: "#FFE072", border: "#FFE072" }, // lemon — Matrix
  { bg: "#DAF5E7", iconBg: "#9DE3C4", iconColor: "#0E4A2F", blob: "#9DE3C4", border: "#9DE3C4" }, // mint  — Soal
  { bg: "#FFE3D0", iconBg: "#FFB68A", iconColor: "#6B2D00", blob: "#FFB68A", border: "#FFB68A" }, // peach — Dokumen
]

const ADMIN_MENU_COLORS = [
  { bg: "#DAF5E7", iconBg: "#9DE3C4", iconColor: "#0E4A2F" }, // mint  — Validasi
  { bg: "#FFF5C6", iconBg: "#FFE072", iconColor: "#5A4500" }, // lemon — Patokan
  { bg: "#FFE3D0", iconBg: "#FFB68A", iconColor: "#6B2D00" }, // peach — Mapel
  { bg: "#ECE4FF", iconBg: "#C9B8FF", iconColor: "#2E1A6B" }, // lilac — Matrix
  { bg: "#FFD9E6", iconBg: "#FFA6C5", iconColor: "#6B0E33" }, // pink  — Users
]

const STAT_VARIANTS = [
  { bg: "#ECE4FF", iconBg: "#C9B8FF", iconColor: "#2E1A6B", blob: "#C9B8FF" }, // Total   lilac
  { bg: "#FFF5C6", iconBg: "#FFE072", iconColor: "#5A4500", blob: "#FFE072" }, // Draft   lemon
  { bg: "#FFE3D0", iconBg: "#FFB68A", iconColor: "#6B2D00", blob: "#FFB68A" }, // Subm.   peach
  { bg: "#DAF5E7", iconBg: "#9DE3C4", iconColor: "#0E4A2F", blob: "#9DE3C4" }, // Approv. mint
  { bg: "#FFD9E6", iconBg: "#FFA6C5", iconColor: "#6B0E33", blob: "#FFA6C5" }, // Revisi  pink
]

const AVATAR_BG = ["#FFB68A","#9DE3C4","#C9B8FF","#FFE072","#FFA6C5"]
const AVATAR_FG = ["#6B2D00","#0E4A2F","#2E1A6B","#5A4500","#6B0E33"]

function getAvatarColors(name: string | null | undefined) {
  const idx = name ? name.charCodeAt(0) % 5 : 0
  return { bg: AVATAR_BG[idx], color: AVATAR_FG[idx] }
}

export default function DashboardPage() {
  const router = useRouter()
  const [user, setUser]                         = useState<UserData | null>(null)
  const [hasProfile, setHasProfile]             = useState(false)
  const [noAccess, setNoAccess]                 = useState(false)
  const [hasValidatorProfile, setHasValidatorProfile] = useState(false)
  const [hasMatrix, setHasMatrix]               = useState(false)
  const [submittedCount, setSubmittedCount]     = useState(0)
  const [approvedCount, setApprovedCount]       = useState(0)
  const [revisionCount, setRevisionCount]       = useState(0)
  const [mapelCounts, setMapelCounts]           = useState<Record<string, number>>({})
  const [mapelNames, setMapelNames]             = useState<Record<string, string>>({})
  const [guruSoalStats, setGuruSoalStats]       = useState({ total: 0, submitted: 0, approved: 0, needs_revision: 0, draft: 0 })
  const [soalCounts, setSoalCounts]             = useState<Record<string, number>>({})
  const [patokan, setPatokan]                   = useState<Record<string, number>>({})
  const [targetBank, setTargetBank]             = useState(0)
  const [loading, setLoading]                   = useState(true)

  useEffect(() => {
    async function checkAuth() {
      const { data: { user: u } } = await supabase.auth.getUser()
      if (!u) { router.push("/login"); return }

      const { data: profileData, error: profileQueryError } = await supabase
        .from("profiles").select("role").eq("id", u.id).maybeSingle()
      if (profileQueryError) console.error("Query profile error:", profileQueryError)

      // Sejak identitas PSAT disatukan dengan LMS, keanggotaan ditentukan flag
      // "Penulis Soal" yang dinyalakan admin di LMS — profil tidak lagi dibuat
      // sendiri saat login pertama. Tanpa gerbang ini dashboard tetap terbuka
      // tapi semua query balik kosong, dan guru tidak tahu kenapa.
      if (!profileData) {
        setNoAccess(true)
        setLoading(false)
        return
      }

      const { data: fullProfile } = await supabase
        .from("profiles").select("nama, role, no_hp, kelas").eq("id", u.id).maybeSingle()

      setUser({
        id: u.id, email: u.email || "",
        nama: u.user_metadata?.nama || fullProfile?.nama || null,
        username: u.user_metadata?.username || null,
        role: fullProfile?.role || "guru",
      })

      const { data: guruData } = await supabase
        .from("psat_guru_data").select("bank, no_rekening, unit_sekolah, mapel_id").eq("profile_id", u.id).maybeSingle()

      const namaOk = !!fullProfile?.nama && fullProfile.nama !== u.id
      setHasProfile(namaOk && !!fullProfile?.no_hp && !!fullProfile?.kelas &&
        !!guruData?.unit_sekolah && !!guruData?.mapel_id && !!guruData?.bank && !!guruData?.no_rekening)

      const vRole = fullProfile?.role || "guru"
      if (vRole === "validator" || vRole === "admin") {
        const { data: vGuruData } = await supabase
          .from("psat_guru_data").select("bank, no_rekening, unit_sekolah").eq("profile_id", u.id).maybeSingle()
        setHasValidatorProfile(namaOk && !!fullProfile?.no_hp && !!vGuruData?.unit_sekolah && !!vGuruData?.bank && !!vGuruData?.no_rekening)
      }

      let validatorMapelIds: string[] | null = null
      if (vRole === "validator") {
        const { data: vmRows } = await supabase
          .from("psat_validator_mapel").select("mapel_id").eq("validator_id", u.id)
        validatorMapelIds = vmRows?.map((r: any) => r.mapel_id) ?? []
      }

      const { data: matrix } = await supabase
        .from("psat_matrix_input").select("id").eq("profile_id", u.id).eq("is_submitted", true)
      setHasMatrix(!!matrix && matrix.length > 0)

      const [{ count: sub }, { count: app }, { count: rev }] = await Promise.all([
        supabase.from("bank_soal").select("*", { count: "exact", head: true }).eq("status", "submitted"),
        supabase.from("bank_soal").select("*", { count: "exact", head: true }).eq("status", "approved"),
        supabase.from("bank_soal").select("*", { count: "exact", head: true }).eq("status", "needs_revision"),
      ])
      setSubmittedCount(sub || 0)
      setApprovedCount(app || 0)
      setRevisionCount(rev || 0)

      const { data: submittedByMapel } = await supabase
        .from("bank_soal").select("mata_pelajaran_id").eq("status", "submitted")
      const counts: Record<string, number> = {}
      const names: Record<string, string> = {}
      if (submittedByMapel) {
        submittedByMapel.forEach(s => { if (s.mata_pelajaran_id) counts[s.mata_pelajaran_id] = (counts[s.mata_pelajaran_id] || 0) + 1 })
        const { data: mapels } = await supabase.from("mata_pelajaran").select("id, nama")
        mapels?.forEach(m => { names[m.id] = m.nama })
      }
      if (validatorMapelIds !== null) {
        Object.keys(counts).forEach(mapelId => {
          if (!validatorMapelIds!.includes(mapelId)) delete counts[mapelId]
        })
      }
      setMapelCounts(counts)
      setMapelNames(names)

      if (guruData?.mapel_id) {
        const { data: patokanRows } = await supabase
          .from("psat_patokan_soal").select("*").eq("mapel_id", guruData.mapel_id)
          .order("created_at", { ascending: false }).limit(1)
        const pd = patokanRows?.[0]
        if (pd) {
          const p: Record<string, number> = {}
          const tipes = (pd.tipe || "").split(",")
          const tingkatans = (pd.tingkat_kesulitan || "").split(",")
          const keluarArr = (pd.keluar || "").split(",")
          const bankArr = (pd.bank || "").split(",")
          let i = 0
          tipes.forEach((t: string) => tingkatans.forEach((k: string) => {
            p[`${t}_${k}_keluar`] = parseInt(keluarArr[i]) || 0
            p[`${t}_${k}_bank`]   = parseInt(bankArr[i])   || 0
            i++
          }))
          setPatokan(p)
        }
      }

      const { data: guruSoal } = await supabase
        .from("bank_soal").select("status, tipe, tingkat_kesulitan").eq("guru_id", u.id)
      if (guruSoal) {
        const stats = { total: guruSoal.length, submitted: 0, approved: 0, needs_revision: 0, draft: 0 }
        const sc: Record<string, number> = {}
        guruSoal.forEach(s => {
          if (s.status === "submitted")      stats.submitted++
          else if (s.status === "approved")  stats.approved++
          else if (s.status === "needs_revision") stats.needs_revision++
          else stats.draft++
          if (s.tipe && s.tingkat_kesulitan) {
            const key = `${s.tipe}_${s.tingkat_kesulitan}`
            sc[key] = (sc[key] || 0) + 1
          }
        })
        setGuruSoalStats(stats)
        setSoalCounts(sc)
      }

      const { data: matrixBabs } = await supabase
        .from("psat_matrix_input").select("data").eq("profile_id", u.id).eq("is_submitted", true)
      if (matrixBabs) {
        let total = 0
        matrixBabs.forEach(bab => { if (bab.data) Object.keys(bab.data).forEach(k => { if (k.endsWith("_bank")) total += bab.data[k] || 0 }) })
        setTargetBank(total)
      }

      setLoading(false)
    }
    checkAuth()
  }, [router])

  const handleLogout = async () => {
    await supabase.auth.signOut()
    router.push("/login")
  }

  const goTo = (path: string, blocked?: boolean, requireMatrix?: boolean) => {
    if (blocked) { alert("Lengkapi data diri terlebih dahulu!"); return }
    if (requireMatrix && !hasMatrix) { alert("Selesaikan matrix terlebih dahulu sebelum input soal!"); return }
    router.push(path)
  }

  /* ── Belum diberi akses PSAT ── */
  if (noAccess) {
    return (
      <div className="min-h-screen flex items-center justify-center px-5" style={{ backgroundColor: "var(--pp-bg)" }}>
        <div
          className="w-full max-w-[420px] text-center"
          style={{
            padding: "32px 28px",
            borderRadius: "18px",
            border: "1.5px solid var(--pp-ink)",
            backgroundColor: "var(--pp-card)",
            boxShadow: "5px 5px 0 0 var(--pp-ink)",
          }}
        >
          <Lock className="mx-auto mb-4 w-8 h-8" style={{ color: "var(--pp-ink)" }} />
          <div className="font-display font-semibold text-xl mb-2" style={{ color: "var(--pp-ink)" }}>
            Akun Anda belum diberi akses
          </div>
          <p className="mb-6" style={{ color: "var(--pp-muted)", fontSize: "14px", lineHeight: 1.55 }}>
            Login Anda berhasil, tetapi akun ini belum ditandai sebagai penulis soal.
            Minta admin menyalakan <strong>Soal PSAT &rarr; Tulis</strong> pada data guru Anda di LMS,
            lalu masuk lagi.
          </p>
          <button
            onClick={handleLogout}
            style={{
              width: "100%",
              padding: "12px 16px",
              borderRadius: "14px",
              border: "1.5px solid var(--pp-ink)",
              backgroundColor: "var(--pp-card)",
              fontSize: "14px",
              fontWeight: 600,
              color: "var(--pp-ink)",
              cursor: "pointer",
              fontFamily: "inherit",
            }}
          >
            Keluar
          </button>
        </div>
      </div>
    )
  }

  /* ── Loading ── */
  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center" style={{ backgroundColor: "var(--pp-bg)" }}>
        <div className="text-center space-y-3">
          <div className="font-display font-semibold text-2xl" style={{ color: "var(--pp-ink)" }}>Memuat...</div>
          <div style={{ color: "var(--pp-muted)", fontSize: "14px" }}>Menyiapkan dashboard Anda</div>
        </div>
      </div>
    )
  }

  const userRole  = user?.role || "guru"
  const isAdmin   = userRole === "admin"
  const isValidator = userRole === "validator"

  const avatarCol = getAvatarColors(user?.nama)
  const displayName = user?.nama || user?.username || userRole

  /* ── Role badge ── */
  const roleBadge = isAdmin
    ? { label: "Admin", bg: "#FFD9E6", color: "#6B0E33", border: "#FFA6C5" }
    : isValidator
    ? { label: "Validator", bg: "#DAF5E7", color: "#0E4A2F", border: "#9DE3C4" }
    : { label: "Guru", bg: "#ECE4FF", color: "#2E1A6B", border: "#C9B8FF" }

  /* ── Admin/Validator menu items ── */
  const adminMenuItems = [
    ...(isValidator ? [{
      icon: <User className="w-5 h-5" />,
      label: "Profil",
      desc: hasValidatorProfile ? "Data diri lengkap" : "Lengkapi data diri dulu",
      done: hasValidatorProfile,
      locked: false,
      path: "/dashboard/profile",
      ci: ADMIN_MENU_COLORS[0],
    }] : []),
    {
      icon: <CheckSquare className="w-5 h-5" />,
      label: "Validasi",
      desc: isAdmin || hasValidatorProfile ? "Review & approve soal" : "Lengkapi profil dulu",
      done: false,
      locked: !isAdmin && !hasValidatorProfile,
      path: "/dashboard/validasi",
      ci: ADMIN_MENU_COLORS[0],
    },
    ...(isAdmin ? [
      {
        icon: <Settings className="w-5 h-5" />,
        label: "Patokan Soal",
        desc: "Atur target soal per mapel",
        done: false, locked: false,
        path: "/dashboard/patokan",
        ci: ADMIN_MENU_COLORS[1],
      },
      {
        icon: <BookOpen className="w-5 h-5" />,
        label: "Mata Pelajaran",
        desc: "Kelola daftar mata pelajaran",
        done: false, locked: false,
        path: "/dashboard/admin/mapel",
        ci: ADMIN_MENU_COLORS[2],
      },
      {
        icon: <LayoutGrid className="w-5 h-5" />,
        label: "Matrix Guru",
        desc: "Kelola & hapus matrix guru",
        done: false, locked: false,
        path: "/dashboard/admin/matrix",
        ci: ADMIN_MENU_COLORS[3],
      },
      {
        icon: <Users className="w-5 h-5" />,
        label: "Users",
        desc: "Kelola users & roles",
        done: false, locked: false,
        path: "/admin/users",
        ci: ADMIN_MENU_COLORS[4],
      },
    ] : []),
  ]

  /* ── Guru steps ── */
  const guruSteps = [
    {
      step: 1, icon: <User className="w-5 h-5" />,
      label: "Profil", desc: hasProfile ? "Data diri sudah lengkap" : "Data diri (WA, Bank, Rekening)",
      done: hasProfile, locked: false, path: "/dashboard/profile", ci: GURU_STEP_COLORS[0],
    },
    {
      step: 2, icon: <LayoutGrid className="w-5 h-5" />,
      label: "Matrix", desc: hasProfile ? "Pemetaan jumlah soal" : "Lengkapi profil dulu",
      done: hasMatrix, locked: !hasProfile, path: "/dashboard/matrix", ci: GURU_STEP_COLORS[1],
    },
    {
      step: 3, icon: <PenSquare className="w-5 h-5" />,
      label: "Soal", desc: hasMatrix ? "Input soal ujian" : "Selesaikan matrix dulu",
      done: false, locked: !hasMatrix, path: "/dashboard/soal", ci: GURU_STEP_COLORS[2],
    },
    {
      step: 4, icon: <FileText className="w-5 h-5" />,
      label: "Dokumen", desc: "Kisi-kisi & Glossary",
      done: false, locked: false, path: "/dashboard/dokumen", ci: GURU_STEP_COLORS[3],
    },
  ]

  /* ── Stat cards for guru ── */
  const statCards = [
    { label: "Total",        value: guruSoalStats.total,          icon: <FileText className="w-5 h-5" />,    vi: STAT_VARIANTS[0] },
    { label: "Draft",        value: guruSoalStats.draft,          icon: <PenSquare className="w-5 h-5" />,   vi: STAT_VARIANTS[1] },
    { label: "Submitted",    value: guruSoalStats.submitted,      icon: <Bell className="w-5 h-5" />,        vi: STAT_VARIANTS[2] },
    { label: "Approved",     value: guruSoalStats.approved,       icon: <CheckCircle className="w-5 h-5" />, vi: STAT_VARIANTS[3] },
    { label: "Perlu Revisi", value: guruSoalStats.needs_revision, icon: <AlertCircle className="w-5 h-5" />, vi: STAT_VARIANTS[4] },
  ]

  const progPct = targetBank > 0 ? Math.min(100, Math.round((guruSoalStats.total / targetBank) * 100)) : 0
  const progGradient = progPct >= 80
    ? "linear-gradient(90deg,#9DE3C4,#34A86E)"
    : progPct >= 40
    ? "linear-gradient(90deg,#FFE072,#C99A14)"
    : "linear-gradient(90deg,#FFC9C9,#DC4F4F)"

  return (
    <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh" }}>

      {/* ── Header ── */}
      <header className="sticky top-0 z-10" style={{ backgroundColor: "var(--pp-card)", borderBottom: "1px solid var(--pp-line)" }}>
        <div className="max-w-7xl mx-auto px-6 md:px-8 py-4 flex items-center justify-between gap-4">
          {/* Brand */}
          <div className="flex items-center gap-3">
            <div style={{
              width: "44px", height: "44px", borderRadius: "14px",
              backgroundColor: "var(--pp-primary)",
              display: "grid", placeItems: "center",
              color: "white", position: "relative",
              boxShadow: "0 4px 0 0 #1A2F8B", flexShrink: 0,
            }}>
              <BookOpen className="w-5 h-5" />
              <div style={{
                position: "absolute", inset: "6px", borderRadius: "10px",
                border: "1.5px dashed rgba(255,255,255,0.45)", pointerEvents: "none",
              }} />
            </div>
            <div className="hidden sm:block">
              <div className="font-bold text-sm leading-tight" style={{ color: "var(--pp-ink)" }}>PSAT Dashboard</div>
              <div className="text-xs mt-0.5" style={{ color: "var(--pp-muted)" }}>Portal Validasi Soal Al Abidin</div>
            </div>
          </div>

          {/* Actions */}
          <div className="flex items-center gap-2">
            <div className="[&_button]:rounded-full [&_button]:text-xs">
              <ThemeToggle />
            </div>
            <button
              onClick={handleLogout}
              className="flex items-center gap-2 text-sm font-semibold"
              style={{
                backgroundColor: "var(--pp-ink)", color: "white",
                padding: "10px 16px", borderRadius: "999px",
                border: "none", cursor: "pointer",
                boxShadow: "0 3px 0 0 rgba(0,0,0,0.4)",
                fontFamily: "inherit",
              }}
            >
              <LogOut className="w-3.5 h-3.5" />
              <span className="hidden sm:inline">Keluar</span>
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-7xl mx-auto px-6 md:px-8 py-8 space-y-6">

        {/* ── Welcome card ── */}
        <div className="rounded-[22px] shadow-hard-md p-6 flex items-start gap-5"
             style={{ backgroundColor: "var(--pp-card)", border: "1.5px solid var(--pp-ink)" }}>
          {/* Avatar */}
          <div style={{
            width: "56px", height: "56px", borderRadius: "50%",
            backgroundColor: avatarCol.bg, color: avatarCol.color,
            display: "grid", placeItems: "center",
            fontWeight: 700, fontSize: "20px",
            border: "1.5px solid var(--pp-ink)", flexShrink: 0,
          }}>
            {(user?.nama || user?.email || "?")[0].toUpperCase()}
          </div>

          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2.5 flex-wrap">
              <h2 className="font-display font-semibold" style={{ fontSize: "22px", color: "var(--pp-ink)", margin: 0 }}>
                Selamat datang, {displayName}!
              </h2>
              <span style={{
                fontSize: "11px", fontWeight: 700,
                padding: "3px 10px", borderRadius: "999px",
                backgroundColor: roleBadge.bg, color: roleBadge.color,
                border: `1px solid ${roleBadge.border}`,
                textTransform: "uppercase", letterSpacing: "0.08em",
              }}>
                {roleBadge.label}
              </span>
            </div>
            <p className="mt-0.5 text-sm" style={{ color: "var(--pp-muted)" }}>{user?.email}</p>

            {/* Incomplete profile warning */}
            {!isAdmin && !isValidator && !hasProfile && (
              <div className="mt-3 flex items-center gap-2 px-3 py-2 rounded-lg text-sm"
                   style={{ backgroundColor: "#FFE3D0", border: "1px solid var(--pp-peach)", color: "#6B2D00" }}>
                <AlertCircle className="w-4 h-4 shrink-0" />
                Silakan lengkapi data diri terlebih dahulu untuk mulai input soal.
              </div>
            )}
            {isValidator && !hasValidatorProfile && (
              <div className="mt-3 flex items-center gap-2 px-3 py-2 rounded-lg text-sm"
                   style={{ backgroundColor: "#FFE3D0", border: "1px solid var(--pp-peach)", color: "#6B2D00" }}>
                <AlertCircle className="w-4 h-4 shrink-0" />
                Silakan lengkapi data diri sebelum mulai validasi.
              </div>
            )}

            {/* Admin/Validator: soal notification */}
            {(isAdmin || isValidator) && Object.keys(mapelCounts).length > 0 && (
              <div className="mt-4">
                <div className="flex items-center gap-2 mb-2">
                  <Bell className="w-4 h-4" style={{ color: "#C99A14" }} />
                  <span className="font-semibold text-sm" style={{ color: "var(--pp-ink)" }}>
                    {Object.values(mapelCounts).reduce((a, b) => a + b, 0)} soal menunggu validasi
                  </span>
                </div>
                <div className="flex flex-wrap gap-2">
                  {Object.entries(mapelCounts).map(([mapelId, count]) => (
                    <button
                      key={mapelId}
                      onClick={() => { localStorage.setItem("selectedMapelId", mapelId); router.push("/dashboard/validasi") }}
                      className="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium rounded-full"
                      style={{
                        backgroundColor: "#FFF5C6", border: "1.5px solid var(--pp-ink)",
                        color: "var(--pp-ink)", cursor: "pointer",
                        boxShadow: "2px 2px 0 0 var(--pp-ink)", fontFamily: "inherit",
                      }}
                    >
                      {mapelNames[mapelId] || "Mapel"}
                      <span style={{
                        backgroundColor: "var(--pp-ink)", color: "white",
                        borderRadius: "999px", padding: "1px 7px", fontSize: "11px", fontWeight: 700,
                      }}>{count}</span>
                    </button>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* ── Guru: revision / approved notifications ── */}
        {!isAdmin && !isValidator && (revisionCount > 0 || approvedCount > 0) && (
          <div className="flex gap-3 flex-wrap">
            {revisionCount > 0 && (
              <button
                onClick={() => { localStorage.setItem("soal_filter_revisi", "1"); router.push("/dashboard/soal") }}
                className="flex items-center gap-2 px-4 py-2.5 rounded-full font-medium text-sm"
                style={{
                  backgroundColor: "#FFD9E6", border: "1.5px solid var(--pp-pink)",
                  color: "#6B0E33", cursor: "pointer",
                  boxShadow: "2px 2px 0 0 var(--pp-ink)", fontFamily: "inherit",
                }}
              >
                <AlertCircle className="w-4 h-4" />
                {revisionCount} soal perlu revisi
                <ArrowRight className="w-3.5 h-3.5" />
              </button>
            )}
            {approvedCount > 0 && (
              <div className="flex items-center gap-2 px-4 py-2.5 rounded-full font-medium text-sm"
                   style={{
                     backgroundColor: "#DAF5E7", border: "1.5px solid var(--pp-mint)",
                     color: "#0E4A2F",
                   }}>
                <CheckCircle className="w-4 h-4" />
                {approvedCount} soal approved
              </div>
            )}
          </div>
        )}

        {/* ── ADMIN / VALIDATOR: menu grid ── */}
        {(isAdmin || isValidator) ? (
          <div>
            <div className="mb-4 flex items-center gap-2">
              <span style={{
                fontSize: "11px", fontWeight: 700, letterSpacing: "0.1em",
                textTransform: "uppercase", color: "var(--pp-muted)",
              }}>Menu</span>
              <div style={{ flex: 1, height: "1px", backgroundColor: "var(--pp-line)" }} />
            </div>
            <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4">
              {adminMenuItems.map(({ icon, label, desc, done, locked, path, ci }) => (
                <button
                  key={label}
                  onClick={() => goTo(path, locked)}
                  disabled={locked}
                  className="rounded-[18px] p-5 text-left group disabled:cursor-not-allowed"
                  style={{
                    backgroundColor: locked ? "var(--pp-bg)" : ci.bg,
                    border: "1.5px solid var(--pp-ink)",
                    boxShadow: locked ? "none" : "4px 4px 0 0 var(--pp-ink)",
                    opacity: locked ? 0.45 : 1,
                    cursor: locked ? "not-allowed" : "pointer",
                    fontFamily: "inherit",
                    transition: "transform 0.1s, box-shadow 0.1s",
                  }}
                  onMouseEnter={e => { if (!locked) { e.currentTarget.style.transform = "translate(-1px,-1px)"; e.currentTarget.style.boxShadow = "5px 5px 0 0 var(--pp-ink)" }}}
                  onMouseLeave={e => { e.currentTarget.style.transform = ""; e.currentTarget.style.boxShadow = locked ? "none" : "4px 4px 0 0 var(--pp-ink)" }}
                >
                  <div className="mb-4">
                    <div style={{
                      width: "38px", height: "38px", borderRadius: "12px",
                      backgroundColor: locked ? "var(--pp-muted)" : done ? "#9DE3C4" : ci.iconBg,
                      color: locked ? "white" : done ? "#0E4A2F" : ci.iconColor,
                      display: "grid", placeItems: "center",
                    }}>
                      {done ? <Check className="w-5 h-5" /> : locked ? <Lock className="w-5 h-5" /> : icon}
                    </div>
                  </div>
                  <div className="font-semibold text-sm mb-0.5" style={{ color: "var(--pp-ink)" }}>{label}</div>
                  <div className="text-xs" style={{ color: "var(--pp-ink-2)" }}>{desc}</div>
                  {!locked && (
                    <div className="mt-3 flex items-center gap-1 text-xs font-semibold" style={{ color: ci.iconColor }}>
                      Buka <ArrowRight className="w-3 h-3" />
                    </div>
                  )}
                </button>
              ))}
            </div>
          </div>
        ) : (
          <>
            {/* ── GURU: step cards ── */}
            <div>
              <div className="mb-4 flex items-center gap-2">
                <span style={{ fontSize: "11px", fontWeight: 700, letterSpacing: "0.1em", textTransform: "uppercase", color: "var(--pp-muted)" }}>
                  Langkah pengerjaan
                </span>
                <div style={{ flex: 1, height: "1px", backgroundColor: "var(--pp-line)" }} />
              </div>
              <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
                {guruSteps.map(({ step, icon, label, desc, done, locked, path, ci }) => (
                  <button
                    key={label}
                    onClick={() => goTo(path, locked, label === "Soal")}
                    disabled={locked}
                    className="rounded-[18px] p-5 text-left"
                    style={{
                      backgroundColor: locked ? "var(--pp-bg)" : done ? "#DAF5E7" : ci.bg,
                      border: "1.5px solid var(--pp-ink)",
                      boxShadow: locked ? "none" : "4px 4px 0 0 var(--pp-ink)",
                      opacity: locked ? 0.45 : 1,
                      cursor: locked ? "not-allowed" : "pointer",
                      fontFamily: "inherit",
                      transition: "transform 0.1s, box-shadow 0.1s",
                    }}
                    onMouseEnter={e => { if (!locked) { e.currentTarget.style.transform = "translate(-1px,-1px)"; e.currentTarget.style.boxShadow = "5px 5px 0 0 var(--pp-ink)" }}}
                    onMouseLeave={e => { e.currentTarget.style.transform = ""; e.currentTarget.style.boxShadow = locked ? "none" : "4px 4px 0 0 var(--pp-ink)" }}
                  >
                    <div className="flex items-center justify-between mb-4">
                      <div style={{
                        width: "38px", height: "38px", borderRadius: "12px",
                        backgroundColor: locked ? "var(--pp-muted)" : done ? "#9DE3C4" : ci.iconBg,
                        color: locked ? "white" : done ? "#0E4A2F" : ci.iconColor,
                        display: "grid", placeItems: "center",
                      }}>
                        {done ? <Check className="w-5 h-5" /> : locked ? <Lock className="w-5 h-5" /> : icon}
                      </div>
                      <span className="font-bold text-xs px-2 py-0.5 rounded-full"
                            style={{ backgroundColor: "var(--pp-bg)", color: "var(--pp-muted)", border: "1px solid var(--pp-line)" }}>
                        {step}
                      </span>
                    </div>
                    <div className="font-semibold text-sm mb-0.5" style={{ color: "var(--pp-ink)" }}>{label}</div>
                    <div className="text-xs leading-snug" style={{ color: "var(--pp-ink-2)" }}>{desc}</div>
                    {done && (
                      <div className="mt-3 flex items-center gap-1 text-xs font-semibold" style={{ color: "#0E4A2F" }}>
                        <Check className="w-3 h-3" /> Selesai
                      </div>
                    )}
                  </button>
                ))}
              </div>
            </div>

            {/* Tips */}
            {!hasMatrix && (
              <div className="flex items-start gap-3 px-4 py-3 rounded-[14px]"
                   style={{ backgroundColor: "#FFF5C6", border: "1.5px solid var(--pp-lemon)" }}>
                <Lightbulb className="w-4 h-4 mt-0.5 shrink-0" style={{ color: "#C99A14" }} />
                <p className="text-sm" style={{ color: "#5A4500" }}>
                  Isi matrix terlebih dahulu untuk dapat input soal. Namun Anda bisa upload dokumen sekarang.
                </p>
              </div>
            )}

            {/* ── Stat cards ── */}
            <div>
              <div className="mb-4 flex items-center gap-2">
                <span style={{ fontSize: "11px", fontWeight: 700, letterSpacing: "0.1em", textTransform: "uppercase", color: "var(--pp-muted)" }}>
                  Statistik soal saya
                </span>
                <div style={{ flex: 1, height: "1px", backgroundColor: "var(--pp-line)" }} />
              </div>
              <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
                {statCards.map(({ label, value, icon, vi }) => (
                  <div key={label} className="relative overflow-hidden rounded-[22px] shadow-hard-md p-5"
                       style={{ backgroundColor: vi.bg, border: "1.5px solid var(--pp-ink)", minHeight: "130px" }}>
                    <div style={{
                      position: "absolute", right: "-16px", top: "-16px",
                      width: "70px", height: "70px", borderRadius: "50%",
                      backgroundColor: vi.blob, opacity: 0.5,
                    }} />
                    <div style={{
                      width: "34px", height: "34px", borderRadius: "10px",
                      backgroundColor: vi.iconBg, color: vi.iconColor,
                      display: "grid", placeItems: "center",
                      marginBottom: "16px", position: "relative",
                    }}>
                      {icon}
                    </div>
                    <div className="font-display font-semibold relative"
                         style={{ fontSize: "36px", lineHeight: 1, letterSpacing: "-0.03em", color: "var(--pp-ink)" }}>
                      {value}
                    </div>
                    <div className="font-medium mt-1 relative text-xs" style={{ color: "var(--pp-ink-2)" }}>
                      {label}
                    </div>
                  </div>
                ))}
              </div>
            </div>

            {/* ── Progress bank soal ── */}
            {targetBank > 0 && (
              <div className="rounded-[18px] shadow-hard-md p-5"
                   style={{ backgroundColor: "var(--pp-card)", border: "1.5px solid var(--pp-ink)" }}>
                <div className="flex justify-between items-center mb-3">
                  <span className="font-semibold text-sm" style={{ color: "var(--pp-ink)" }}>Progress Bank Soal</span>
                  <span className="font-bold text-sm" style={{ color: "var(--pp-ink-2)", fontVariantNumeric: "tabular-nums" }}>
                    {guruSoalStats.total} / {targetBank}
                  </span>
                </div>
                <div style={{ height: "10px", borderRadius: "999px", backgroundColor: "#F4ECDF", border: "1.5px solid var(--pp-ink)", overflow: "hidden" }}>
                  <div style={{ height: "100%", width: `${progPct}%`, background: progGradient, transition: "width 0.4s ease" }} />
                </div>
                <p className="text-xs mt-2" style={{ color: "var(--pp-ink-2)", fontVariantNumeric: "tabular-nums" }}>
                  {guruSoalStats.total >= targetBank
                    ? "Target bank soal tercapai"
                    : `${targetBank - guruSoalStats.total} soal lagi untuk memenuhi target (${progPct}%)`}
                </p>
              </div>
            )}

            {/* ── Progress vs Patokan ── */}
            {Object.keys(patokan).length > 0 && (
              <div>
                <div className="mb-4 flex items-center gap-2">
                  <span style={{ fontSize: "11px", fontWeight: 700, letterSpacing: "0.1em", textTransform: "uppercase", color: "var(--pp-muted)" }}>
                    Progress vs Patokan
                  </span>
                  <div style={{ flex: 1, height: "1px", backgroundColor: "var(--pp-line)" }} />
                </div>
                <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                  {TIPE_OPTIONS.map((tipe, ti) => {
                    const tipeColor = GURU_STEP_COLORS[ti]
                    return (
                      <div key={tipe} className="rounded-[18px] shadow-hard-md overflow-hidden"
                           style={{ border: "1.5px solid var(--pp-ink)" }}>
                        {/* tipe header */}
                        <div className="px-4 py-3 flex items-center gap-2"
                             style={{ backgroundColor: tipeColor.bg, borderBottom: "1.5px solid var(--pp-ink)" }}>
                          <div style={{
                            width: "8px", height: "8px", borderRadius: "2px",
                            backgroundColor: tipeColor.iconBg, border: "1px solid var(--pp-ink)",
                          }} />
                          <span className="font-semibold text-sm capitalize" style={{ color: "var(--pp-ink)" }}>{tipe}</span>
                        </div>

                        {/* header row */}
                        <div className="grid grid-cols-3 px-4 py-2"
                             style={{ backgroundColor: "#FFF4E5", borderBottom: "1px solid var(--pp-line)" }}>
                          <span style={{ fontSize: "10px", fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.08em", color: "var(--pp-muted)" }}>Tingkat</span>
                          <span className="text-center" style={{ fontSize: "10px", fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.08em", color: "var(--pp-muted)" }}>Keluar</span>
                          <span className="text-center" style={{ fontSize: "10px", fontWeight: 700, textTransform: "uppercase", letterSpacing: "0.08em", color: "var(--pp-muted)" }}>Bank</span>
                        </div>

                        <div style={{ backgroundColor: "var(--pp-card)" }}>
                          {KESULITAN_OPTIONS.map((kesulitan, ki) => {
                            const dibuat       = soalCounts[`${tipe}_${kesulitan}`] || 0
                            const tgtKeluar    = patokan[`${tipe}_${kesulitan}_keluar`] || 0
                            const tgtBank      = patokan[`${tipe}_${kesulitan}_bank`]   || 0
                            const okKeluar     = tgtKeluar > 0 && dibuat >= tgtKeluar
                            const okBank       = tgtBank   > 0 && dibuat >= tgtBank

                            const cellStyle = (ok: boolean, target: number): React.CSSProperties => ({
                              fontSize: "12px", fontWeight: 600, fontVariantNumeric: "tabular-nums",
                              padding: "2px 8px", borderRadius: "6px", textAlign: "center",
                              backgroundColor: target === 0 ? "transparent"
                                : ok ? "#DAF5E7" : "#FFD9E6",
                              color: target === 0 ? "var(--pp-muted)"
                                : ok ? "#0E4A2F" : "#6B0E33",
                            })

                            return (
                              <div key={kesulitan} className="grid grid-cols-3 items-center px-4 py-2.5"
                                   style={{ borderBottom: ki < 2 ? "1px solid var(--pp-line)" : "none" }}>
                                <span className="text-xs capitalize" style={{ color: "var(--pp-ink-2)" }}>{kesulitan}</span>
                                <div className="flex justify-center">
                                  <span style={cellStyle(okKeluar, tgtKeluar)}>
                                    {tgtKeluar > 0 && (okKeluar
                                      ? <Check className="w-3 h-3 inline mr-0.5" />
                                      : <X className="w-3 h-3 inline mr-0.5" />
                                    )}
                                    {dibuat}/{tgtKeluar}
                                  </span>
                                </div>
                                <div className="flex justify-center">
                                  <span style={cellStyle(okBank, tgtBank)}>
                                    {tgtBank > 0 && (okBank
                                      ? <Check className="w-3 h-3 inline mr-0.5" />
                                      : <X className="w-3 h-3 inline mr-0.5" />
                                    )}
                                    {dibuat}/{tgtBank}
                                  </span>
                                </div>
                              </div>
                            )
                          })}
                        </div>
                      </div>
                    )
                  })}
                </div>
              </div>
            )}
          </>
        )}
      </main>

      <footer className="text-center py-6" style={{ fontSize: "12px", color: "var(--pp-muted)" }}>
        © 2026 <strong style={{ color: "var(--pp-ink-2)" }}>PSAT SMP Al Abidin</strong>
      </footer>
    </div>
  )
}
