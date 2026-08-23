import {
  Bot,
  CheckCircle2,
  ChevronDown,
  CircleDollarSign,
  Clock3,
  FileText,
  MapPin,
  MoreHorizontal,
  Paperclip,
  ReceiptText,
  Send,
  ShieldCheck,
  Sparkles,
} from 'lucide-react'

const conversations = [
  {
    name: 'Cotización evento empresarial',
    preview: 'La cotización quedó creada...',
    time: 'Ahora',
    active: true,
  },
  {
    name: 'Agenda del sábado',
    preview: 'Encontré 3 eventos programados',
    time: '11:42',
  },
  {
    name: 'Consulta catálogo',
    preview: 'Estos productos contienen pollo...',
    time: 'Ayer',
  },
]

function StatusBadge() {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-full border border-emerald-200 bg-emerald-50 px-2.5 py-1 text-[11px] font-semibold text-emerald-700">
      <CheckCircle2 className="size-3.5" />
      Completada
    </span>
  )
}

export function ValentinaWorkspace() {
  return (
    <div className="mx-auto max-w-[1600px] p-3 sm:p-5 xl:p-6">
      <div className="mb-4 flex items-end justify-between gap-4 px-1">
        <div>
          <div className="flex items-center gap-2">
            <span className="grid size-9 place-items-center rounded-xl bg-indigo-600 text-white shadow-lg shadow-indigo-200">
              <Sparkles className="size-[18px]" />
            </span>
            <div>
              <h1 className="text-xl font-bold tracking-[-0.03em] text-slate-950">Valentina</h1>
              <p className="text-xs text-slate-500">Operadora interna · En línea</p>
            </div>
          </div>
        </div>
        <button className="hidden items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-700 shadow-sm hover:bg-slate-50 sm:flex">
          Nueva conversación
          <span className="rounded-md bg-slate-100 px-1.5 py-0.5 text-[10px] text-slate-500">⌘ N</span>
        </button>
      </div>

      <div className="grid min-h-[calc(100vh-9.5rem)] overflow-hidden rounded-[22px] border border-slate-200/80 bg-white shadow-[0_18px_60px_rgba(15,23,42,0.07)] xl:grid-cols-[260px_minmax(420px,1fr)_330px]">
        <aside className="hidden border-r border-slate-200/80 bg-slate-50/70 xl:block">
          <div className="border-b border-slate-200/80 p-4">
            <div className="flex items-center justify-between">
              <p className="text-xs font-bold uppercase tracking-[0.14em] text-slate-500">Conversaciones</p>
              <button className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-200/60 hover:text-slate-700" aria-label="Más opciones">
                <MoreHorizontal className="size-4" />
              </button>
            </div>
          </div>
          <div className="space-y-1.5 p-2.5">
            {conversations.map((conversation) => (
              <button
                key={conversation.name}
                className={`w-full rounded-xl p-3 text-left transition ${
                  conversation.active
                    ? 'bg-white shadow-sm ring-1 ring-slate-200/80'
                    : 'hover:bg-white/70'
                }`}
              >
                <div className="flex items-start gap-2.5">
                  <span className={`mt-1 size-2 shrink-0 rounded-full ${conversation.active ? 'bg-indigo-500' : 'bg-slate-300'}`} />
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-[13px] font-semibold text-slate-800">{conversation.name}</span>
                    <span className="mt-1 block truncate text-xs text-slate-500">{conversation.preview}</span>
                  </span>
                  <span className="text-[10px] text-slate-400">{conversation.time}</span>
                </div>
              </button>
            ))}
          </div>
        </aside>

        <section className="flex min-h-[650px] flex-col bg-white">
          <div className="flex h-[65px] items-center justify-between border-b border-slate-200/80 px-4 sm:px-5">
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold text-slate-900">Cotización evento empresarial</p>
              <p className="mt-0.5 flex items-center gap-1.5 text-[11px] text-slate-500">
                <ShieldCheck className="size-3.5 text-emerald-600" />
                Conversación interna protegida
              </p>
            </div>
            <StatusBadge />
          </div>

          <div className="flex-1 space-y-6 overflow-y-auto bg-[radial-gradient(circle_at_top,#f8faff_0%,#ffffff_48%)] px-4 py-6 sm:px-8">
            <div className="mx-auto flex max-w-2xl justify-center">
              <span className="rounded-full bg-slate-100 px-3 py-1 text-[10px] font-semibold uppercase tracking-[0.12em] text-slate-500">Hoy · 6:41 p. m.</span>
            </div>

            <div className="mx-auto flex max-w-2xl justify-end">
              <div className="max-w-[82%] rounded-2xl rounded-br-md bg-slate-900 px-4 py-3 text-sm leading-6 text-white shadow-sm">
                Valentina, crea la cotización que preparamos para el evento empresarial.
              </div>
            </div>

            <div className="mx-auto flex max-w-2xl items-start gap-3">
              <span className="grid size-9 shrink-0 place-items-center rounded-xl bg-indigo-600 text-white shadow-md shadow-indigo-100">
                <Bot className="size-[18px]" />
              </span>
              <div className="max-w-[86%]">
                <div className="rounded-2xl rounded-tl-md border border-slate-200 bg-white px-4 py-3.5 text-sm leading-6 text-slate-700 shadow-sm">
                  <p>
                    Listo, Ramiro. La cotización quedó creada y confirmada. La solicitud correspondía a una cotización ya materializada, así que conservé la existente sin generar un duplicado.
                  </p>
                  <div className="mt-4 flex flex-wrap items-center gap-2 border-t border-slate-100 pt-3">
                    <StatusBadge />
                    <span className="rounded-full bg-indigo-50 px-2.5 py-1 text-[11px] font-semibold text-indigo-700">Ejecución segura</span>
                    <span className="rounded-full bg-slate-100 px-2.5 py-1 text-[11px] font-medium text-slate-600">Sin duplicados</span>
                  </div>
                </div>
                <p className="mt-2 px-1 text-[11px] text-slate-400">Valentina · Resultado canónico verificado</p>
              </div>
            </div>
          </div>

          <div className="border-t border-slate-200/80 bg-white p-3 sm:p-4">
            <div className="mx-auto max-w-3xl rounded-2xl border border-slate-200 bg-white p-2 shadow-[0_8px_30px_rgba(15,23,42,0.06)] focus-within:border-indigo-300 focus-within:ring-4 focus-within:ring-indigo-100/60">
              <textarea
                rows={2}
                placeholder="Escríbele a Valentina..."
                className="block w-full resize-none border-0 bg-transparent px-2 py-1.5 text-sm text-slate-800 outline-none placeholder:text-slate-400"
              />
              <div className="flex items-center justify-between px-1 pt-1">
                <button className="rounded-lg p-2 text-slate-400 hover:bg-slate-100 hover:text-slate-700" aria-label="Adjuntar archivo">
                  <Paperclip className="size-[18px]" />
                </button>
                <button className="grid size-9 place-items-center rounded-xl bg-indigo-600 text-white shadow-md shadow-indigo-200 transition hover:bg-indigo-700" aria-label="Enviar mensaje">
                  <Send className="size-4" />
                </button>
              </div>
            </div>
            <p className="mt-2 text-center text-[10px] text-slate-400">Las acciones sensibles requieren permisos y trazabilidad.</p>
          </div>
        </section>

        <aside className="hidden border-l border-slate-200/80 bg-slate-50/55 xl:block">
          <div className="flex h-[65px] items-center justify-between border-b border-slate-200/80 px-4">
            <p className="text-xs font-bold uppercase tracking-[0.14em] text-slate-500">Contexto operativo</p>
            <ChevronDown className="size-4 text-slate-400" />
          </div>

          <div className="space-y-4 p-4">
            <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
              <div className="flex items-center justify-between">
                <span className="grid size-9 place-items-center rounded-xl bg-indigo-50 text-indigo-600">
                  <ReceiptText className="size-[18px]" />
                </span>
                <StatusBadge />
              </div>
              <p className="mt-4 text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-400">Quote Builder</p>
              <p className="mt-1 text-sm font-bold text-slate-900">Evento empresarial</p>
              <p className="mt-1 text-xs text-slate-500">Arma tu Mesa 2026</p>

              <div className="mt-4 grid grid-cols-2 gap-2">
                <div className="rounded-xl bg-slate-50 p-3">
                  <p className="text-[10px] uppercase tracking-wide text-slate-400">Estado</p>
                  <p className="mt-1 text-xs font-semibold text-slate-700">Materializada</p>
                </div>
                <div className="rounded-xl bg-slate-50 p-3">
                  <p className="text-[10px] uppercase tracking-wide text-slate-400">Duplicados</p>
                  <p className="mt-1 text-xs font-semibold text-emerald-700">0 generados</p>
                </div>
              </div>

              <button className="mt-4 flex w-full items-center justify-center gap-2 rounded-xl border border-slate-200 px-3 py-2.5 text-xs font-semibold text-slate-700 hover:bg-slate-50">
                <FileText className="size-4" />
                Ver cotización
              </button>
            </div>

            <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
              <p className="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-400">Resumen</p>
              <div className="mt-4 space-y-3">
                <div className="flex items-center gap-3">
                  <span className="grid size-8 place-items-center rounded-lg bg-blue-50 text-blue-600"><CircleDollarSign className="size-4" /></span>
                  <div><p className="text-[11px] text-slate-400">Resultado</p><p className="text-xs font-semibold text-slate-700">Cotización confirmada</p></div>
                </div>
                <div className="flex items-center gap-3">
                  <span className="grid size-8 place-items-center rounded-lg bg-emerald-50 text-emerald-600"><ShieldCheck className="size-4" /></span>
                  <div><p className="text-[11px] text-slate-400">Seguridad</p><p className="text-xs font-semibold text-slate-700">Permiso validado</p></div>
                </div>
                <div className="flex items-center gap-3">
                  <span className="grid size-8 place-items-center rounded-lg bg-amber-50 text-amber-600"><Clock3 className="size-4" /></span>
                  <div><p className="text-[11px] text-slate-400">Ejecución</p><p className="text-xs font-semibold text-slate-700">Idempotente</p></div>
                </div>
                <div className="flex items-center gap-3">
                  <span className="grid size-8 place-items-center rounded-lg bg-violet-50 text-violet-600"><MapPin className="size-4" /></span>
                  <div><p className="text-[11px] text-slate-400">Empresa</p><p className="text-xs font-semibold text-slate-700">FingerFood · Cartagena</p></div>
                </div>
              </div>
            </div>

            <div className="rounded-2xl border border-indigo-100 bg-indigo-50/70 p-4">
              <div className="flex gap-3">
                <Sparkles className="mt-0.5 size-4 shrink-0 text-indigo-600" />
                <div>
                  <p className="text-xs font-semibold text-indigo-950">Q1–Q8 certificados</p>
                  <p className="mt-1 text-[11px] leading-5 text-indigo-700">Esta vista representa el contrato operativo certificado de Valentina.</p>
                </div>
              </div>
            </div>
          </div>
        </aside>
      </div>
    </div>
  )
}
