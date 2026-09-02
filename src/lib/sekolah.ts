import { supabase } from "@/lib/supabase"

/**
 * Daftar unit sekolah — dibaca dari LMS, bukan ditulis tangan.
 *
 * Sebelumnya `UNIT_OPTIONS` adalah larik 8 nama yang DISALIN di dua berkas
 * (dashboard/profile dan admin/users). LMS punya 11 sekolah, dan tiga tidak
 * pernah ikut tersalin — Magelang, Sragen, dan Learning Center — sehingga 14
 * guru tidak bisa memilih unitnya sendiri di kolom yang wajib diisi.
 *
 * Menambal nama yang hilang cuma menunda masalahnya; sekolah berikutnya yang
 * dibuat di LMS akan hilang lagi dengan cara yang sama. Jadi salinannya
 * dihapus, bukan diperbaiki.
 */
export async function ambilUnitSekolah(): Promise<string[]> {
  const { data, error } = await supabase.rpc("get_unit_sekolah")
  if (error) throw error
  return ((data as { nama: string }[]) ?? []).map(r => r.nama)
}

/**
 * Gabungkan nilai yang SUDAH tersimpan ke dalam daftar pilihan.
 *
 * Kalau nilai lama tidak ada di daftar (unit dinonaktifkan di LMS, atau ejaannya
 * berbeda), `<select>` akan menampilkannya sebagai kosong dan guru mengira
 * profilnya belum diisi — lalu tersimpan berubah tanpa ia bermaksud mengubah.
 * Menyertakannya membuat keadaan apa adanya tetap terlihat.
 */
export function daftarDenganNilaiTersimpan(daftar: string[], tersimpan: string): string[] {
  if (!tersimpan || daftar.includes(tersimpan)) return daftar
  return [...daftar, tersimpan]
}
