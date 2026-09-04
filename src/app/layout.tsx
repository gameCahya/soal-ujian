import type { Metadata } from "next"
import { Fraunces } from "next/font/google"
import "katex/dist/katex.min.css"
import "./globals.css"

const fraunces = Fraunces({
  subsets: ["latin"],
  variable: "--font-display",
  weight: ["500", "600", "700"],
  style: ["normal", "italic"],
  display: "swap",
})

export const metadata: Metadata = {
  title: "PSAT SMP Al Abidin",
  description: "Sistem Penilaian Akhir Tahun",
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="id" suppressHydrationWarning className={fraunces.variable}>
      <head />
      <body className="min-h-screen bg-background text-foreground antialiased">
        {children}
      </body>
    </html>
  )
}