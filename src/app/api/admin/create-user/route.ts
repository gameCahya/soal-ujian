import { NextResponse } from "next/server"

/**
 * Sejak identitas PSAT disatukan dengan identitas LMS (migrasi
 * 20260821_psat_identitas_bersama.sql), psat.profiles adalah view di atas
 * public.profiles — akun tidak lagi dibuat di sini.
 *
 * Alurnya sekarang: admin membuat guru di LMS, lalu menyalakan
 * "Soal PSAT → Tulis" pada baris guru tersebut di Kelola Guru.
 */
export async function POST() {
  return NextResponse.json(
    { error: "Akun guru dibuat di LMS, bukan di sini. Buat gurunya di LMS lalu nyalakan akses Soal PSAT." },
    { status: 410 },
  )
}
