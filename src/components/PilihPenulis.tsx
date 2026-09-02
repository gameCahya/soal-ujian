"use client"

import React, { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { Search, Check, X, Loader2, ChevronDown } from "lucide-react"
import { cariCalonPenulis, pesanError, type CalonPenulis } from "@/lib/ujian"

/** Jeda ketik sebelum pencarian dikirim. */
const DEBOUNCE_MS = 200
/** Di bawah ini tidak dicari: satu huruf atas ~200 guru bukan jawaban apa pun. */
const MIN_HURUF = 2

interface Props {
  ujianId: string
  /** Isi awal dropdown: pengampu mapel+tingkat ujian ini, sudah dimuat halaman. */
  calonAwal: CalonPenulis[]
  disabled?: boolean
  /**
   * Menerima baris utuh, bukan sekadar id: orang yang ditemukan lewat pencarian
   * belum tentu ada di `calonAwal`, jadi halaman harus bisa menyisipkannya —
   * kalau tidak, tombol kembali berbunyi "belum ditunjuk" padahal sudah.
   */
  onPilih: (calon: CalonPenulis | null) => void | Promise<void>
}

/**
 * Pemilih penulis matriks: daftarnya SELURUH guru aktif, dicari lewat ketikan.
 *
 * Dulu ini `<select>` berisi pengampu mapel+tingkat saja. Data `guru_mengajar`
 * di produksi belum lengkap, jadi guru yang sebenarnya ditugasi sering tidak
 * ada di daftar dan tidak ada layar lain untuk menunjuknya.
 *
 * Dua hal yang menahan permintaan supaya tidak satu per huruf:
 *   1. Dropdown dibuka → yang tampil `calonAwal`, tanpa permintaan sama sekali.
 *   2. Mengetik → satu permintaan setelah diam DEBOUNCE_MS, bukan per ketukan.
 *
 * Balasan basi juga dibuang: urutan balasan tidak dijamin, jadi tanpa penjaga
 * hasil "Bu" bisa tiba SESUDAH hasil "Budi" dan menimpanya.
 */
export default function PilihPenulis({ ujianId, calonAwal, disabled, onPilih }: Props) {
  const [buka, setBuka] = useState(false)
  const [q, setQ] = useState("")
  const [hasil, setHasil] = useState<CalonPenulis[] | null>(null)
  const [mencari, setMencari] = useState(false)
  const [galat, setGalat] = useState<string | null>(null)

  const wadahRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  /** Nomor permintaan terakhir yang dikirim — balasan lain diabaikan. */
  const seqRef = useRef(0)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const terpilih = useMemo(() => calonAwal.find(c => c.ditunjuk), [calonAwal])
  const sedangMencari = q.trim().length >= MIN_HURUF

  /**
   * Jeda ketik dipasang di handler, bukan di useEffect.
   *
   * Versi effect memanggil setState di badannya — React menandainya sebagai
   * cascading render, dan lint project menolaknya. Di handler, tiap ketukan
   * membatalkan timer sebelumnya, jadi permintaan tetap satu per jeda diam.
   */
  const ubahKueri = useCallback((nilai: string) => {
    setQ(nilai)
    if (timerRef.current) clearTimeout(timerRef.current)

    const kueri = nilai.trim()
    if (kueri.length < MIN_HURUF) {
      // Kembali ke daftar awal tanpa menembakkan apa pun. seq dinaikkan supaya
      // balasan yang masih di jalan tidak mendarat di layar yang sudah kosong.
      seqRef.current += 1
      setHasil(null)
      setMencari(false)
      setGalat(null)
      return
    }

    const seq = ++seqRef.current
    setMencari(true)
    timerRef.current = setTimeout(async () => {
      try {
        const r = await cariCalonPenulis(ujianId, kueri)
        if (seqRef.current !== seq) return
        setHasil(r)
        setGalat(null)
      } catch (e) {
        if (seqRef.current !== seq) return
        setHasil([])
        setGalat(pesanError(e))
      } finally {
        if (seqRef.current === seq) setMencari(false)
      }
    }, DEBOUNCE_MS)
  }, [ujianId])

  // Timer yang masih menyala saat komponen dilepas akan memanggil setState pada
  // komponen yang sudah tidak ada. 33 ujian × satu pemilih; tanpa ini, berpindah
  // halaman di tengah ketikan meninggalkan peringatan di konsol.
  useEffect(() => () => { if (timerRef.current) clearTimeout(timerRef.current) }, [])

  // ── Tutup saat klik di luar / Escape ──────────────────────────────────────
  useEffect(() => {
    if (!buka) return
    const diLuar = (e: MouseEvent) => {
      if (wadahRef.current && !wadahRef.current.contains(e.target as Node)) setBuka(false)
    }
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") setBuka(false) }
    document.addEventListener("mousedown", diLuar)
    document.addEventListener("keydown", esc)
    return () => {
      document.removeEventListener("mousedown", diLuar)
      document.removeEventListener("keydown", esc)
    }
  }, [buka])

  useEffect(() => { if (buka) inputRef.current?.focus() }, [buka])

  const pilih = useCallback(async (calon: CalonPenulis | null) => {
    if (timerRef.current) clearTimeout(timerRef.current)
    seqRef.current += 1
    setBuka(false)
    setQ("")
    setHasil(null)
    setMencari(false)
    await onPilih(calon)
  }, [onPilih])

  const daftar = hasil ?? calonAwal

  const gaya = {
    border: "1px solid var(--pp-ink)",
    borderRadius: 10,
    backgroundColor: "var(--pp-card)",
    color: "var(--pp-ink)",
  } as const

  return (
    <div ref={wadahRef} className="relative w-full max-w-[240px]">
      <button
        type="button"
        disabled={disabled}
        onClick={() => setBuka(v => !v)}
        className="text-xs px-2 py-1 w-full flex items-center gap-1 text-left disabled:opacity-50"
        style={gaya}
      >
        <span className="flex-1 truncate">
          {terpilih
            ? (terpilih.nama || terpilih.profile_id.slice(0, 8))
            : <span style={{ color: "var(--pp-muted)" }}>— belum ditunjuk —</span>}
        </span>
        {disabled
          ? <Loader2 size={12} className="animate-spin shrink-0" />
          : <ChevronDown size={12} className="shrink-0" style={{ color: "var(--pp-muted)" }} />}
      </button>

      {/* Guru yang ditunjuk tapi tidak tercatat mengampu tetap sah — tapi kalau
          tidak dikatakan, ia terlihat seperti salah pilih. */}
      {terpilih && !terpilih.mengampu && (
        <div className="text-[10px] mt-0.5 leading-tight" style={{ color: "var(--pp-muted)" }}>
          Tidak tercatat mengampu mapel ini — tugasnya tetap masuk karena ditunjuk.
        </div>
      )}

      {buka && (
        <div
          className="absolute z-30 mt-1 w-[280px] max-w-[80vw] shadow-lg overflow-hidden"
          style={{ ...gaya, borderRadius: 12 }}
        >
          <div className="flex items-center gap-1.5 px-2 py-1.5" style={{ borderBottom: "1px solid var(--pp-line)" }}>
            <Search size={13} className="shrink-0" style={{ color: "var(--pp-muted)" }} />
            <input
              ref={inputRef}
              value={q}
              onChange={e => ubahKueri(e.target.value)}
              placeholder="Cari nama guru…"
              className="text-xs flex-1 bg-transparent outline-none"
              style={{ color: "var(--pp-ink)" }}
            />
            {mencari && <Loader2 size={12} className="animate-spin shrink-0" style={{ color: "var(--pp-muted)" }} />}
            {q && !mencari && (
              <button type="button" onClick={() => ubahKueri("")} aria-label="Kosongkan pencarian">
                <X size={12} style={{ color: "var(--pp-muted)" }} />
              </button>
            )}
          </div>

          <div className="max-h-64 overflow-y-auto">
            <button
              type="button"
              onClick={() => void pilih(null)}
              className="w-full text-left text-xs px-2 py-1.5 hover:opacity-70"
              style={{ color: "var(--pp-muted)", borderBottom: "1px solid var(--pp-line)" }}
            >
              — lepas penunjukan —
            </button>

            {galat && (
              <div className="text-[11px] px-2 py-2" style={{ color: "#b45309" }}>
                Gagal mencari: {galat}
              </div>
            )}

            {!galat && daftar.length === 0 && (
              <div className="text-[11px] px-2 py-2" style={{ color: "var(--pp-muted)" }}>
                {sedangMencari
                  ? "Tidak ada guru aktif yang cocok. Akun tidak aktif sengaja tidak ditampilkan."
                  : "Belum ada guru tercatat mengampu mapel + tingkat ini — ketik nama untuk mencari guru mana pun."}
              </div>
            )}

            {daftar.map(c => (
              <button
                key={c.profile_id}
                type="button"
                onClick={() => void pilih(c)}
                className="w-full text-left px-2 py-1.5 hover:opacity-70 flex items-start gap-1.5"
                style={{ borderBottom: "1px solid var(--pp-line)" }}
              >
                <span className="w-3 shrink-0 pt-0.5">
                  {c.ditunjuk && <Check size={12} style={{ color: "var(--pp-primary)" }} />}
                </span>
                <span className="flex-1 min-w-0">
                  <span className="text-xs block truncate" style={{ color: "var(--pp-ink)" }}>
                    {c.nama || c.profile_id.slice(0, 8)}
                  </span>
                  {/* Nama saja tidak cukup memilih: satu ujian punya 7–11 calon
                      dari 10 unit. Sekolah dan jumlah kelas yang diampu memberi
                      dasar untuk memutuskan. */}
                  <span className="text-[10px] block truncate" style={{ color: "var(--pp-muted)" }}>
                    {c.sekolah || "tanpa unit"}
                    {c.mengampu ? ` • ${c.jml_kelas} kelas` : " • bukan pengampu"}
                    {c.sudah_isi ? " • sudah mengisi" : ""}
                  </span>
                </span>
              </button>
            ))}

            {!sedangMencari && q.length > 0 && (
              <div className="text-[10px] px-2 py-1.5" style={{ color: "var(--pp-muted)" }}>
                Ketik minimal {MIN_HURUF} huruf untuk mencari seluruh guru.
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
