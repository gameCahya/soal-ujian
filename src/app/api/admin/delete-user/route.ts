import { NextResponse } from "next/server"

/**
 * Lihat catatan di create-user: penghapusan akun juga milik LMS. Untuk
 * mencabut akses PSAT saja, cukup matikan flag "Soal PSAT → Tulis" di LMS —
 * soal yang sudah ditulis tetap utuh.
 */
export async function POST() {
  return NextResponse.json(
    { error: "Hapus akun dilakukan di LMS. Untuk mencabut akses PSAT saja, matikan flag Soal PSAT di LMS." },
    { status: 410 },
  )
}
