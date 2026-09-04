"use client"

import { useEffect, useRef, useState } from 'react'
import { useEditor, EditorContent } from '@tiptap/react'
import StarterKit from '@tiptap/starter-kit'
import Image from '@tiptap/extension-image'
import Placeholder from '@tiptap/extension-placeholder'
import TextAlign from '@tiptap/extension-text-align'
import Superscript from '@tiptap/extension-superscript'
import Subscript from '@tiptap/extension-subscript'
import { Table } from '@tiptap/extension-table'
import { TableRow } from '@tiptap/extension-table-row'
import { TableCell } from '@tiptap/extension-table-cell'
import { TableHeader } from '@tiptap/extension-table-header'
import {
  Bold, Italic, Strikethrough, Underline as UnderlineIcon,
  AlignLeft, AlignCenter, AlignRight, AlignJustify,
  List, ListOrdered,
  Image as ImageIcon,
  Upload,
  Superscript as SuperscriptIcon,
  Subscript as SubscriptIcon,
  Table as TableIcon,
  Plus, Trash2,
} from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { InlineMath } from '@/lib/extensions/InlineMath'

/** Simbol yang paling sering dipakai soal SMP. Disisipkan sebagai teks biasa. */
const SIMBOL_MATEMATIKA = [
  { char: "\u00b1", nama: "Plus-minus" },
  { char: "\u00d7", nama: "Kali" },
  { char: "\u00f7", nama: "Bagi" },
  { char: "\u03c0", nama: "Pi" },
  { char: "\u2264", nama: "Kurang dari atau sama dengan" },
  { char: "\u2265", nama: "Lebih dari atau sama dengan" },
  { char: "\u2260", nama: "Tidak sama dengan" },
  { char: "\u2248", nama: "Kira-kira sama dengan" },
  { char: "\u00b0", nama: "Derajat" },
  { char: "\u2220", nama: "Sudut" },
  { char: "\u221e", nama: "Tak hingga" },
  { char: "\u221a", nama: "Akar (simbol saja)" },
  { char: "\u0394", nama: "Delta" },
  { char: "\u2211", nama: "Sigma (jumlah)" },
  { char: "\u22c5", nama: "Titik kali" },
] as const

interface RichTextEditorProps {
  content: string
  onChange: (html: string) => void
  placeholder?: string
  mini?: boolean
}

async function calculateFileHash(file: File): Promise<string> {
  const buffer = await file.arrayBuffer()
  const hashBuffer = await crypto.subtle.digest('SHA-256', buffer)
  const hashArray = Array.from(new Uint8Array(hashBuffer))
  return hashArray.map(b => b.toString(16).padStart(2, '0')).join('')
}

async function convertToJpeg(file: File): Promise<File> {
  if (file.type === 'image/jpeg' || file.type === 'image/png') return file
  return new Promise(resolve => {
    const img = new window.Image()
    const url = URL.createObjectURL(file)
    img.onload = () => {
      const canvas = document.createElement('canvas')
      canvas.width = img.naturalWidth
      canvas.height = img.naturalHeight
      const ctx = canvas.getContext('2d')!
      ctx.fillStyle = '#ffffff'
      ctx.fillRect(0, 0, canvas.width, canvas.height)
      ctx.drawImage(img, 0, 0)
      URL.revokeObjectURL(url)
      canvas.toBlob(blob => {
        resolve(blob
          ? new File([blob], file.name.replace(/\.[^.]+$/, '.jpg'), { type: 'image/jpeg' })
          : file)
      }, 'image/jpeg', 0.92)
    }
    img.onerror = () => { URL.revokeObjectURL(url); resolve(file) }
    img.src = url
  })
}

async function uploadImageFile(file: File): Promise<string | null> {
  try {
    const converted = await convertToJpeg(file)
    const fileHash = await calculateFileHash(converted)
    const { data: existing } = await supabase
      .from('psat_image_uploads')
      .select('image_url')
      .eq('file_hash', fileHash)
      .maybeSingle()
    if (existing) return existing.image_url

    const fileExt = converted.name.split('.').pop() || 'jpg'
    const fileName = `${Date.now()}-${Math.random().toString(36).substring(7)}.${fileExt}`
    const { error: uploadError } = await supabase.storage
      .from('soal-images')
      .upload(fileName, converted, { cacheControl: '3600', upsert: false })
    if (uploadError) { console.error('Upload error:', uploadError); return null }

    const { data: { publicUrl } } = supabase.storage.from('soal-images').getPublicUrl(fileName)
    await supabase.from('psat_image_uploads').insert({
      file_name: converted.name, file_size: converted.size, file_hash: fileHash, image_url: publicUrl,
    })
    return publicUrl
  } catch (err) {
    console.error('Error:', err)
    return null
  }
}

export default function RichTextEditor({ content, onChange, placeholder = "Write something...", mini = false }: RichTextEditorProps) {
  const [uploading, setUploading] = useState(false)
  const [showFracPopover, setShowFracPopover] = useState(false)
  const [showTablePopover, setShowTablePopover] = useState(false)
  const [fracNum, setFracNum] = useState("")
  const [fracDen, setFracDen] = useState("")
  const [showAkarPopover, setShowAkarPopover] = useState(false)
  const [showSimbolPopover, setShowSimbolPopover] = useState(false)
  const [akarIsi, setAkarIsi] = useState("")
  const [akarPangkat, setAkarPangkat] = useState("")
  const [tableRows, setTableRows] = useState(3)
  const [tableCols, setTableCols] = useState(3)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const editor = useEditor({
    immediatelyRender: false,
    extensions: [
      StarterKit,
      Superscript,
      Subscript,
      InlineMath,
      ...(mini ? [] : [
        Image.configure({ inline: true, allowBase64: false }),
        TextAlign.configure({ types: ['heading', 'paragraph'] }),
        Table.configure({ resizable: false }),
        TableRow,
        TableHeader,
        TableCell,
      ]),
      Placeholder.configure({ placeholder }),
    ],
    content: content || "",
    onUpdate: ({ editor }) => {
      onChange(editor.getHTML())
    },
    editorProps: {
      attributes: {
        class: mini
          ? "focus:outline-none min-h-[38px] px-3 py-2 text-sm"
          : "prose prose-sm max-w-none focus:outline-none min-h-[120px] p-3",
      },
      handlePaste(_view, event) {
        const items = Array.from(event.clipboardData?.items ?? [])
        const imageItem = items.find(item => item.type.startsWith('image/'))
        if (!imageItem) return false

        event.preventDefault()
        const file = imageItem.getAsFile()
        if (!file) return true

        setUploading(true)
        uploadImageFile(file).then(url => {
          if (url) editor?.chain().focus().setImage({ src: url }).run()
          setUploading(false)
        })
        return true
      },
    },
  })

  useEffect(() => {
    if (!editor) return
    const currentHTML = editor.getHTML()
    const isEmpty = currentHTML === "<p></p>" || currentHTML === ""
    if (content === "" && !isEmpty) {
      editor.commands.setContent("", { emitUpdate: false })
    } else if (content !== "" && currentHTML !== content) {
      editor.commands.setContent(content, { emitUpdate: false })
    }
  }, [content, editor])

  if (!editor) {
    return null
  }

  const insertTable = () => {
    editor.chain().focus().insertTable({ rows: tableRows, cols: tableCols, withHeaderRow: true }).run()
    setShowTablePopover(false)
  }

  /** Sisipkan rumus sebagai node LaTeX. Guru tidak pernah melihat sintaksnya. */
  const sisipkanRumus = (latex: string) => {
    editor.chain().focus().insertContent({ type: 'inlineMath', attrs: { latex } }).run()
  }

  const insertFraction = () => {
    if (!fracNum && !fracDen) return
    sisipkanRumus(`\\frac{${fracNum || '\\square'}}{${fracDen || '\\square'}}`)
    setFracNum("")
    setFracDen("")
    setShowFracPopover(false)
  }

  const insertAkar = () => {
    if (!akarIsi) return
    // \sqrt[n]{x} untuk akar pangkat n, \sqrt{x} untuk akar kuadrat.
    sisipkanRumus(akarPangkat ? `\\sqrt[${akarPangkat}]{${akarIsi}}` : `\\sqrt{${akarIsi}}`)
    setAkarIsi("")
    setAkarPangkat("")
    setShowAkarPopover(false)
  }

  const handleImageUpload = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    setUploading(true)
    const url = await uploadImageFile(file)
    if (url) editor.chain().focus().setImage({ src: url }).run()
    setUploading(false)
    if (fileInputRef.current) fileInputRef.current.value = ''
  }

  const btnBase = `p-1.5 rounded hover:bg-gray-100 dark:hover:bg-gray-800`
  const btnActive = "bg-gray-200 dark:bg-gray-700"
  const sep = <div className="w-px bg-gray-300 dark:bg-gray-600 mx-0.5" />

  const mathButtons = (
    <>
      <button type="button" onClick={() => editor.chain().focus().toggleSuperscript().run()}
        className={`${btnBase} ${editor.isActive("superscript") ? btnActive : ""}`}
        style={{ color: "var(--color-foreground)" }} title="Pangkat (Superscript)">
        <SuperscriptIcon className="w-3.5 h-3.5" />
      </button>
      <button type="button" onClick={() => editor.chain().focus().toggleSubscript().run()}
        className={`${btnBase} ${editor.isActive("subscript") ? btnActive : ""}`}
        style={{ color: "var(--color-foreground)" }} title="Subscript">
        <SubscriptIcon className="w-3.5 h-3.5" />
      </button>
      <button type="button" onClick={() => editor.chain().focus().insertContent('°').run()}
        className={btnBase}
        style={{ color: "var(--color-foreground)", fontWeight: 700, fontSize: "14px", lineHeight: 1 }}
        title="Derajat (°)">
        °
      </button>
      <div className="relative">
        <button type="button" onClick={() => setShowFracPopover(v => !v)}
          className={`${btnBase} ${showFracPopover ? btnActive : ""}`}
          style={{ color: "var(--color-foreground)" }} title="Pecahan">
          <span style={{ fontSize: "11px", fontWeight: 700, lineHeight: 1, fontFamily: "serif" }}>a/b</span>
        </button>
        {showFracPopover && (
          <div
            className="absolute top-full left-0 mt-1 z-20 p-3 rounded-md border shadow-lg flex flex-col gap-2"
            style={{ backgroundColor: "var(--color-card)", borderColor: "var(--color-border)", minWidth: "150px" }}
          >
            <input autoFocus placeholder="Pembilang" value={fracNum}
              onChange={e => setFracNum(e.target.value)}
              className="border rounded px-2 py-1 text-sm w-full"
              style={{ borderColor: "var(--color-border)", backgroundColor: "var(--color-background)", color: "var(--color-foreground)" }}
            />
            <div className="w-full border-t" style={{ borderColor: "var(--color-foreground)" }} />
            <input placeholder="Penyebut" value={fracDen}
              onChange={e => setFracDen(e.target.value)}
              onKeyDown={e => e.key === 'Enter' && insertFraction()}
              className="border rounded px-2 py-1 text-sm w-full"
              style={{ borderColor: "var(--color-border)", backgroundColor: "var(--color-background)", color: "var(--color-foreground)" }}
            />
            <button onClick={insertFraction} className="text-xs px-2 py-1 rounded text-center"
              style={{ backgroundColor: "var(--color-primary)", color: "#fff" }}>
              Sisipkan
            </button>
          </div>
        )}
      </div>

      {/* Akar — kotak isi wajib, pangkat opsional (kosong = akar kuadrat) */}
      <div className="relative">
        <button type="button" onClick={() => setShowAkarPopover(v => !v)}
          className={`${btnBase} ${showAkarPopover ? btnActive : ""}`}
          style={{ color: "var(--color-foreground)", fontWeight: 700, fontSize: "14px", lineHeight: 1 }}
          title="Akar">
          &#8730;
        </button>
        {showAkarPopover && (
          <div
            className="absolute top-full left-0 mt-1 z-20 p-3 rounded-md border shadow-lg flex flex-col gap-2"
            style={{ backgroundColor: "var(--color-card)", borderColor: "var(--color-border)", minWidth: "170px" }}
          >
            <input autoFocus placeholder="Isi akar, mis. 2 atau x+1" value={akarIsi}
              onChange={e => setAkarIsi(e.target.value)}
              onKeyDown={e => e.key === 'Enter' && insertAkar()}
              className="border rounded px-2 py-1 text-sm w-full"
              style={{ borderColor: "var(--color-border)", backgroundColor: "var(--color-background)", color: "var(--color-foreground)" }}
            />
            <input placeholder="Pangkat akar (kosong = 2)" value={akarPangkat}
              onChange={e => setAkarPangkat(e.target.value)}
              onKeyDown={e => e.key === 'Enter' && insertAkar()}
              className="border rounded px-2 py-1 text-sm w-full"
              style={{ borderColor: "var(--color-border)", backgroundColor: "var(--color-background)", color: "var(--color-foreground)" }}
            />
            <button onClick={insertAkar} className="text-xs px-2 py-1 rounded text-center"
              style={{ backgroundColor: "var(--color-primary)", color: "#fff" }}>
              Sisipkan
            </button>
          </div>
        )}
      </div>

      {/* Simbol umum — teks Unicode biasa, bukan node: selamat di setiap jalur
          (layar siswa, PDF, Excel, Google Form) tanpa perender apa pun. */}
      <div className="relative">
        <button type="button" onClick={() => setShowSimbolPopover(v => !v)}
          className={`${btnBase} ${showSimbolPopover ? btnActive : ""}`}
          style={{ color: "var(--color-foreground)", fontWeight: 700, fontSize: "13px", lineHeight: 1 }}
          title="Simbol matematika">
          &#960;
        </button>
        {showSimbolPopover && (
          <div
            className="absolute top-full left-0 mt-1 z-20 p-2 rounded-md border shadow-lg grid grid-cols-5 gap-1"
            style={{ backgroundColor: "var(--color-card)", borderColor: "var(--color-border)", width: "180px" }}
          >
            {SIMBOL_MATEMATIKA.map(sim => (
              <button key={sim.char} type="button" title={sim.nama}
                onClick={() => { editor.chain().focus().insertContent(sim.char).run(); setShowSimbolPopover(false) }}
                className="rounded hover:bg-gray-100 dark:hover:bg-gray-800 py-1"
                style={{ color: "var(--color-foreground)", fontSize: "15px", lineHeight: 1.3 }}>
                {sim.char}
              </button>
            ))}
          </div>
        )}
      </div>
    </>
  )

  return (
    <div className="border rounded-md" style={{ borderColor: "var(--color-border)", backgroundColor: "var(--color-background)" }}>
      <div className="flex gap-0.5 p-1.5 border-b flex-wrap items-center" style={{ borderColor: "var(--color-border)" }}>
        {/* Bold, Italic, Underline always visible */}
        <button type="button" onClick={() => editor.chain().focus().toggleBold().run()}
          className={`${btnBase} ${editor.isActive("bold") ? btnActive : ""}`}
          style={{ color: "var(--color-foreground)" }} title="Bold">
          <Bold className="w-3.5 h-3.5" />
        </button>
        <button type="button" onClick={() => editor.chain().focus().toggleItalic().run()}
          className={`${btnBase} ${editor.isActive("italic") ? btnActive : ""}`}
          style={{ color: "var(--color-foreground)" }} title="Italic">
          <Italic className="w-3.5 h-3.5" />
        </button>
        <button type="button" onClick={() => editor.chain().focus().toggleUnderline().run()}
          className={`${btnBase} ${editor.isActive("underline") ? btnActive : ""}`}
          style={{ color: "var(--color-foreground)" }} title="Underline">
          <UnderlineIcon className="w-3.5 h-3.5" />
        </button>

        {mini ? (
          /* Mini toolbar: just math */
          <>{sep}{mathButtons}</>
        ) : (
          /* Full toolbar */
          <>
            <button type="button" onClick={() => editor.chain().focus().toggleStrike().run()}
              className={`${btnBase} ${editor.isActive("strike") ? btnActive : ""}`}
              style={{ color: "var(--color-foreground)" }} title="Strikethrough">
              <Strikethrough className="w-3.5 h-3.5" />
            </button>

            {sep}

            <button type="button" onClick={() => editor.chain().focus().setTextAlign("left").run()}
              className={`${btnBase} ${editor.isActive({ textAlign: "left" }) ? btnActive : ""}`}
              style={{ color: "var(--color-foreground)" }} title="Align Left">
              <AlignLeft className="w-3.5 h-3.5" />
            </button>
            <button type="button" onClick={() => editor.chain().focus().setTextAlign("center").run()}
              className={`${btnBase} ${editor.isActive({ textAlign: "center" }) ? btnActive : ""}`}
              style={{ color: "var(--color-foreground)" }} title="Align Center">
              <AlignCenter className="w-3.5 h-3.5" />
            </button>
            <button type="button" onClick={() => editor.chain().focus().setTextAlign("right").run()}
              className={`${btnBase} ${editor.isActive({ textAlign: "right" }) ? btnActive : ""}`}
              style={{ color: "var(--color-foreground)" }} title="Align Right">
              <AlignRight className="w-3.5 h-3.5" />
            </button>
            <button type="button" onClick={() => editor.chain().focus().setTextAlign("justify").run()}
              className={`${btnBase} ${editor.isActive({ textAlign: "justify" }) ? btnActive : ""}`}
              style={{ color: "var(--color-foreground)" }} title="Justify">
              <AlignJustify className="w-3.5 h-3.5" />
            </button>

            {sep}

            <button type="button" onClick={() => editor.chain().focus().toggleBulletList().run()}
              className={`${btnBase} ${editor.isActive("bulletList") ? btnActive : ""}`}
              style={{ color: "var(--color-foreground)" }} title="Bullet List">
              <List className="w-3.5 h-3.5" />
            </button>
            <button type="button" onClick={() => editor.chain().focus().toggleOrderedList().run()}
              className={`${btnBase} ${editor.isActive("orderedList") ? btnActive : ""}`}
              style={{ color: "var(--color-foreground)" }} title="Numbered List">
              <ListOrdered className="w-3.5 h-3.5" />
            </button>

            {sep}

            {mathButtons}

            {sep}

            <input type="file" ref={fileInputRef} accept="image/jpeg,image/png,image/webp,image/gif"
              onChange={handleImageUpload} className="hidden" id="image-upload-input" />
            <label htmlFor="image-upload-input"
              className={`${btnBase} cursor-pointer ${uploading ? "opacity-50" : ""}`}
              style={{ color: "var(--color-foreground)" }} title="Upload Image">
              {uploading ? <Upload className="w-3.5 h-3.5 animate-spin" /> : <ImageIcon className="w-3.5 h-3.5" />}
            </label>

            {sep}

            {/* Table insert + controls */}
            <div className="relative">
              <button type="button" onClick={() => setShowTablePopover(v => !v)}
                className={`${btnBase} ${showTablePopover || editor.isActive("table") ? btnActive : ""}`}
                style={{ color: "var(--color-foreground)" }} title="Tabel">
                <TableIcon className="w-3.5 h-3.5" />
              </button>
              {showTablePopover && (
                <div
                  className="absolute top-full left-0 mt-1 z-20 p-3 rounded-md border shadow-lg flex flex-col gap-2"
                  style={{ backgroundColor: "var(--color-card)", borderColor: "var(--color-border)", minWidth: "160px" }}
                >
                  <div className="text-xs font-semibold" style={{ color: "var(--color-foreground)" }}>Sisipkan Tabel</div>
                  <div className="flex items-center gap-2">
                    <div className="flex flex-col gap-1 flex-1">
                      <label className="text-xs" style={{ color: "var(--color-foreground)" }}>Baris</label>
                      <input type="number" min={1} max={20} value={tableRows}
                        onChange={e => setTableRows(Math.max(1, Number(e.target.value)))}
                        className="border rounded px-2 py-1 text-sm w-full"
                        style={{ borderColor: "var(--color-border)", backgroundColor: "var(--color-background)", color: "var(--color-foreground)" }}
                      />
                    </div>
                    <div className="flex flex-col gap-1 flex-1">
                      <label className="text-xs" style={{ color: "var(--color-foreground)" }}>Kolom</label>
                      <input type="number" min={1} max={10} value={tableCols}
                        onChange={e => setTableCols(Math.max(1, Number(e.target.value)))}
                        className="border rounded px-2 py-1 text-sm w-full"
                        style={{ borderColor: "var(--color-border)", backgroundColor: "var(--color-background)", color: "var(--color-foreground)" }}
                      />
                    </div>
                  </div>
                  <button onClick={insertTable} className="text-xs px-2 py-1 rounded text-center"
                    style={{ backgroundColor: "var(--color-primary)", color: "#fff" }}>
                    Buat Tabel
                  </button>
                </div>
              )}
            </div>

            {/* Table row/col controls — only visible when cursor is inside a table */}
            {editor.isActive("table") && (
              <>
                {sep}
                <button type="button" title="Tambah baris di bawah"
                  onClick={() => editor.chain().focus().addRowAfter().run()}
                  className={btnBase} style={{ color: "var(--color-foreground)", fontSize: "10px", fontWeight: 700 }}>
                  +B
                </button>
                <button type="button" title="Hapus baris"
                  onClick={() => editor.chain().focus().deleteRow().run()}
                  className={btnBase} style={{ color: "#dc2626", fontSize: "10px", fontWeight: 700 }}>
                  <Trash2 className="w-3 h-3" />B
                </button>
                <button type="button" title="Tambah kolom di kanan"
                  onClick={() => editor.chain().focus().addColumnAfter().run()}
                  className={btnBase} style={{ color: "var(--color-foreground)", fontSize: "10px", fontWeight: 700 }}>
                  +K
                </button>
                <button type="button" title="Hapus kolom"
                  onClick={() => editor.chain().focus().deleteColumn().run()}
                  className={btnBase} style={{ color: "#dc2626", fontSize: "10px", fontWeight: 700 }}>
                  <Trash2 className="w-3 h-3" />K
                </button>
                <button type="button" title="Hapus tabel"
                  onClick={() => editor.chain().focus().deleteTable().run()}
                  className={btnBase} style={{ color: "#dc2626" }}>
                  <Trash2 className="w-3.5 h-3.5" />
                </button>
              </>
            )}
          </>
        )}
      </div>
      <div className="overflow-x-auto">
        <EditorContent editor={editor} />
      </div>
    </div>
  )
}
