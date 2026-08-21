import { createClient } from "@supabase/supabase-js"
import { NextRequest, NextResponse } from "next/server"

const supabaseAdmin = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!,
  { db: { schema: "psat" } }
)

export async function POST(req: NextRequest) {
  const authHeader = req.headers.get("Authorization")
  if (!authHeader?.startsWith("Bearer ")) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 })
  }

  const token = authHeader.slice(7)
  const { data: { user: caller } } = await supabaseAdmin.auth.getUser(token)
  if (!caller) return NextResponse.json({ error: "Unauthorized" }, { status: 401 })

  const { data: callerProfile } = await supabaseAdmin
    .from("profiles")
    .select("role")
    .eq("id", caller.id)
    .single()

  if (!callerProfile || callerProfile.role !== "admin") {
    return NextResponse.json({ error: "Forbidden" }, { status: 403 })
  }

  const body = await req.json()
  const { userId, profileData, guruData } = body

  if (!userId) {
    return NextResponse.json({ error: "userId wajib diisi" }, { status: 400 })
  }

  // Peran sekarang diturunkan dari LMS (role + flag is_penulis_soal /
  // is_soal_validator), jadi mengirimnya ke sini tidak akan berpengaruh apa-apa.
  // Ditolak terang-terangan supaya tidak terlihat "tersimpan" padahal tidak.
  const { data: targetProfile } = await supabaseAdmin
    .from("profiles")
    .select("role")
    .eq("id", userId)
    .maybeSingle()

  if (profileData.role && targetProfile && profileData.role !== targetProfile.role) {
    return NextResponse.json(
      { error: "Peran diatur dari LMS, bukan dari sini. Ubah lewat Kelola Guru → Soal PSAT." },
      { status: 400 },
    )
  }

  // psat.profiles adalah view: trigger INSTEAD OF menyalurkan nama ke
  // public.profiles, dan no_hp/kelas ke psat.psat_guru_data.
  const { error: profileError } = await supabaseAdmin
    .from("profiles")
    .update({
      nama: profileData.nama,
      no_hp: profileData.no_hp,
      kelas: profileData.kelas ?? null,
    })
    .eq("id", userId)

  if (profileError) {
    return NextResponse.json({ error: "Gagal update profil: " + profileError.message }, { status: 500 })
  }

  // Upsert psat_guru_data
  const { data: existing } = await supabaseAdmin
    .from("psat_guru_data")
    .select("id")
    .eq("profile_id", userId)
    .maybeSingle()

  const payload = {
    whatsapp: guruData.no_hp,
    unit_sekolah: guruData.unit_sekolah,
    bank: guruData.bank,
    no_rekening: guruData.no_rekening,
    mapel_id: guruData.mapel_id ?? null,
  }

  if (existing) {
    const { error: guruError } = await supabaseAdmin
      .from("psat_guru_data")
      .update({ ...payload, updated_at: new Date().toISOString() })
      .eq("id", existing.id)
    if (guruError) {
      return NextResponse.json({ error: "Gagal update data guru: " + guruError.message }, { status: 500 })
    }
  } else {
    const { error: guruError } = await supabaseAdmin
      .from("psat_guru_data")
      .insert({ profile_id: userId, ...payload })
    if (guruError) {
      return NextResponse.json({ error: "Gagal insert data guru: " + guruError.message }, { status: 500 })
    }
  }

  return NextResponse.json({ success: true })
}
