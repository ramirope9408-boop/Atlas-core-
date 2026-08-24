import { useState, type FormEvent } from 'react'
import { Navigate } from 'react-router-dom'
import { LoaderCircle, LockKeyhole } from 'lucide-react'
import { AtlasMark } from '../../../shared/brand/AtlasMark'
import { useAuth } from '../auth-context'

export function LoginPage() {
  const { signIn, status } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [formError, setFormError] = useState<string | null>(null)

  if (status === 'authenticated') {
    return <Navigate to="/valentina" replace />
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setFormError(null)

    const result = await signIn(email.trim(), password)

    if (result.error) {
      setFormError(result.error)
    }
  }

  const submitting = status === 'loading'

  return (
    <main className="min-h-screen bg-[#090b10] px-5 py-10 text-slate-950">
      <div className="mx-auto flex min-h-[calc(100vh-5rem)] max-w-md items-center">
        <section className="w-full rounded-[2rem] border border-white/10 bg-white p-8 shadow-2xl shadow-black/40">
          <div className="mb-8 flex items-center gap-3">
            <AtlasMark />
            <div>
              <p className="text-xl font-semibold">Atlas</p>
              <p className="text-xs uppercase tracking-[0.24em] text-slate-500">
                Intelligence OS
              </p>
            </div>
          </div>

          <div className="mb-7">
            <div className="mb-4 inline-flex rounded-2xl bg-blue-50 p-3 text-blue-700">
              <LockKeyhole size={22} />
            </div>

            <h1 className="text-3xl font-semibold tracking-tight">
              Acceso seguro
            </h1>

            <p className="mt-2 text-sm leading-6 text-slate-500">
              Ingresa con tu cuenta autorizada para abrir el espacio
              empresarial de Atlas.
            </p>
          </div>

          <form className="space-y-5" onSubmit={handleSubmit}>
            <label className="block">
              <span className="mb-2 block text-sm font-medium">
                Correo electrónico
              </span>
              <input
                autoComplete="email"
                className="w-full rounded-xl border border-slate-200 px-4 py-3 outline-none transition focus:border-blue-500 focus:ring-4 focus:ring-blue-100"
                onChange={(event) => setEmail(event.target.value)}
                required
                type="email"
                value={email}
              />
            </label>

            <label className="block">
              <span className="mb-2 block text-sm font-medium">
                Contraseña
              </span>
              <input
                autoComplete="current-password"
                className="w-full rounded-xl border border-slate-200 px-4 py-3 outline-none transition focus:border-blue-500 focus:ring-4 focus:ring-blue-100"
                minLength={8}
                onChange={(event) => setPassword(event.target.value)}
                required
                type="password"
                value={password}
              />
            </label>

            {formError ? (
              <p
                className="rounded-xl bg-red-50 px-4 py-3 text-sm text-red-700"
                role="alert"
              >
                {formError}
              </p>
            ) : null}

            <button
              className="flex w-full items-center justify-center gap-2 rounded-xl bg-blue-700 px-4 py-3 font-semibold text-white transition hover:bg-blue-800 disabled:cursor-not-allowed disabled:opacity-60"
              disabled={submitting}
              type="submit"
            >
              {submitting ? (
                <>
                  <LoaderCircle className="animate-spin" size={18} />
                  Verificando…
                </>
              ) : (
                'Entrar a Atlas'
              )}
            </button>
          </form>

          <p className="mt-7 text-center text-xs text-slate-400">
            Sesión protegida · Acceso gobernado por empresa
          </p>
        </section>
      </div>
    </main>
  )
}