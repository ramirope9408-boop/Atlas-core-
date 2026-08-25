import { useEffect, useMemo, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  Bot,
  CheckCircle2,
  LoaderCircle,
  MessageSquarePlus,
  MoreHorizontal,
  Paperclip,
  Send,
  ShieldCheck,
  Sparkles,
} from 'lucide-react'
import { useAuth } from '../../auth/auth-context'
import {
  getValentinaMessages,
  listValentinaConversations,
  openValentinaConversation,
  sendValentinaMessage,
  type ValentinaConversation,
  type ValentinaMessage,
} from '../api/valentina-conversations'

function formatTime(value?: string) {
  if (!value) return ''
  return new Intl.DateTimeFormat('es-CO', {
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(value))
}

function conversationTitle(conversation?: ValentinaConversation) {
  return conversation?.title?.trim() || 'Nueva conversación'
}

function previewText(conversation: ValentinaConversation) {
  return conversation.last_message?.text_content || 'Conversación sin mensajes'
}

function OpenBadge() {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-full border border-emerald-200 bg-emerald-50 px-2.5 py-1 text-[11px] font-semibold text-emerald-700">
      <CheckCircle2 className="size-3.5" />
      Abierta
    </span>
  )
}

function MessageBubble({ message }: { message: ValentinaMessage }) {
  const isUser = message.actor_type === 'USER'
  const text = message.text_content || message.transcription_text || 'Mensaje sin contenido textual'

  if (isUser) {
    return (
      <div className="mx-auto flex max-w-2xl justify-end">
        <div className="max-w-[86%] rounded-2xl rounded-br-md bg-slate-900 px-4 py-3 text-sm leading-6 text-white shadow-sm">
          {text}
          <p className="mt-1 text-right text-[10px] text-slate-400">
            {formatTime(message.created_at)}
          </p>
        </div>
      </div>
    )
  }

  return (
    <div className="mx-auto flex max-w-2xl items-start gap-3">
      <span className="grid size-9 shrink-0 place-items-center rounded-xl bg-indigo-600 text-white shadow-md shadow-indigo-100">
        <Bot className="size-[18px]" />
      </span>
      <div className="max-w-[86%]">
        <div className="rounded-2xl rounded-tl-md border border-slate-200 bg-white px-4 py-3.5 text-sm leading-6 text-slate-700 shadow-sm">
          {text}
        </div>
        <p className="mt-2 px-1 text-[11px] text-slate-400">
          Valentina · {formatTime(message.created_at)}
        </p>
      </div>
    </div>
  )
}

export function ValentinaWorkspace() {
  const { bootstrap } = useAuth()
  const queryClient = useQueryClient()
  const messagesViewportRef = useRef<HTMLDivElement | null>(null)
  const [activeConversationId, setActiveConversationId] = useState<string | null>(null)
  const [draft, setDraft] = useState('')
  const [recovering, setRecovering] = useState(false)

  const empresaId = bootstrap?.default_empresa_id ?? null
  const company = bootstrap?.companies.find(
    (candidate) => candidate.empresa_id === empresaId,
  )

  const conversationsQuery = useQuery({
    queryKey: ['valentina-conversations', empresaId],
    queryFn: () => listValentinaConversations(empresaId!),
    enabled: Boolean(empresaId),
    refetchInterval: 10_000,
    refetchIntervalInBackground: false,
  })

  const conversations = useMemo(
    () => conversationsQuery.data?.conversations ?? [],
    [conversationsQuery.data],
  )

  const selectedConversationId =
    activeConversationId ?? conversations[0]?.id ?? null

  const messagesQuery = useQuery({
    queryKey: ['valentina-messages', selectedConversationId],
    queryFn: () => getValentinaMessages(selectedConversationId!),
    enabled: Boolean(selectedConversationId),
    refetchInterval: selectedConversationId ? 2_500 : false,
    refetchIntervalInBackground: false,
  })

  const activeConversation = conversations.find(
    (conversation) => conversation.id === selectedConversationId,
  )
  const messages = useMemo(
    () => messagesQuery.data?.messages ?? [],
    [messagesQuery.data],
  )

  useEffect(() => {
    const viewport = messagesViewportRef.current
    if (viewport && typeof viewport.scrollTo === 'function') {
      viewport.scrollTo({
        top: viewport.scrollHeight,
        behavior: 'smooth',
      })
    }
  }, [messages.length])

  const openMutation = useMutation({
    mutationFn: () => openValentinaConversation(empresaId!),
    onSuccess: async (opened) => {
      setActiveConversationId(opened.conversation_id)
      await queryClient.invalidateQueries({
        queryKey: ['valentina-conversations', empresaId],
      })
    },
  })

  const sendMutation = useMutation({
    mutationFn: async () => {
      if (!empresaId) throw new Error('No hay una empresa activa.')
      let conversationId = selectedConversationId

      if (!conversationId) {
        const opened = await openValentinaConversation(empresaId)
        conversationId = opened.conversation_id
        setActiveConversationId(conversationId)
      }

      return sendValentinaMessage(empresaId, conversationId, draft.trim())
    },
    onSuccess: async ({ registered }) => {
      setDraft('')
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: ['valentina-conversations', empresaId],
        }),
        queryClient.invalidateQueries({
          queryKey: [
            'valentina-messages',
            registered.conversation_id,
          ],
        }),
      ])
    },
  })

  const busy =
    openMutation.isPending ||
    sendMutation.isPending ||
    recovering
  const error =
    conversationsQuery.error ||
    messagesQuery.error ||
    openMutation.error ||
    sendMutation.error

  function submitMessage() {
    if (!draft.trim() || busy) return
    sendMutation.mutate()
  }

  async function recoverWorkspace() {
    if (recovering) return

    setRecovering(true)

    try {
      openMutation.reset()
      sendMutation.reset()

      await Promise.all([
        conversationsQuery.refetch(),
        selectedConversationId
          ? messagesQuery.refetch()
          : Promise.resolve(),
      ])
    } finally {
      setRecovering(false)
    }
  }

  return (
    <div className="mx-auto max-w-[1600px] p-3 sm:p-5 xl:p-6">
      <div className="mb-4 flex items-end justify-between gap-4 px-1">
        <div className="flex items-center gap-2">
          <span className="grid size-9 place-items-center rounded-xl bg-indigo-600 text-white shadow-lg shadow-indigo-200">
            <Sparkles className="size-[18px]" />
          </span>
          <div>
            <h1 className="text-xl font-bold tracking-[-0.03em] text-slate-950">Valentina</h1>
            <p className="text-xs text-slate-500">Operadora interna · En línea</p>
          </div>
        </div>
        <button
          type="button"
          disabled={!empresaId || busy}
          onClick={() => openMutation.mutate()}
          className="flex items-center gap-2 rounded-xl border border-slate-200 bg-white px-3 py-2 text-xs font-semibold text-slate-700 shadow-sm hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
        >
          <MessageSquarePlus className="size-4" />
          Nueva conversación
        </button>
      </div>

      <div className="grid h-[calc(100dvh-9.5rem)] min-h-0 overflow-hidden rounded-[22px] border border-slate-200/80 bg-white shadow-[0_18px_60px_rgba(15,23,42,0.07)] xl:h-auto xl:min-h-[calc(100vh-9.5rem)] xl:grid-cols-[260px_minmax(420px,1fr)_330px]">
        <aside className="hidden border-r border-slate-200/80 bg-slate-50/70 xl:block">
          <div className="border-b border-slate-200/80 p-4">
            <div className="flex items-center justify-between">
              <p className="text-xs font-bold uppercase tracking-[0.14em] text-slate-500">Conversaciones</p>
              <MoreHorizontal className="size-4 text-slate-400" />
            </div>
          </div>
          <div className="space-y-1.5 p-2.5">
            {conversationsQuery.isLoading && (
              <p className="p-3 text-xs text-slate-500">Cargando conversaciones…</p>
            )}
            {conversations.map((conversation) => {
              const active = conversation.id === selectedConversationId
              return (
                <button
                  key={conversation.id}
                  type="button"
                  onClick={() => setActiveConversationId(conversation.id)}
                  className={`w-full rounded-xl p-3 text-left transition ${
                    active
                      ? 'bg-white shadow-sm ring-1 ring-slate-200/80'
                      : 'hover:bg-white/70'
                  }`}
                >
                  <div className="flex items-start gap-2.5">
                    <span className={`mt-1 size-2 shrink-0 rounded-full ${active ? 'bg-indigo-500' : 'bg-slate-300'}`} />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[13px] font-semibold text-slate-800">
                        {conversationTitle(conversation)}
                      </span>
                      <span className="mt-1 block truncate text-xs text-slate-500">
                        {previewText(conversation)}
                      </span>
                    </span>
                    <span className="text-[10px] text-slate-400">
                      {formatTime(conversation.last_activity_at)}
                    </span>
                  </div>
                </button>
              )
            })}
          </div>
        </aside>

        <section className="flex min-h-0 flex-col bg-white xl:min-h-[650px]">
          <div className="flex h-[65px] items-center justify-between border-b border-slate-200/80 px-4 sm:px-5">
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold text-slate-900">
                {conversationTitle(activeConversation)}
              </p>
              <p className="mt-0.5 flex items-center gap-1.5 text-[11px] text-slate-500">
                <ShieldCheck className="size-3.5 text-emerald-600" />
                Conversación interna protegida
              </p>
            </div>
            {activeConversation && <OpenBadge />}
          </div>

          <div
            ref={messagesViewportRef}
            data-testid="messages-viewport"
            className="min-h-0 flex-1 space-y-6 overflow-y-auto overscroll-contain bg-[radial-gradient(circle_at_top,#f8faff_0%,#ffffff_48%)] px-4 py-6 sm:px-8"
          >
            {!selectedConversationId && !conversationsQuery.isLoading && (
              <div className="mx-auto mt-24 max-w-md text-center">
                <span className="mx-auto grid size-12 place-items-center rounded-2xl bg-indigo-50 text-indigo-600">
                  <Sparkles className="size-6" />
                </span>
                <h2 className="mt-4 font-semibold text-slate-900">Comienza una conversación real</h2>
                <p className="mt-2 text-sm leading-6 text-slate-500">
                  Crea una conversación y habla con Valentina desde el entorno protegido de Atlas.
                </p>
              </div>
            )}

            {messagesQuery.isLoading && (
              <div className="flex justify-center pt-20 text-indigo-600">
                <LoaderCircle className="size-6 animate-spin" />
              </div>
            )}

            {messages.map((message) => (
              <MessageBubble key={message.id} message={message} />
            ))}

            {sendMutation.isPending && (
              <div className="mx-auto flex max-w-2xl items-center gap-3 text-xs text-slate-500">
                <LoaderCircle className="size-4 animate-spin text-indigo-600" />
                Valentina está procesando el mensaje…
              </div>
            )}
          </div>

          <div className="shrink-0 border-t border-slate-200/80 bg-white p-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] sm:p-4">
            {error && (
              <div
                role="alert"
                className="mx-auto mb-2 flex max-w-3xl items-center justify-between gap-3 rounded-xl bg-rose-50 px-3 py-2 text-xs text-rose-700"
              >
                <span>
                  {error instanceof Error
                    ? error.message
                    : 'Ocurrió un error inesperado.'}
                </span>
                <button
                  type="button"
                  disabled={recovering}
                  onClick={() => void recoverWorkspace()}
                  className="shrink-0 rounded-lg border border-rose-200 bg-white px-3 py-1.5 font-semibold text-rose-700 transition hover:bg-rose-100 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  {recovering ? 'Actualizando…' : 'Actualizar'}
                </button>
              </div>
            )}
            <div className="mx-auto max-w-3xl rounded-2xl border border-slate-200 bg-white p-2 shadow-[0_8px_30px_rgba(15,23,42,0.06)] focus-within:border-indigo-300 focus-within:ring-4 focus-within:ring-indigo-100/60">
              <textarea
                rows={2}
                value={draft}
                disabled={busy}
                onChange={(event) => setDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' && !event.shiftKey) {
                    event.preventDefault()
                    submitMessage()
                  }
                }}
                placeholder="Escríbele a Valentina…"
                className="block w-full resize-none border-0 bg-transparent px-2 py-1.5 text-sm text-slate-800 outline-none placeholder:text-slate-400 disabled:opacity-60"
              />
              <div className="flex items-center justify-between px-1 pt-1">
                <button type="button" disabled className="rounded-lg p-2 text-slate-300" aria-label="Adjuntar archivo próximamente">
                  <Paperclip className="size-[18px]" />
                </button>
                <button
                  type="button"
                  disabled={!draft.trim() || busy}
                  onClick={submitMessage}
                  className="grid size-9 place-items-center rounded-xl bg-indigo-600 text-white shadow-md shadow-indigo-200 transition hover:bg-indigo-700 disabled:cursor-not-allowed disabled:opacity-40"
                  aria-label="Enviar mensaje"
                >
                  {busy ? <LoaderCircle className="size-4 animate-spin" /> : <Send className="size-4" />}
                </button>
              </div>
            </div>
            <p className="mt-2 text-center text-[10px] text-slate-400">
              Las acciones sensibles requieren permisos y trazabilidad.
            </p>
          </div>
        </section>

        <aside className="hidden border-l border-slate-200/80 bg-slate-50/55 xl:block">
          <div className="flex h-[65px] items-center border-b border-slate-200/80 px-4">
            <p className="text-xs font-bold uppercase tracking-[0.14em] text-slate-500">Contexto operativo</p>
          </div>
          <div className="space-y-4 p-4">
            <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
              <ShieldCheck className="size-5 text-emerald-600" />
              <p className="mt-3 text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-400">Empresa autenticada</p>
              <p className="mt-1 text-sm font-bold text-slate-900">{company?.empresa_commercial_name || company?.empresa_name}</p>
              <p className="mt-1 text-xs text-slate-500">{company?.empresa_city || 'Ubicación no definida'}</p>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
              <p className="text-[11px] font-semibold uppercase tracking-[0.12em] text-slate-400">Conversación</p>
              <dl className="mt-3 space-y-3 text-xs">
                <div className="flex justify-between gap-3"><dt className="text-slate-500">Estado</dt><dd className="font-semibold text-slate-800">{activeConversation?.status || 'Sin seleccionar'}</dd></div>
                <div className="flex justify-between gap-3"><dt className="text-slate-500">Mensajes</dt><dd className="font-semibold text-slate-800">{messages.length}</dd></div>
                <div className="flex justify-between gap-3"><dt className="text-slate-500">Modo</dt><dd className="font-semibold text-slate-800">{activeConversation?.mode || '—'}</dd></div>
              </dl>
            </div>
            <div className="rounded-2xl border border-indigo-100 bg-indigo-50/70 p-4">
              <div className="flex gap-3">
                <Sparkles className="mt-0.5 size-4 shrink-0 text-indigo-600" />
                <div>
                  <p className="text-xs font-semibold text-indigo-950">Operación gobernada</p>
                  <p className="mt-1 text-[11px] leading-5 text-indigo-700">
                    Identidad, empresa, conversación y herramientas se validan antes de cada respuesta.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </aside>
      </div>
    </div>
  )
}
