import { supabase } from "@/lib/supabase"

/**
 * Konstanta & helper bersama untuk alur bercakupan ujian.
 *
 * Sebelumnya TIPE_OPTIONS/KESULITAN_OPTIONS disalin ulang di halaman matrix,
 * patokan, dan soal — urutannya sempat berbeda antar berkas padahal patokan
 * lama menyimpan angkanya sebagai CSV posisional. Sekarang satu sumber.
 */

export const TIPE_OPTIONS = ["pilgan", "ceklist", "isian_singkat", "essay", "benar_salah"] as const
export const KESULITAN_OPTIONS = ["mudah", "sedang", "sulit"] as const

export type Tipe = (typeof TIPE_OPTIONS)[number]
export type Kesulitan = (typeof KESULITAN_OPTIONS)[number]

export const TIPE_LABELS: Record<string, string> = {
  pilgan: "Pilgan",
  ceklist: "Ceklist",
  isian_singkat: "Isian Singkat",
  essay: "Essay",
  benar_salah: "Benar/Salah",
}

/**
 * Warna badge per tipe. Sebelumnya disalin di lima halaman, salah satunya
 * (matrix) berupa array POSISIONAL sehingga tipe kelima terbaca undefined.
 */
export const TIPE_COLORS: Record<string, { bg: string; accent: string }> = {
  pilgan:        { bg: "#ECE4FF", accent: "#6d28d9" },
  ceklist:       { bg: "#DAF5E7", accent: "#15803d" },
  isian_singkat: { bg: "#FFF5C6", accent: "#92400e" },
  essay:         { bg: "#FFE3D0", accent: "#c2410c" },
  benar_salah:   { bg: "#D8ECFF", accent: "#1d4ed8" },
}

/** Dipakai saat kode tipe tak dikenal — jangan biarkan `.bg` jatuh ke undefined. */
export const WARNA_TIPE_CADANGAN = { bg: "#EEEEEE", accent: "#444444" }

export function warnaTipe(tipe: string) {
  return TIPE_COLORS[tipe] ?? WARNA_TIPE_CADANGAN
}

/** Bobot skor awal per tipe × kesulitan. Admin bisa menimpanya di halaman Patokan. */
export const BOBOT_DEFAULT: Record<string, Record<string, number>> = {
  pilgan:        { mudah: 1.0, sedang: 1.5, sulit: 2.0 },
  ceklist:       { mudah: 1.5, sedang: 2.0, sulit: 2.5 },
  isian_singkat: { mudah: 1.0, sedang: 1.5, sulit: 2.0 },
  essay:         { mudah: 2.0, sedang: 3.0, sulit: 4.0 },
  benar_salah:   { mudah: 1.0, sedang: 1.0, sulit: 1.5 },
}

export const KESULITAN_LABELS: Record<string, string> = {
  mudah: "Mudah",
  sedang: "Sedang",
  sulit: "Sulit",
}

/** Ujian pada siklus aktif yang soalnya ditentukan super admin. */
export interface UjianAktif {
  ujian_id: string
  ujian_nama: string
  mapel_id: string | null
  psat_mapel_id: string | null
  mapel_nama: string | null
  level: string | null
  kelas_list: string[] | null
  event_nama: string | null
  tahun_ajaran: string | null
  semester: number | null
}

/** Satu tugas menulis milik guru yang sedang login. */
export interface TugasMenulis {
  ujian_id: string
  ujian_nama: string
  mapel_id: string | null
  psat_mapel_id: string | null
  mapel_nama: string | null
  level: string | null
  matrix_submitted: boolean
  total_soal: number
  target_bank: number
}

export interface BabUjian {
  bab_id: string
  nama_bab: string
  urutan: number | null
}

/** Satu sel target: berapa soal keluar di ujian dan berapa disiapkan di bank. */
export interface PatokanUjianRow {
  tipe: string
  tingkat_kesulitan: string
  jumlah_keluar: number
  jumlah_bank: number
}

/** Kunci datar yang dipakai grid matrix: `{tipe}_{kesulitan}_{keluar|bank}`. */
export type GridAngka = Record<string, number>

export function gridKosong(): GridAngka {
  const g: GridAngka = {}
  TIPE_OPTIONS.forEach(t =>
    KESULITAN_OPTIONS.forEach(k => {
      g[`${t}_${k}_keluar`] = 0
      g[`${t}_${k}_bank`] = 0
    }),
  )
  return g
}

/** Baris `psat_patokan_ujian` → grid datar yang dipakai UI. */
export function patokanKeGrid(rows: PatokanUjianRow[] | null | undefined): GridAngka {
  const g = gridKosong()
  rows?.forEach(r => {
    g[`${r.tipe}_${r.tingkat_kesulitan}_keluar`] = r.jumlah_keluar ?? 0
    g[`${r.tipe}_${r.tingkat_kesulitan}_bank`] = r.jumlah_bank ?? 0
  })
  return g
}

/** Label ringkas sebuah ujian, mis. "Mathematics · Kelas 8". */
export function labelUjian(u: { mapel_nama: string | null; level: string | null; ujian_nama?: string }): string {
  const mapel = u.mapel_nama || u.ujian_nama || "Ujian"
  return u.level ? `${mapel} · Kelas ${u.level}` : mapel
}

/** Ujian yang punya data PSAT — dipakai halaman publik & antrean validasi. */
export interface UjianPsat {
  ujian_id: string
  ujian_nama: string
  mapel_id: string | null
  psat_mapel_id: string | null
  mapel_nama: string | null
  level: string | null
  event_id: string | null
  event_nama: string | null
  tahun_ajaran: string | null
  semester: number | null
  event_aktif: boolean
  jumlah_soal: number
}

export async function ambilUjianPsat(): Promise<UjianPsat[]> {
  const { data, error } = await supabase.rpc("get_ujian_psat")
  if (error) throw error
  return (data as UjianPsat[]) ?? []
}

/** Pesan error yang aman ditampilkan, tanpa melebarkan tipe ke `any`. */
export function pesanError(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}

export async function ambilUjianAktif(): Promise<UjianAktif[]> {
  const { data, error } = await supabase.rpc("get_ujian_aktif")
  if (error) throw error
  return (data as UjianAktif[]) ?? []
}

export async function ambilTugasMenulis(): Promise<TugasMenulis[]> {
  const { data, error } = await supabase.rpc("get_tugas_menulis")
  if (error) throw error
  return (data as TugasMenulis[]) ?? []
}

export async function ambilBabUjian(ujianId: string): Promise<BabUjian[]> {
  const { data, error } = await supabase.rpc("get_bab_ujian", { p_ujian_id: ujianId })
  if (error) throw error
  return (data as BabUjian[]) ?? []
}

export async function ambilPatokanUjian(ujianId: string): Promise<GridAngka> {
  const { data, error } = await supabase
    .from("psat_patokan_ujian")
    .select("tipe, tingkat_kesulitan, jumlah_keluar, jumlah_bank")
    .eq("ujian_id", ujianId)
  if (error) throw error
  return patokanKeGrid(data as PatokanUjianRow[])
}

/**
 * Simpan seluruh grid target satu ujian.
 *
 * Ditulis sebagai upsert 12 baris sekaligus (4 tipe × 3 kesulitan) supaya sel
 * yang dikosongkan tetap tercatat 0, bukan menghilang dan diam-diam berarti
 * "tidak ada target".
 */
export async function simpanPatokanUjian(
  ujianId: string,
  grid: GridAngka,
  createdBy: string | null,
): Promise<void> {
  const rows = TIPE_OPTIONS.flatMap(t =>
    KESULITAN_OPTIONS.map(k => ({
      ujian_id: ujianId,
      tipe: t,
      tingkat_kesulitan: k,
      jumlah_keluar: grid[`${t}_${k}_keluar`] || 0,
      jumlah_bank: grid[`${t}_${k}_bank`] || 0,
      created_by: createdBy,
      updated_at: new Date().toISOString(),
    })),
  )
  const { error } = await supabase
    .from("psat_patokan_ujian")
    .upsert(rows, { onConflict: "ujian_id,tipe,tingkat_kesulitan" })
  if (error) throw error
}

/** Sel yang keluar-nya melebihi bank ditolak database; cek dulu di UI. */
export function validasiGridTarget(grid: GridAngka): string[] {
  const errors: string[] = []
  TIPE_OPTIONS.forEach(t =>
    KESULITAN_OPTIONS.forEach(k => {
      const keluar = grid[`${t}_${k}_keluar`] || 0
      const bank = grid[`${t}_${k}_bank`] || 0
      if (keluar > bank) {
        errors.push(`${TIPE_LABELS[t]} ${KESULITAN_LABELS[k]}: soal keluar (${keluar}) melebihi bank (${bank})`)
      }
    }),
  )
  return errors
}

/** Calon penulis satu ujian: guru yang mengampu mapel+tingkat ujian itu. */
export interface CalonPenulis {
  profile_id: string
  nama: string | null
  sudah_isi: boolean
  ditunjuk: boolean
  /** Unit asal — 33 ujian × 7–11 calon dari 10 sekolah, nama saja tidak cukup. */
  sekolah: string | null
  /** Kelas yang diampu untuk mapel+tingkat ujian ini. */
  jml_kelas: number
  /** Izin & status sudah siap, jadi ia bisa langsung bekerja begitu ditunjuk. */
  siap: boolean
}

export async function ambilCalonPenulis(ujianId: string): Promise<CalonPenulis[]> {
  const { data, error } = await supabase.rpc("get_calon_penulis", { p_ujian_id: ujianId })
  if (error) throw error
  return (data as CalonPenulis[]) ?? []
}

/**
 * Tunjuk (atau lepas) penanggung jawab matriks satu ujian.
 *
 * Tanpa penunjukan, get_tugas_menulis menampilkan ujian ke SEMUA guru mapel itu
 * — di produksi 45 dari 46 kombinasi (mapel, tingkat) punya lebih dari satu
 * guru — dan tiap grid divalidasi harus sama dengan pagu, sehingga jumlahnya
 * berlipat sebanyak jumlah guru.
 */
export interface HasilTetapkanPenulis {
  ok: boolean
  nama: string | null
  /** true bila izin menulisnya baru dinyalakan oleh penunjukan ini. */
  izin_baru_dinyalakan: boolean
}

export async function tetapkanPenulis(
  ujianId: string,
  profileId: string | null,
): Promise<HasilTetapkanPenulis | null> {
  if (!profileId) {
    const { error } = await supabase.rpc("hapus_penulis", { p_ujian_id: ujianId })
    if (error) throw error
    return null
  }

  // Lewat RPC, bukan upsert langsung. Menulis baris psat_ujian_penulis saja
  // menghasilkan penulis yang masuk ke aplikasi setengah lumpuh: tanpa
  // is_penulis_soal, view psat.profiles tidak mengembalikan barisnya sendiri
  // (0 baris — diukur di produksi), jadi dashboard PSAT tidak bisa memuat
  // profilnya. RPC menyalakan izin itu dalam transaksi yang sama, dan menolak
  // calon yang tidak mengampu atau akunnya tidak aktif — dua keadaan yang dulu
  // diterima diam-diam.
  const { data, error } = await supabase.rpc("tetapkan_penulis", {
    p_ujian_id: ujianId,
    p_profile_id: profileId,
  })
  if (error) throw error
  return data as HasilTetapkanPenulis
}

/** Hasil pembuatan bab dari halaman Matrix. */
export interface BabDibuat {
  bab_id: string
  nama_bab: string
  urutan: number | null
  /** true bila nama itu sudah ada — dikembalikan apa adanya, tidak digandakan. */
  sudah_ada: boolean
}

/**
 * Buat bab tingkat mapel dari PSAT.
 *
 * Perlu RPC karena klien PSAT terikat schema `psat` dan tidak bisa menulis
 * public.bab_pelajaran langsung. Bab sengaja tingkat mapel (ujian_id NULL)
 * supaya bisa dipakai ulang ujian lain pada mapel yang sama — sama seperti
 * yang sudah dilakukan public.impor_soal_psat.
 */
export async function buatBabUjian(ujianId: string, namaBab: string): Promise<BabDibuat> {
  const { data, error } = await supabase.rpc("buat_bab_ujian", {
    p_ujian_id: ujianId,
    p_nama_bab: namaBab,
  })
  if (error) throw error
  const baris = (data as BabDibuat[] | null)?.[0]
  if (!baris) throw new Error("Bab tidak terbuat")
  return baris
}
