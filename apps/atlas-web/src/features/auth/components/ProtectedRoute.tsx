import { LoaderCircle, ShieldAlert } from 'lucide-react'
import {
  Navigate,
  Outlet,
  useLocation,
} from 'react-router-dom'
import { useAuth } from '../auth-context'

export function ProtectedRoute() {
  const {
    errorMessage,
    signOut,
    status,
  } = useAuth()

  const location = useLocation()

  if (status === 'loading') {
    return (
      <main className="flex min-h-screen items-center justify-center bg-[#090b10] text-white">
        <div className="text-center">
          <LoaderCircle
            className="mx-auto animate-spin text-blue-400"
            size={30}
          />
          <p className="mt-4 text-sm text-slate-300">
            Preparando tu espacio Atlas…
          </p>
        </div>
      </main>
    )
  }

  if (status === 'unauthenticated') {
    return (
      <Navigate
        replace
        state={{ from: location.pathname }}
        to="/login"
      />
    )
  }

  if (status === 'forbidden' || status === 'error') {
    return (
      <main className="flex min-h-screen items-center justify-center bg-[#090b10] px-5">
        <section className="max-w-md rounded-3xl bg-white p-8 text-center shadow-2xl">
          <ShieldAlert
            className="mx-auto text-amber-600"
            size={34}
          />

          <h1 className="mt-5 text-2xl font-semibold">
            Acceso no disponible
          </h1>

          <p className="mt-3 text-sm leading-6 text-slate-500">
            {errorMessage ??
              'Tu cuenta no tiene un contexto empresarial activo.'}
          </p>

          <button
            className="mt-7 rounded-xl bg-slate-950 px-5 py-3 text-sm font-semibold text-white"
            onClick={() => void signOut()}
            type="button"
          >
            Cerrar sesión
          </button>
        </section>
      </main>
    )
  }

  return <Outlet />
}