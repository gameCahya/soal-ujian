"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { supabase } from "@/lib/supabase"
import {
  BookOpen, Mail, Lock, Eye, EyeOff,
  ArrowRight, Check, CheckSquare,
} from "lucide-react"

export default function LoginPage() {
  const router = useRouter()
  const [identitas, setIdentitas]      = useState("")
  const [password, setPassword]       = useState("")
  const [showPassword, setShowPassword] = useState(false)
  const [rememberMe, setRememberMe]   = useState(false)
  const [loading, setLoading]         = useState(false)
  const [error, setError]             = useState("")

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault()
    setLoading(true)
    setError("")

    // Sejak identitas PSAT disatukan dengan LMS, guru masuk memakai akun LMS —
    // dan di LMS mereka mengenal dirinya lewat username, bukan email. Kalau yang
    // diketik bukan email, tukar dulu jadi email lewat RPC yang sama dengan LMS.
    let email = identitas.trim()
    if (email && !email.includes("@")) {
      const { data: fromUsername } = await supabase
        .schema("public")
        .rpc("get_email_by_username", { p_username: email })
      if (!fromUsername) {
        setError("Username tidak ditemukan.")
        setLoading(false)
        return
      }
      email = fromUsername as string
    }

    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password })

    void supabase.from("login_log").insert({
      email,
      success: !signInError,
      user_agent: typeof navigator !== "undefined" ? navigator.userAgent : null,
    })

    if (signInError) {
      setError("Username/email atau password salah.")
      setLoading(false)
      return
    }

    router.push("/dashboard")
  }

  return (
    <div style={{ backgroundColor: "var(--pp-bg)", minHeight: "100vh", position: "relative", overflow: "hidden" }}>

      {/* Decorative blobs */}
      <div aria-hidden style={{
        position: "absolute", top: "-80px", left: "-80px",
        width: "280px", height: "280px", borderRadius: "50%",
        border: "1.5px solid var(--pp-ink)", backgroundColor: "var(--pp-lemon)",
        opacity: 0.7,
      }} />
      <div aria-hidden style={{
        position: "absolute", bottom: "-100px", left: "240px",
        width: "200px", height: "200px", borderRadius: "50%",
        border: "1.5px solid var(--pp-ink)", backgroundColor: "var(--pp-mint)",
        opacity: 0.6,
      }} />
      <div aria-hidden style={{
        position: "absolute", top: "160px", right: "-60px",
        width: "240px", height: "240px", borderRadius: "50%",
        border: "1.5px solid var(--pp-ink)", backgroundColor: "var(--pp-peach)",
        opacity: 0.5,
      }} />
      <div aria-hidden style={{
        position: "absolute", bottom: "80px", right: "280px",
        width: "100px", height: "100px",
        border: "1.5px solid var(--pp-ink)", backgroundColor: "var(--pp-lilac)",
        transform: "rotate(20deg)",
        opacity: 0.5,
      }} />

      {/* Stars */}
      <div aria-hidden style={{
        position: "absolute", top: "60px", right: "520px",
        width: "36px", height: "36px",
        backgroundColor: "var(--pp-pink)", opacity: 0.7,
        clipPath: "polygon(50% 0,61% 35%,98% 35%,68% 57%,79% 91%,50% 70%,21% 91%,32% 57%,2% 35%,39% 35%)",
      }} />
      <div aria-hidden style={{
        position: "absolute", bottom: "140px", left: "80px",
        width: "36px", height: "36px",
        backgroundColor: "var(--pp-lilac)", opacity: 0.7,
        transform: "rotate(15deg)",
        clipPath: "polygon(50% 0,61% 35%,98% 35%,68% 57%,79% 91%,50% 70%,21% 91%,32% 57%,2% 35%,39% 35%)",
      }} />

      {/* Layout */}
      <div className="relative z-10 min-h-screen grid lg:grid-cols-[1.05fr_1fr] gap-12 p-6 md:p-12 items-stretch">

        {/* LEFT — hero */}
        <div className="hidden lg:flex flex-col justify-between py-8 px-4">
          {/* Brand */}
          <div className="flex items-center gap-3.5">
            <div style={{
              width: "48px", height: "48px", borderRadius: "14px",
              backgroundColor: "var(--pp-primary)",
              display: "grid", placeItems: "center",
              color: "white", position: "relative",
              boxShadow: "0 4px 0 0 #1A2F8B", flexShrink: 0,
            }}>
              <BookOpen className="w-5 h-5" />
              <div style={{
                position: "absolute", inset: "6px", borderRadius: "10px",
                border: "1.5px dashed rgba(255,255,255,0.45)",
                pointerEvents: "none",
              }} />
            </div>
            <div>
              <div className="font-bold text-sm leading-tight" style={{ color: "var(--pp-ink)" }}>
                Portal Validasi Soal PSAT Al Abidin
              </div>
              <div className="text-xs mt-0.5" style={{ color: "var(--pp-muted)" }}>
                Bank soal — terbuka, terpantau, terlacak
              </div>
            </div>
          </div>

          {/* Hero text */}
          <div>
            <h1 className="font-display font-semibold mb-3.5" style={{
              fontSize: "64px", lineHeight: 1.02,
              letterSpacing: "-0.025em", color: "var(--pp-ink)",
            }}>
              Hari ini, mari buat{" "}
              <em style={{ fontStyle: "italic", color: "var(--pp-primary)" }}>satu soal</em>{" "}
              yang berkesan.
            </h1>
            <p style={{ fontSize: "17px", color: "var(--pp-ink-2)", lineHeight: 1.55, maxWidth: "480px" }}>
              Masuk ke portal untuk menyusun, memvalidasi, atau memantau bank soal PSAT SMP Al Abidin.
            </p>

            {/* Feature list */}
            <div className="mt-6 flex flex-col gap-3.5">
              <div className="flex items-center gap-3.5 p-3.5" style={{
                background: "var(--pp-card)",
                border: "1.5px solid var(--pp-ink)",
                borderRadius: "18px",
                boxShadow: "4px 4px 0 0 var(--pp-ink)",
                maxWidth: "440px",
              }}>
                <div style={{
                  width: "38px", height: "38px", borderRadius: "12px",
                  backgroundColor: "var(--pp-mint)", color: "#0E4A2F",
                  display: "grid", placeItems: "center", flexShrink: 0,
                }}>
                  <Check className="w-4.5 h-4.5" strokeWidth={2.5} />
                </div>
                <div>
                  <div className="font-semibold text-sm" style={{ color: "var(--pp-ink)" }}>
                    Auto-save & status real-time
                  </div>
                  <div className="text-xs mt-0.5" style={{ color: "var(--pp-muted)" }}>
                    Setiap perubahan tersimpan, status tervalidasi muncul instan
                  </div>
                </div>
              </div>

              <div className="flex items-center gap-3.5 p-3.5" style={{
                background: "var(--pp-card)",
                border: "1.5px solid var(--pp-ink)",
                borderRadius: "18px",
                boxShadow: "4px 4px 0 0 var(--pp-ink)",
                maxWidth: "440px",
              }}>
                <div style={{
                  width: "38px", height: "38px", borderRadius: "12px",
                  backgroundColor: "var(--pp-lemon)", color: "#5A4500",
                  display: "grid", placeItems: "center", flexShrink: 0,
                }}>
                  <CheckSquare className="w-4.5 h-4.5" strokeWidth={2.2} />
                </div>
                <div>
                  <div className="font-semibold text-sm" style={{ color: "var(--pp-ink)" }}>
                    Matrix kisi-kisi terintegrasi
                  </div>
                  <div className="text-xs mt-0.5" style={{ color: "var(--pp-muted)" }}>
                    Pemetaan bab, tingkat kesulitan, dan tipe soal di satu tempat
                  </div>
                </div>
              </div>
            </div>
          </div>

          {/* Quote */}
          <blockquote className="font-display" style={{
            fontStyle: "italic", fontSize: "15px",
            color: "var(--pp-ink-2)", lineHeight: 1.5,
            borderLeft: "3px solid var(--pp-peach)",
            paddingLeft: "14px", paddingTop: "6px", paddingBottom: "6px",
            maxWidth: "440px", margin: 0,
          }}>
            &ldquo;Soal yang baik bukan yang sulit dijawab — tapi yang adil membedakan paham dan belum paham.&rdquo;
            <strong style={{
              color: "var(--pp-ink)", fontStyle: "normal",
              display: "block", fontSize: "12px",
              marginTop: "6px", letterSpacing: "0.04em",
            }}>
              — Tim Akademik PSAT
            </strong>
          </blockquote>
        </div>

        {/* RIGHT — login card */}
        <div className="flex items-center justify-center">
          <div className="w-full" style={{ maxWidth: "460px" }}>
            {/* Mobile brand (only shown on small screens) */}
            <div className="flex items-center gap-3 mb-6 lg:hidden">
              <div style={{
                width: "40px", height: "40px", borderRadius: "12px",
                backgroundColor: "var(--pp-primary)",
                display: "grid", placeItems: "center",
                color: "white", position: "relative",
                boxShadow: "0 3px 0 0 #1A2F8B", flexShrink: 0,
              }}>
                <BookOpen className="w-4.5 h-4.5" />
              </div>
              <div>
                <div className="font-bold text-sm" style={{ color: "var(--pp-ink)" }}>Portal PSAT Al Abidin</div>
                <div className="text-xs" style={{ color: "var(--pp-muted)" }}>Bank soal terpantau</div>
              </div>
            </div>

            {/* Card */}
            <div className="relative shadow-hard-lg" style={{
              backgroundColor: "var(--pp-card)",
              border: "1.5px solid var(--pp-ink)",
              borderRadius: "28px",
              padding: "40px 36px",
            }}>
              {/* Ribbon */}
              <span style={{
                position: "absolute", top: "-14px", right: "32px",
                backgroundColor: "var(--pp-peach)",
                border: "1.5px solid var(--pp-ink)",
                padding: "5px 14px", borderRadius: "999px",
                fontSize: "11px", fontWeight: 700,
                textTransform: "uppercase", letterSpacing: "0.12em",
                transform: "rotate(4deg)",
                color: "var(--pp-ink)",
                whiteSpace: "nowrap",
              }}>
                Untuk guru & validator
              </span>

              <h2 className="font-display font-semibold mb-1.5" style={{
                fontSize: "36px", letterSpacing: "-0.02em", color: "var(--pp-ink)", margin: 0,
              }}>
                Selamat datang kembali
              </h2>
              <p className="mb-7 mt-1.5" style={{ fontSize: "14px", color: "var(--pp-muted)" }}>
                Masuk memakai akun LMS Anda — username dan kata sandi yang sama.
              </p>

              <form onSubmit={handleLogin} className="space-y-4">
                {/* Email */}
                <div>
                  <label className="block font-semibold uppercase mb-1.5" style={{
                    fontSize: "12px", color: "var(--pp-ink-2)", letterSpacing: "0.1em",
                  }}>
                    Username atau Email
                  </label>
                  <div className="relative">
                    <Mail className="absolute left-3.5 top-1/2 -translate-y-1/2 w-4 h-4 pointer-events-none" style={{ color: "var(--pp-muted)" }} />
                    <input
                      type="text"
                      value={identitas}
                      onChange={e => setIdentitas(e.target.value)}
                      placeholder="username LMS Anda"
                      autoComplete="username"
                      spellCheck={false}
                      required
                      style={{
                        width: "100%",
                        padding: "14px 16px 14px 44px",
                        borderRadius: "14px",
                        border: "1.5px solid var(--pp-ink)",
                        backgroundColor: "var(--pp-card)",
                        fontSize: "14px",
                        color: "var(--pp-ink)",
                        outline: "none",
                        fontFamily: "inherit",
                        boxSizing: "border-box",
                      }}
                      onFocus={e => {
                        e.currentTarget.style.borderColor = "var(--pp-primary)"
                        e.currentTarget.style.boxShadow = "3px 3px 0 0 var(--pp-primary)"
                      }}
                      onBlur={e => {
                        e.currentTarget.style.borderColor = "var(--pp-ink)"
                        e.currentTarget.style.boxShadow = "none"
                      }}
                    />
                  </div>
                </div>

                {/* Password */}
                <div>
                  <label className="block font-semibold uppercase mb-1.5" style={{
                    fontSize: "12px", color: "var(--pp-ink-2)", letterSpacing: "0.1em",
                  }}>
                    Kata sandi
                  </label>
                  <div className="relative">
                    <Lock className="absolute left-3.5 top-1/2 -translate-y-1/2 w-4 h-4 pointer-events-none" style={{ color: "var(--pp-muted)" }} />
                    <input
                      type={showPassword ? "text" : "password"}
                      value={password}
                      onChange={e => setPassword(e.target.value)}
                      placeholder="••••••••"
                      autoComplete="current-password"
                      required
                      style={{
                        width: "100%",
                        padding: "14px 44px 14px 44px",
                        borderRadius: "14px",
                        border: "1.5px solid var(--pp-ink)",
                        backgroundColor: "var(--pp-card)",
                        fontSize: "14px",
                        color: "var(--pp-ink)",
                        outline: "none",
                        fontFamily: "inherit",
                        boxSizing: "border-box",
                      }}
                      onFocus={e => {
                        e.currentTarget.style.borderColor = "var(--pp-primary)"
                        e.currentTarget.style.boxShadow = "3px 3px 0 0 var(--pp-primary)"
                      }}
                      onBlur={e => {
                        e.currentTarget.style.borderColor = "var(--pp-ink)"
                        e.currentTarget.style.boxShadow = "none"
                      }}
                    />
                    <button
                      type="button"
                      onClick={() => setShowPassword(v => !v)}
                      className="absolute right-3.5 top-1/2 -translate-y-1/2"
                      style={{ color: "var(--pp-muted)", background: "none", border: "none", cursor: "pointer", padding: 0 }}
                      aria-label={showPassword ? "Sembunyikan kata sandi" : "Tampilkan kata sandi"}
                    >
                      {showPassword ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                    </button>
                  </div>
                </div>

                {/* Remember me + forgot */}
                <div className="flex items-center justify-between mt-1.5">
                  <button
                    type="button"
                    onClick={() => setRememberMe(v => !v)}
                    className="flex items-center gap-2 text-sm"
                    style={{ color: "var(--pp-ink-2)", background: "none", border: "none", cursor: "pointer", padding: 0 }}
                  >
                    <span style={{
                      width: "18px", height: "18px",
                      border: "1.5px solid var(--pp-ink)",
                      borderRadius: "5px",
                      backgroundColor: rememberMe ? "var(--pp-lemon)" : "transparent",
                      display: "grid", placeItems: "center",
                      color: "var(--pp-ink)", flexShrink: 0,
                      transition: "background-color 0.15s",
                    }}>
                      {rememberMe && <Check className="w-3 h-3" strokeWidth={3} />}
                    </span>
                    Ingat saya di perangkat ini
                  </button>
                </div>

                {/* Error */}
                {error && (
                  <p className="text-sm px-3 py-2 rounded-lg" style={{
                    color: "#DC2626",
                    backgroundColor: "#FFE4E4",
                    border: "1px solid #FECACA",
                  }}>
                    {error}
                  </p>
                )}

                {/* Submit */}
                <button
                  type="submit"
                  disabled={loading}
                  className="flex items-center justify-center gap-2 w-full font-semibold disabled:opacity-50"
                  style={{
                    backgroundColor: "var(--pp-head-ink)",
                    color: "white",
                    padding: "15px 18px",
                    borderRadius: "14px",
                    border: "none",
                    fontSize: "14px",
                    letterSpacing: "0.02em",
                    boxShadow: "0 4px 0 0 rgba(0,0,0,0.4)",
                    cursor: loading ? "not-allowed" : "pointer",
                    fontFamily: "inherit",
                    transition: "transform 0.1s, box-shadow 0.1s",
                  }}
                  onMouseDown={e => {
                    if (!loading) {
                      e.currentTarget.style.transform = "translateY(2px)"
                      e.currentTarget.style.boxShadow = "0 2px 0 0 rgba(0,0,0,0.4)"
                    }
                  }}
                  onMouseUp={e => {
                    e.currentTarget.style.transform = ""
                    e.currentTarget.style.boxShadow = "0 4px 0 0 rgba(0,0,0,0.4)"
                  }}
                  onMouseLeave={e => {
                    e.currentTarget.style.transform = ""
                    e.currentTarget.style.boxShadow = "0 4px 0 0 rgba(0,0,0,0.4)"
                  }}
                >
                  {loading ? "Memuat..." : "Masuk ke portal"}
                  {!loading && <ArrowRight className="w-4 h-4" />}
                </button>
              </form>

              {/* Divider */}
              <div className="flex items-center gap-3 my-5" style={{ color: "var(--pp-muted)", fontSize: "12px", textTransform: "uppercase", letterSpacing: "0.16em" }}>
                <span style={{ flex: 1, height: "1px", backgroundColor: "var(--pp-line)" }} />
                atau
                <span style={{ flex: 1, height: "1px", backgroundColor: "var(--pp-line)" }} />
              </div>

              <p className="text-center" style={{ fontSize: "13px", color: "var(--pp-ink-2)" }}>
                Belum punya akun?{" "}
                <a href="/dashboard" style={{ color: "var(--pp-primary)", fontWeight: 600, textDecoration: "underline", textUnderlineOffset: "3px" }}>
                  Hubungi admin akademik
                </a>
              </p>

              {/* Doodle arrow */}
              <div style={{
                position: "absolute", bottom: "30px", right: "-76px",
                fontFamily: "var(--font-display, 'Fraunces', serif)",
                fontStyle: "italic",
                fontSize: "13px", color: "var(--pp-ink-2)",
                maxWidth: "120px", lineHeight: 1.3,
                pointerEvents: "none",
              }}>
                butuh bantuan?
                <svg width="80" height="40" viewBox="0 0 80 40" fill="none"
                     stroke="var(--pp-ink-2)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M5 30 Q 40 5, 75 30" strokeDasharray="3 3" />
                  <polyline points="68 24 75 30 68 36" />
                </svg>
              </div>
            </div>

            {/* Back to landing */}
            <div className="text-center mt-5">
              <a href="/" style={{ fontSize: "13px", color: "var(--pp-muted)", textDecoration: "none" }}>
                ← Kembali ke halaman utama
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
