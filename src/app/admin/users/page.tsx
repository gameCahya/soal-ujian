"use client"

import { useEffect, useState } from "react"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabase"
import Toast from "@/components/Toast"
import { UserPlus, X, Eye, EyeOff, Trash2, Pencil, Users, ArrowLeft } from "lucide-react"
import ThemeToggle from "@/components/ThemeToggle"

const ROLE_OPTIONS = ["guru", "validator", "admin", "admin_keuangan"]

const ROLE_COLORS: Record<string, { bg: string; color: string }> = {
  admin:           { bg: "#ECE4FF", color: "#6d28d9" },
  validator:       { bg: "#DAF5E7", color: "#15803d" },
  guru:            { bg: "#FFF5C6", color: "#92400e" },
  admin_keuangan:  { bg: "#FFE3D0", color: "#c2410c" },
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

interface UserRow {
  id: string
  email: string
  nama: string | null
  role: string
  created_at: string
}

interface EditForm {
  userId: string
  email: string
  role: string
  nama: string
  noHp: string
  unitSekolah: string
  kelas: string
  mapelId: string
  bank: string
  noRekening: string
}

const inputStyle: React.CSSProperties = {
  width: "100%",
  padding: "8px 12px",
  borderRadius: 10,
  border: "1.5px solid var(--pp-ink)",
  backgroundColor: "var(--pp-bg)",
  color: "var(--pp-ink)",
  fontSize: 14,
  outline: "none",
}

export default function UsersAdminPage() {
  const router = useRouter()
  const [user, setUser] = useState<any>(null)
  const [userList, setUserList] = useState<UserRow[]>([])
  const [mataPelajaran, setMataPelajaran] = useState<{ id: string; nama: string }[]>([])
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState("")
  const [toast, setToast] = useState<{ message: string; type: "success" | "error" | "info" } | null>(null)

  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [deleting, setDeleting] = useState(false)

  const [showAddModal, setShowAddModal] = useState(false)
  const [formEmail, setFormEmail] = useState("")
  const [formPassword, setFormPassword] = useState("")
  const [showPassword, setShowPassword] = useState(false)
  const [formError, setFormError] = useState("")
  const [formLoading, setFormLoading] = useState(false)

  const [showEditModal, setShowEditModal] = useState(false)
  const [editForm, setEditForm] = useState<EditForm | null>(null)
  const [editLoading, setEditLoading] = useState(false)
  const [editSaving, setEditSaving] = useState(false)
  const [editValidatorMapels, setEditValidatorMapels] = useState<string[]>([])

  useEffect(() => {
    async function load() {
      const { data: { user: u } } = await supabase.auth.getUser()
      if (!u) { router.push("/login"); return }

      const { data: profile } = await supabase
        .from("profiles").select("role").eq("id", u.id).single()

      if (!profile || profile.role !== "admin") {
        setToast({ message: "Akses ditolak", type: "error" })
        setTimeout(() => router.push("/dashboard"), 1500)
        return
      }

      setUser(u)

      const { data: mapelData } = await supabase
        .from("mata_pelajaran").select("id, nama").order("nama")
      if (mapelData) setMataPelajaran(mapelData)

      loadUsers()
    }
    load()
  }, [router])

  const loadUsers = async () => {
    setLoading(true)
    setLoadError("")
    const { data: users, error } = await supabase
      .from("profiles")
      .select("id,email,nama,role,created_at")
      .order("created_at", { ascending: false })

    if (error) setLoadError(error.message)
    else setUserList(users ?? [])
    setLoading(false)
  }

  // Peran diturunkan dari LMS sejak identitas disatukan: psat.profiles adalah
  // view, dan trigger INSTEAD OF-nya tidak menyalurkan kolom role ke mana pun.
  // Menulisnya di sini akan "berhasil" tanpa mengubah apa pun, jadi jalurnya
  // ditutup dan diganti keterangan.
  const handleRoleChange = async () => {
    setToast({
      message: "Peran diatur dari LMS: Kelola Guru -> Soal PSAT (Tulis / Validasi).",
      type: "error",
    })
  }

  const openEditModal = async (u: UserRow) => {
    setShowEditModal(true)
    setEditLoading(true)
    setEditForm({ userId: u.id, email: u.email, role: u.role, nama: u.nama || "", noHp: "", unitSekolah: "", kelas: "", mapelId: "", bank: "", noRekening: "" })

    const { data: profileData } = await supabase
      .from("profiles").select("nama, no_hp, kelas, role").eq("id", u.id).maybeSingle()
    const { data: guruData } = await supabase
      .from("psat_guru_data").select("whatsapp, unit_sekolah, mapel_id, bank, no_rekening").eq("profile_id", u.id).maybeSingle()

    const resolvedRole = profileData?.role || u.role
    setEditForm({
      userId: u.id, email: u.email, role: resolvedRole,
      nama: profileData?.nama || u.nama || "",
      noHp: guruData?.whatsapp || profileData?.no_hp || "",
      unitSekolah: guruData?.unit_sekolah || "",
      kelas: profileData?.kelas || "",
      mapelId: guruData?.mapel_id || "",
      bank: guruData?.bank || "",
      noRekening: guruData?.no_rekening || "",
    })

    if (resolvedRole === "validator") {
      const { data: vmRows } = await supabase
        .from("psat_validator_mapel").select("mapel_id").eq("validator_id", u.id)
      setEditValidatorMapels(vmRows?.map((r: any) => r.mapel_id) ?? [])
    } else {
      setEditValidatorMapels([])
    }
    setEditLoading(false)
  }

  const handleEditSave = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!editForm) return
    setEditSaving(true)

    const { data: { session } } = await supabase.auth.getSession()
    if (!session) {
      setToast({ message: "Sesi tidak valid, silakan login ulang.", type: "error" })
      setEditSaving(false)
      return
    }

    const isGuru = editForm.role === "guru"
    const res = await fetch("/api/admin/update-profile", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${session.access_token}` },
      body: JSON.stringify({
        userId: editForm.userId,
        profileData: { nama: editForm.nama, no_hp: editForm.noHp, role: editForm.role, kelas: isGuru ? editForm.kelas : null },
        guruData: { no_hp: editForm.noHp, unit_sekolah: editForm.unitSekolah, bank: editForm.bank, no_rekening: editForm.noRekening, mapel_id: isGuru ? (editForm.mapelId || null) : null },
      }),
    })

    const result = await res.json()
    setEditSaving(false)

    if (!res.ok) { setToast({ message: result.error || "Gagal menyimpan profil.", type: "error" }); return }

    if (editForm.role === "validator") {
      await supabase.from("psat_validator_mapel").delete().eq("validator_id", editForm.userId)
      if (editValidatorMapels.length > 0) {
        await supabase.from("psat_validator_mapel").insert(editValidatorMapels.map(mapelId => ({ validator_id: editForm.userId, mapel_id: mapelId })))
      }
    }

    setToast({ message: "Profil berhasil diperbarui!", type: "success" })
    setShowEditModal(false)
    setUserList(prev => prev.map(u => u.id === editForm.userId ? { ...u, nama: editForm.nama, role: editForm.role } : u))
  }

  const toggleSelect = (id: string) => {
    setSelectedIds(prev => { const next = new Set(prev); next.has(id) ? next.delete(id) : next.add(id); return next })
  }

  const toggleSelectAll = () => {
    const selectable = userList.filter(u => u.id !== user?.id).map(u => u.id)
    if (selectable.every(id => selectedIds.has(id))) setSelectedIds(new Set())
    else setSelectedIds(new Set(selectable))
  }

  const handleDelete = async (ids: string[]) => {
    if (!confirm(`Hapus ${ids.length} user? Tindakan ini tidak bisa dibatalkan.`)) return
    setDeleting(true)

    const { data: { session } } = await supabase.auth.getSession()
    if (!session) { setToast({ message: "Sesi tidak valid, silakan login ulang.", type: "error" }); setDeleting(false); return }

    const res = await fetch("/api/admin/delete-user", {
      method: "DELETE",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${session.access_token}` },
      body: JSON.stringify({ userIds: ids }),
    })

    const result = await res.json()
    setDeleting(false)

    if (!res.ok) { setToast({ message: result.error || "Gagal menghapus user.", type: "error" }); return }

    setToast({ message: `${result.deleted} user berhasil dihapus.`, type: "success" })
    setSelectedIds(new Set())
    loadUsers()
  }

  const handleCreateUser = async (e: React.FormEvent) => {
    e.preventDefault()
    setFormLoading(true)
    setFormError("")

    const { data: { session } } = await supabase.auth.getSession()
    if (!session) { setFormError("Sesi tidak valid."); setFormLoading(false); return }

    const res = await fetch("/api/admin/create-user", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${session.access_token}` },
      body: JSON.stringify({ email: formEmail, password: formPassword }),
    })

    const result = await res.json()
    setFormLoading(false)

    if (!res.ok) { setFormError(result.error || "Gagal membuat user."); return }

    setToast({ message: "User berhasil ditambahkan!", type: "success" })
    setShowAddModal(false)
    setFormEmail(""); setFormPassword(""); setShowPassword(false); setFormError("")
    loadUsers()
  }

  if (loading) {
    return (
      <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh" }} className="flex items-center justify-center">
        <div className="font-display text-xl" style={{ color: "var(--pp-ink-2)" }}>Memuat...</div>
      </div>
    )
  }

  const editIsGuru = editForm?.role === "guru"
  const editIsValidator = editForm?.role === "validator"
  const allSelectable = userList.filter(u => u.id !== user?.id)
  const allSelected = allSelectable.length > 0 && allSelectable.every(u => selectedIds.has(u.id))

  return (
    <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh" }}>
      {/* Header */}
      <header
        className="sticky top-0 z-10"
        style={{ backgroundColor: "var(--pp-card)", borderBottom: "1.5px solid var(--pp-ink)" }}
      >
        <div className="max-w-5xl mx-auto px-4 py-3 flex items-center justify-between gap-3">
          <div className="flex items-center gap-3 min-w-0">
            <div style={{
              width: 40, height: 40, flexShrink: 0,
              backgroundColor: "var(--pp-primary)",
              border: "1.5px dashed rgba(255,255,255,0.45)",
              borderRadius: 12,
              boxShadow: "2px 2px 0 0 var(--pp-ink)",
              display: "flex", alignItems: "center", justifyContent: "center",
            }}>
              <Users className="w-4 h-4 text-white" />
            </div>
            <div className="font-display font-semibold text-base" style={{ color: "var(--pp-ink)" }}>
              Kelola Users
            </div>
          </div>
          <div className="flex items-center gap-2 shrink-0">
            <ThemeToggle />
            {selectedIds.size > 0 && (
              <button
                onClick={() => handleDelete([...selectedIds])}
                disabled={deleting}
                className="flex items-center gap-1.5 text-sm font-semibold px-3 py-2 rounded-[10px] disabled:opacity-50"
                style={{
                  backgroundColor: "var(--pp-pink)",
                  color: "#be123c",
                  border: "1.5px solid var(--pp-ink)",
                  boxShadow: "3px 3px 0 0 var(--pp-ink)",
                }}
              >
                <Trash2 className="w-3.5 h-3.5" />
                Hapus ({selectedIds.size})
              </button>
            )}
            <button
              onClick={() => setShowAddModal(true)}
              className="flex items-center gap-1.5 text-sm font-semibold px-4 py-2 rounded-[10px]"
              style={{
                backgroundColor: "var(--pp-mint)",
                color: "#15803d",
                border: "1.5px solid var(--pp-ink)",
                boxShadow: "3px 3px 0 0 var(--pp-ink)",
              }}
            >
              <UserPlus className="w-4 h-4" />
              Tambah User
            </button>
          </div>
        </div>
      </header>

      {/* Keanggotaan PSAT sekarang datang dari LMS — tanpa keterangan ini,
          tombol Tambah/Hapus di atas cuma akan memunculkan error tanpa sebab. */}
      <div className="max-w-5xl mx-auto px-4 pt-4">
        <div
          className="text-sm"
          style={{
            padding: "12px 14px",
            borderRadius: "12px",
            border: "1.5px solid var(--pp-ink)",
            backgroundColor: "var(--pp-lemon)",
            color: "var(--pp-ink)",
            lineHeight: 1.5,
          }}
        >
          <strong>Akun dan peran dikelola di LMS.</strong> Buat atau nonaktifkan guru di LMS,
          lalu nyalakan <em>Kelola Guru &rarr; Soal PSAT</em> — <em>Tulis</em> untuk penulis soal,
          <em> Validasi</em> untuk validator. Halaman ini tinggal untuk melihat daftar dan
          mengisi data per siklus (mapel, kelas, unit, rekening).
        </div>
      </div>

      {/* Back link */}
      <div className="max-w-5xl mx-auto px-4 pt-4 pb-1">
        <button
          onClick={() => router.push("/dashboard")}
          className="flex items-center gap-1.5 text-sm hover:opacity-70 transition-opacity"
          style={{ color: "var(--pp-muted)" }}
        >
          <ArrowLeft className="w-4 h-4" />
          Kembali ke Dashboard
        </button>
      </div>

      <main className="max-w-5xl mx-auto px-4 py-4 pb-12">
        {loadError ? (
          <div
            style={{
              backgroundColor: "var(--pp-pink)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 16,
              padding: "12px 18px",
              boxShadow: "3px 3px 0 0 var(--pp-ink)",
              color: "#be123c",
              fontSize: 14,
            }}
          >
            Error: {loadError}
          </div>
        ) : userList.length === 0 ? (
          <div
            style={{
              backgroundColor: "var(--pp-card)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 22,
              boxShadow: "4px 4px 0 0 var(--pp-ink)",
              padding: "48px 24px",
              textAlign: "center",
            }}
          >
            <p className="font-display font-semibold" style={{ color: "var(--pp-ink)" }}>Belum ada user</p>
            <p className="text-sm mt-1" style={{ color: "var(--pp-muted)" }}>Klik "Tambah User" untuk membuat akun baru.</p>
          </div>
        ) : (
          <div
            style={{
              backgroundColor: "var(--pp-card)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 22,
              boxShadow: "6px 6px 0 0 var(--pp-ink)",
              overflow: "hidden",
            }}
          >
            <table className="w-full text-sm border-collapse">
              <thead>
                <tr style={{ backgroundColor: "var(--pp-lemon)", borderBottom: "1.5px solid var(--pp-ink)" }}>
                  <th className="px-4 py-3 w-10">
                    <input
                      type="checkbox"
                      onChange={toggleSelectAll}
                      checked={allSelected}
                      className="w-3.5 h-3.5"
                      style={{ accentColor: "var(--pp-primary)" }}
                    />
                  </th>
                  <th className="px-4 py-3 text-left font-display font-semibold" style={{ color: "var(--pp-ink)" }}>Nama / Email</th>
                  <th className="px-4 py-3 text-left font-display font-semibold" style={{ color: "var(--pp-ink)" }}>Role</th>
                  <th className="px-4 py-3 text-left font-display font-semibold" style={{ color: "var(--pp-ink)" }}>Bergabung</th>
                  <th className="px-4 py-3 text-center font-display font-semibold" style={{ color: "var(--pp-ink)" }}>Aksi</th>
                </tr>
              </thead>
              <tbody>
                {userList.map((u, idx) => {
                  const isSelf = u.id === user?.id
                  const roleColor = ROLE_COLORS[u.role] || { bg: "var(--pp-bg)", color: "var(--pp-muted)" }
                  return (
                    <tr
                      key={u.id}
                      style={{
                        backgroundColor: idx % 2 === 0 ? "var(--pp-card)" : "var(--pp-bg)",
                        borderBottom: "1px solid var(--pp-line)",
                      }}
                    >
                      <td className="px-4 py-3 text-center">
                        <input
                          type="checkbox"
                          checked={selectedIds.has(u.id)}
                          onChange={() => toggleSelect(u.id)}
                          disabled={isSelf}
                          className="w-3.5 h-3.5"
                          style={{ accentColor: "var(--pp-primary)" }}
                        />
                      </td>
                      <td className="px-4 py-3">
                        <div className="flex items-center gap-2.5">
                          <div
                            className="w-8 h-8 rounded-full flex items-center justify-center font-display font-bold text-xs shrink-0"
                            style={{ backgroundColor: roleColor.bg, color: roleColor.color, border: "1.5px solid var(--pp-ink)" }}
                          >
                            {(u.nama || u.email).charAt(0).toUpperCase()}
                          </div>
                          <div>
                            <div className="font-semibold text-sm" style={{ color: "var(--pp-ink)" }}>
                              {u.nama || <span style={{ color: "var(--pp-muted)", fontStyle: "italic" }}>Belum diisi</span>}
                              {isSelf && (
                                <span
                                  className="ml-1.5 text-xs px-1.5 py-0.5 rounded-full font-medium"
                                  style={{ backgroundColor: "var(--pp-lemon)", color: "#92400e", border: "1px solid var(--pp-ink)" }}
                                >
                                  Anda
                                </span>
                              )}
                            </div>
                            <div className="text-xs mt-0.5" style={{ color: "var(--pp-muted)" }}>{u.email}</div>
                          </div>
                        </div>
                      </td>
                      <td className="px-4 py-3">
                        <span
                          className="text-xs font-semibold px-2 py-0.5 rounded-full"
                          style={{ backgroundColor: roleColor.bg, color: roleColor.color, border: "1px solid var(--pp-ink)" }}
                        >
                          {u.role}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-xs" style={{ color: "var(--pp-muted)" }}>
                        {new Date(u.created_at).toLocaleDateString("id-ID")}
                      </td>
                      <td className="px-4 py-3">
                        <div className="flex items-center justify-center gap-2">
                          <button
                            type="button"
                            onClick={handleRoleChange}
                            title="Peran diatur dari LMS"
                            className="px-2 py-1 rounded-[8px] text-xs font-medium"
                            style={{
                              backgroundColor: "var(--pp-bg)",
                              border: "1.5px dashed var(--pp-muted)",
                              color: "var(--pp-muted)",
                              cursor: "help",
                            }}
                          >
                            dari LMS
                          </button>
                          <button
                            onClick={() => openEditModal(u)}
                            className="flex items-center gap-1 px-2.5 py-1.5 rounded-[8px]"
                            style={{
                              backgroundColor: "var(--pp-lemon)",
                              color: "#92400e",
                              border: "1.5px solid var(--pp-ink)",
                              boxShadow: "2px 2px 0 0 var(--pp-ink)",
                            }}
                            title="Edit profil"
                          >
                            <Pencil className="w-3 h-3" />
                          </button>
                          {!isSelf && (
                            <button
                              onClick={() => handleDelete([u.id])}
                              disabled={deleting}
                              className="flex items-center gap-1 px-2.5 py-1.5 rounded-[8px] disabled:opacity-50"
                              style={{
                                backgroundColor: "var(--pp-pink)",
                                color: "#be123c",
                                border: "1.5px solid var(--pp-ink)",
                                boxShadow: "2px 2px 0 0 var(--pp-ink)",
                              }}
                              title="Hapus user"
                            >
                              <Trash2 className="w-3 h-3" />
                            </button>
                          )}
                        </div>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </main>

      {/* Modal Edit Profil */}
      {showEditModal && editForm && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center p-4"
          style={{ backgroundColor: "rgba(0,0,0,0.55)" }}
          onClick={() => setShowEditModal(false)}
        >
          <div
            className="w-full max-w-lg"
            style={{
              backgroundColor: "var(--pp-card)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: 22,
              boxShadow: "6px 6px 0 0 var(--pp-ink)",
              overflow: "hidden",
            }}
            onClick={e => e.stopPropagation()}
          >
            {/* Header band */}
            <div style={{
              backgroundColor: "var(--pp-lemon)",
              borderBottom: "1.5px solid var(--pp-ink)",
              padding: "16px 20px",
              display: "flex", alignItems: "center", justifyContent: "space-between",
            }}>
              <div>
                <div className="font-display font-semibold text-base" style={{ color: "var(--pp-ink)" }}>Edit Profil</div>
                <div className="text-xs mt-0.5" style={{ color: "var(--pp-muted)" }}>{editForm.email}</div>
              </div>
              <button onClick={() => setShowEditModal(false)} style={{ color: "var(--pp-ink-2)" }}>
                <X className="w-4 h-4" />
              </button>
            </div>

            {editLoading ? (
              <div className="p-8 text-center text-sm" style={{ color: "var(--pp-muted)" }}>Memuat data...</div>
            ) : (
              <div className="max-h-[70vh] overflow-y-auto">
                <form onSubmit={handleEditSave} className="p-5 space-y-4">

                  {/* Role */}
                  <div>
                    <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Role</label>
                    <select
                      value={editForm.role}
                      disabled
                      style={{ ...inputStyle, opacity: 0.6, cursor: "not-allowed" }}
                    >
                      {ROLE_OPTIONS.map(r => <option key={r} value={r}>{r}</option>)}
                    </select>
                    <p className="text-xs mt-1" style={{ color: "var(--pp-muted)" }}>
                      Diatur dari LMS: Kelola Guru &rarr; Soal PSAT.
                    </p>
                  </div>

                  {/* Nama */}
                  <div>
                    <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Nama Lengkap</label>
                    <input
                      type="text"
                      value={editForm.nama}
                      onChange={e => setEditForm(f => f ? { ...f, nama: e.target.value } : f)}
                      style={inputStyle}
                      onFocus={e => { e.currentTarget.style.boxShadow = "2px 2px 0 0 var(--pp-primary)" }}
                      onBlur={e => { e.currentTarget.style.boxShadow = "none" }}
                    />
                  </div>

                  {/* No HP */}
                  <div>
                    <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Nomor HP / WA</label>
                    <input
                      type="tel"
                      value={editForm.noHp}
                      onChange={e => setEditForm(f => f ? { ...f, noHp: e.target.value } : f)}
                      placeholder="08123456789"
                      style={inputStyle}
                      onFocus={e => { e.currentTarget.style.boxShadow = "2px 2px 0 0 var(--pp-primary)" }}
                      onBlur={e => { e.currentTarget.style.boxShadow = "none" }}
                    />
                  </div>

                  {/* Unit Sekolah */}
                  <div>
                    <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Unit Sekolah</label>
                    <select
                      value={editForm.unitSekolah}
                      onChange={e => setEditForm(f => f ? { ...f, unitSekolah: e.target.value } : f)}
                      style={inputStyle}
                    >
                      <option value="">Pilih Unit Sekolah</option>
                      {UNIT_OPTIONS.map(u => <option key={u} value={u}>{u}</option>)}
                    </select>
                  </div>

                  {/* Kelas & Mapel — guru only */}
                  {editIsGuru && (
                    <>
                      <div>
                        <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Kelas</label>
                        <select
                          value={editForm.kelas}
                          onChange={e => setEditForm(f => f ? { ...f, kelas: e.target.value } : f)}
                          style={inputStyle}
                        >
                          <option value="">Pilih Kelas</option>
                          <option value="7">Kelas 7</option>
                          <option value="8">Kelas 8</option>
                          <option value="9">Kelas 9</option>
                        </select>
                      </div>

                      <div>
                        <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Mata Pelajaran</label>
                        <select
                          value={editForm.mapelId}
                          onChange={e => setEditForm(f => f ? { ...f, mapelId: e.target.value } : f)}
                          style={inputStyle}
                        >
                          <option value="">Pilih Mata Pelajaran</option>
                          {mataPelajaran.map(m => <option key={m.id} value={m.id}>{m.nama}</option>)}
                        </select>
                      </div>
                    </>
                  )}

                  {/* Mapel validator */}
                  {editIsValidator && (
                    <div>
                      <label className="block text-xs font-semibold mb-2 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>
                        Mata Pelajaran yang Divalidasi
                        <span
                          className="ml-2 px-1.5 py-0.5 rounded-full font-semibold normal-case"
                          style={{ backgroundColor: "var(--pp-mint)", color: "#15803d", border: "1px solid var(--pp-ink)", fontSize: 10 }}
                        >
                          {editValidatorMapels.length} dipilih
                        </span>
                      </label>
                      <div className="grid grid-cols-2 gap-1.5 max-h-44 overflow-y-auto pr-1">
                        {mataPelajaran.map(mp => {
                          const checked = editValidatorMapels.includes(mp.id)
                          return (
                            <label
                              key={mp.id}
                              className="flex items-center gap-2 px-3 py-2 rounded-[10px] cursor-pointer text-xs font-medium"
                              style={{
                                border: "1.5px solid var(--pp-ink)",
                                backgroundColor: checked ? "var(--pp-mint)" : "var(--pp-bg)",
                                color: "var(--pp-ink)",
                                boxShadow: checked ? "none" : "1px 1px 0 0 var(--pp-ink)",
                                transform: checked ? "translate(1px,1px)" : "none",
                                transition: "all 80ms",
                              }}
                            >
                              <input
                                type="checkbox"
                                checked={checked}
                                onChange={e => {
                                  if (e.target.checked) setEditValidatorMapels(prev => [...prev, mp.id])
                                  else setEditValidatorMapels(prev => prev.filter(id => id !== mp.id))
                                }}
                                className="shrink-0"
                                style={{ accentColor: "var(--pp-primary)" }}
                              />
                              {mp.nama}
                            </label>
                          )
                        })}
                      </div>
                    </div>
                  )}

                  {/* Data rekening */}
                  <div
                    className="pt-4 space-y-3"
                    style={{ borderTop: "1.5px solid var(--pp-line)" }}
                  >
                    <div className="text-xs font-semibold uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Data Rekening</div>
                    <div>
                      <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Bank</label>
                      <select
                        value={editForm.bank}
                        onChange={e => setEditForm(f => f ? { ...f, bank: e.target.value } : f)}
                        style={inputStyle}
                      >
                        <option value="">Pilih Bank</option>
                        {BANK_OPTIONS.map(b => <option key={b} value={b}>{b}</option>)}
                      </select>
                    </div>
                    <div>
                      <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Nomor Rekening</label>
                      <input
                        type="text"
                        value={editForm.noRekening}
                        onChange={e => setEditForm(f => f ? { ...f, noRekening: e.target.value } : f)}
                        style={inputStyle}
                        onFocus={e => { e.currentTarget.style.boxShadow = "2px 2px 0 0 var(--pp-primary)" }}
                        onBlur={e => { e.currentTarget.style.boxShadow = "none" }}
                      />
                    </div>
                  </div>

                  <div className="flex gap-3 pt-2">
                    <button
                      type="button"
                      onClick={() => setShowEditModal(false)}
                      className="flex-1 py-2 px-4 rounded-[10px] text-sm font-semibold"
                      style={{ backgroundColor: "var(--pp-bg)", color: "var(--pp-ink)", border: "1.5px solid var(--pp-ink)" }}
                    >
                      Batal
                    </button>
                    <button
                      type="submit"
                      disabled={editSaving}
                      className="flex-1 py-2 px-4 rounded-[10px] text-sm font-semibold disabled:opacity-50"
                      style={{
                        backgroundColor: "var(--pp-ink)", color: "#fff",
                        border: "1.5px solid var(--pp-ink)",
                        boxShadow: "3px 3px 0 0 rgba(0,0,0,0.35)",
                      }}
                    >
                      {editSaving ? "Menyimpan..." : "Simpan"}
                    </button>
                  </div>
                </form>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Modal Tambah User */}
      {showAddModal && (
        <div
          className="fixed inset-0 z-50 flex items-center justify-center p-4"
          style={{ backgroundColor: "rgba(0,0,0,0.55)" }}
          onClick={() => setShowAddModal(false)}
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
            onClick={e => e.stopPropagation()}
          >
            <div style={{
              backgroundColor: "var(--pp-mint)",
              borderBottom: "1.5px solid var(--pp-ink)",
              padding: "16px 20px",
              display: "flex", alignItems: "center", justifyContent: "space-between",
            }}>
              <div className="font-display font-semibold text-base" style={{ color: "var(--pp-ink)" }}>Tambah User</div>
              <button onClick={() => setShowAddModal(false)} style={{ color: "var(--pp-ink-2)" }}>
                <X className="w-4 h-4" />
              </button>
            </div>

            <form onSubmit={handleCreateUser} className="p-5 space-y-4">
              <div>
                <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Email</label>
                <input
                  type="email"
                  value={formEmail}
                  onChange={e => setFormEmail(e.target.value)}
                  style={inputStyle}
                  onFocus={e => { e.currentTarget.style.boxShadow = "2px 2px 0 0 var(--pp-primary)" }}
                  onBlur={e => { e.currentTarget.style.boxShadow = "none" }}
                  autoComplete="off"
                  required
                />
              </div>

              <div>
                <label className="block text-xs font-semibold mb-1.5 uppercase tracking-wide" style={{ color: "var(--pp-muted)" }}>Password</label>
                <div className="relative">
                  <input
                    type={showPassword ? "text" : "password"}
                    value={formPassword}
                    onChange={e => setFormPassword(e.target.value)}
                    style={{ ...inputStyle, paddingRight: 40 }}
                    onFocus={e => { e.currentTarget.style.boxShadow = "2px 2px 0 0 var(--pp-primary)" }}
                    onBlur={e => { e.currentTarget.style.boxShadow = "none" }}
                    autoComplete="new-password"
                    minLength={6}
                    required
                  />
                  <button
                    type="button"
                    onClick={() => setShowPassword(v => !v)}
                    className="absolute right-3 top-1/2 -translate-y-1/2"
                    style={{ color: "var(--pp-muted)" }}
                  >
                    {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                  </button>
                </div>
                <p className="mt-1 text-xs" style={{ color: "var(--pp-muted)" }}>Minimal 6 karakter.</p>
              </div>

              {formError && (
                <p className="text-sm" style={{ color: "#dc2626" }}>{formError}</p>
              )}

              <div className="flex gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setShowAddModal(false)}
                  className="flex-1 py-2 px-4 rounded-[10px] text-sm font-semibold"
                  style={{ backgroundColor: "var(--pp-bg)", color: "var(--pp-ink)", border: "1.5px solid var(--pp-ink)" }}
                >
                  Batal
                </button>
                <button
                  type="submit"
                  disabled={formLoading}
                  className="flex-1 py-2 px-4 rounded-[10px] text-sm font-semibold disabled:opacity-50"
                  style={{
                    backgroundColor: "var(--pp-ink)", color: "#fff",
                    border: "1.5px solid var(--pp-ink)",
                    boxShadow: "3px 3px 0 0 rgba(0,0,0,0.35)",
                  }}
                >
                  {formLoading ? "Membuat..." : "Tambah User"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {toast && <Toast message={toast.message} type={toast.type} onClose={() => setToast(null)} />}
    </div>
  )
}
