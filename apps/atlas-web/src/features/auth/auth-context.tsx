import type { Session, User } from '@supabase/supabase-js'
import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  type PropsWithChildren,
} from 'react'
import { z } from 'zod'
import { supabase } from '../../shared/lib/supabase'

const agentSchema = z.object({
  agent_code: z.string(),
  relationship_code: z.string().nullable().optional(),
  status: z.string(),
})

const companySchema = z.object({
  agents: z.array(agentSchema),
  display_name: z.string().nullable(),
  empresa_city: z.string().nullable(),
  empresa_commercial_name: z.string().nullable(),
  empresa_country: z.string().nullable(),
  empresa_id: z.string().uuid(),
  empresa_name: z.string(),
  empresa_status: z.string(),
  empresa_timezone: z.string().nullable(),
  membership_id: z.string().uuid(),
  permissions: z.array(z.string()),
  role_code: z.string(),
  role_name: z.string(),
  role_priority: z.number(),
})

const bootstrapSchema = z.object({
  bootstrap_status: z.literal('READY'),
  companies: z.array(companySchema).min(1),
  company_count: z.number().int().positive(),
  default_empresa_id: z.string().uuid(),
  requires_company_selection: z.boolean(),
  runtime_version: z.literal('ATLAS_WEB_BOOTSTRAP_V1'),
  safe_to_continue: z.literal(true),
  user_id: z.string().uuid(),
})

export type AtlasBootstrap = z.infer<typeof bootstrapSchema>
export type AtlasCompany = z.infer<typeof companySchema>

type AuthStatus =
  | 'loading'
  | 'authenticated'
  | 'unauthenticated'
  | 'forbidden'
  | 'error'

type AuthContextValue = {
  bootstrap: AtlasBootstrap | null
  errorMessage: string | null
  session: Session | null
  status: AuthStatus
  user: User | null
  signIn: (
    email: string,
    password: string,
  ) => Promise<{ error: string | null }>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: PropsWithChildren) {
  const [session, setSession] = useState<Session | null>(null)
  const [bootstrap, setBootstrap] =
    useState<AtlasBootstrap | null>(null)
  const [status, setStatus] = useState<AuthStatus>('loading')
  const [errorMessage, setErrorMessage] =
    useState<string | null>(null)

  useEffect(() => {
    let active = true

    async function applySession(nextSession: Session | null) {
      if (!active) return

      setSession(nextSession)
      setBootstrap(null)
      setErrorMessage(null)

      if (!nextSession) {
        setStatus('unauthenticated')
        return
      }

      setStatus('loading')

      const { data, error } = await supabase.rpc(
        'atlas_web_bootstrap_context',
      )

      if (!active) return

      if (error) {
        setErrorMessage(
          'No fue posible cargar el contexto empresarial.',
        )
        setStatus('error')
        return
      }

      const parsedBootstrap = bootstrapSchema.safeParse(data)

      if (!parsedBootstrap.success) {
        setErrorMessage(
          'Atlas recibió un contrato empresarial inválido.',
        )
        setStatus('error')
        return
      }

      if (
        parsedBootstrap.data.user_id !== nextSession.user.id
      ) {
        setErrorMessage(
          'La identidad autenticada no coincide con el contexto empresarial.',
        )
        setStatus('forbidden')
        return
      }

      setBootstrap(parsedBootstrap.data)
      setStatus('authenticated')
    }

    void supabase.auth.getSession().then(
      ({ data, error }) => {
        if (!active) return

        if (error) {
          setErrorMessage(
            'No fue posible recuperar la sesión de Atlas.',
          )
          setStatus('error')
          return
        }

        void applySession(data.session)
      },
    )

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange(
      (_event, nextSession) => {
        window.setTimeout(() => {
          void applySession(nextSession)
        }, 0)
      },
    )

    return () => {
      active = false
      subscription.unsubscribe()
    }
  }, [])

  const value = useMemo<AuthContextValue>(
    () => ({
      bootstrap,
      errorMessage,
      session,
      status,
      user: session?.user ?? null,

      async signIn(email, password) {
        setStatus('loading')
        setErrorMessage(null)

        const { error } =
          await supabase.auth.signInWithPassword({
            email,
            password,
          })

        if (error) {
          setStatus('unauthenticated')

          return {
            error: 'Correo o contraseña incorrectos.',
          }
        }

        return { error: null }
      },

      async signOut() {
        await supabase.auth.signOut()
        setBootstrap(null)
        setSession(null)
        setStatus('unauthenticated')
      },
    }),
    [bootstrap, errorMessage, session, status],
  )

  return (
    <AuthContext.Provider value={value}>
      {children}
    </AuthContext.Provider>
  )
}

// oxlint-disable-next-line react/only-export-components
export function useAuth() {
  const context = useContext(AuthContext)

  if (!context) {
    throw new Error(
      'useAuth must be used inside AuthProvider',
    )
  }

  return context
}