import { z } from 'zod'
import { supabase } from '../../../shared/lib/supabase'

const messageSchema = z.object({
  id: z.string().uuid(),
  actor_type: z.enum(['USER', 'AGENT', 'SYSTEM']),
  agent_code: z.string().nullable().optional(),
  direction: z.enum(['INBOUND', 'OUTBOUND', 'SYSTEM']),
  message_type: z.enum(['TEXT', 'AUDIO', 'SYSTEM']),
  text_content: z.string().nullable(),
  audio_reference: z.string().nullable().optional(),
  transcription_text: z.string().nullable().optional(),
  created_at: z.string(),
  evidence: z.record(z.string(), z.unknown()).optional(),
})

const conversationSchema = z.object({
  id: z.string().uuid(),
  empresa_id: z.string().uuid(),
  agent_code: z.literal('VALENTINA'),
  mode: z.string(),
  title: z.string().nullable(),
  status: z.enum(['OPEN', 'CLOSED', 'ARCHIVED']),
  created_at: z.string(),
  updated_at: z.string(),
  last_activity_at: z.string().optional(),
  last_message: messageSchema.nullable().optional(),
  message_count: z.number().int().nonnegative().optional(),
})

const conversationListSchema = z.object({
  runtime_version: z.literal('ATLAS_WEB_INTERNAL_CONVERSATIONS_V1'),
  list_status: z.literal('READY'),
  safe_to_continue: z.literal(true),
  empresa_id: z.string().uuid(),
  conversation_count: z.number().int().nonnegative(),
  conversations: z.array(conversationSchema),
})

const messageListSchema = z.object({
  runtime_version: z.literal('ATLAS_WEB_INTERNAL_MESSAGES_V1'),
  read_status: z.literal('READY'),
  safe_to_continue: z.literal(true),
  conversation: conversationSchema,
  message_count: z.number().int().nonnegative(),
  messages: z.array(messageSchema),
})

const openConversationSchema = z.object({
  runtime_version: z.literal('ATLAS_WEB_OPEN_INTERNAL_CONVERSATION_V1'),
  open_status: z.literal('OPEN'),
  safe_to_continue: z.literal(true),
  conversation_id: z.string().uuid(),
  empresa_id: z.string().uuid(),
})

const registeredMessageSchema = z.object({
  runtime_version: z.literal('ATLAS_WEB_REGISTER_INTERNAL_TEXT_V1'),
  registration_status: z.literal('REGISTERED'),
  safe_to_continue: z.literal(true),
  conversation_id: z.string().uuid(),
  message_id: z.string().uuid(),
})

const orchestratorSchema = z.object({
  runtime_version: z.literal('INTERNAL_ORCHESTRATOR_V2'),
  decision_id: z.string().uuid(),
  next_action: z.string(),
  tool_executed: z.boolean(),
  final: z.unknown(),
})

export type ValentinaConversation = z.infer<typeof conversationSchema>
export type ValentinaMessage = z.infer<typeof messageSchema>

function contractError(contract: string) {
  return new Error(`Atlas recibió un contrato inválido: ${contract}.`)
}

export async function listValentinaConversations(empresaId: string) {
  const { data, error } = await supabase.rpc(
    'atlas_web_list_internal_conversations',
    { p_empresa_id: empresaId, p_limit: 50 },
  )

  if (error) throw new Error('No fue posible cargar las conversaciones.')

  const parsed = conversationListSchema.safeParse(data)
  if (!parsed.success) throw contractError('lista de conversaciones')
  return parsed.data
}

export async function getValentinaMessages(conversationId: string) {
  const { data, error } = await supabase.rpc(
    'atlas_web_get_internal_messages',
    { p_conversation_id: conversationId, p_limit: 250 },
  )

  if (error) throw new Error('No fue posible cargar los mensajes.')

  const parsed = messageListSchema.safeParse(data)
  if (!parsed.success) throw contractError('mensajes de conversación')
  return parsed.data
}

export async function openValentinaConversation(
  empresaId: string,
  title = 'Nueva conversación',
) {
  const { data, error } = await supabase.rpc(
    'atlas_web_open_internal_conversation',
    { p_empresa_id: empresaId, p_title: title },
  )

  if (error) throw new Error('No fue posible abrir la conversación.')

  const parsed = openConversationSchema.safeParse(data)
  if (!parsed.success) throw contractError('apertura de conversación')
  return parsed.data
}

export async function sendValentinaMessage(
  empresaId: string,
  conversationId: string,
  text: string,
) {
  const { data: registeredData, error: registeredError } = await supabase.rpc(
    'atlas_web_register_internal_text_message',
    { p_conversation_id: conversationId, p_text_content: text },
  )

  if (registeredError) throw new Error('No fue posible registrar el mensaje.')

  const registered = registeredMessageSchema.safeParse(registeredData)
  if (!registered.success) throw contractError('registro de mensaje')

  const { data: orchestratorData, error: orchestratorError } =
    await supabase.functions.invoke('atlas-internal-orchestrator', {
      body: {
        empresa_id: empresaId,
        conversation_id: conversationId,
      },
    })

  if (orchestratorError) {
    throw new Error('Valentina no pudo procesar el mensaje.')
  }

  const orchestrator = orchestratorSchema.safeParse(orchestratorData)
  if (!orchestrator.success) throw contractError('Orchestrator V2')

  return { orchestrator: orchestrator.data, registered: registered.data }
}
