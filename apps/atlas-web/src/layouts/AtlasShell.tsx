import { useEffect, useState } from 'react'
import {
  Activity,
  Bell,
  BookOpen,
  CalendarDays,
  ChevronDown,
  FileText,
  LayoutDashboard,
  LogOut,
  Menu,
  MessageSquareText,
  Search,
  Settings2,
  Sparkles,
  UsersRound,
  X,
} from 'lucide-react'
import { NavLink, Outlet } from 'react-router-dom'
import {
  useAuth,
  type AtlasCompany,
} from '../features/auth/auth-context'
import { AtlasMark } from '../shared/brand/AtlasMark'
import { cn } from '../shared/lib/cn'

const navigation = [
  { label: 'Inicio', icon: LayoutDashboard, disabled: true },
  { label: 'Valentina', icon: Sparkles, to: '/valentina' },
  {
    label: 'Conversaciones',
    icon: MessageSquareText,
    disabled: true,
  },
  { label: 'Cotizaciones', icon: FileText, disabled: true },
  { label: 'Clientes', icon: UsersRound, disabled: true },
  {
    label: 'Agenda y eventos',
    icon: CalendarDays,
    disabled: true,
  },
  { label: 'Catálogo', icon: BookOpen, disabled: true },
  { label: 'Actividad', icon: Activity, disabled: true },
]

function getInitials(value: string) {
  return value
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part[0]?.toUpperCase() ?? '')
    .join('')
}

type SidebarContentProps = {
  company: AtlasCompany
  onNavigate?: () => void
  onSignOut: () => Promise<void>
}

function SidebarContent({
  company,
  onNavigate,
  onSignOut,
}: SidebarContentProps) {
  const valentina = company.agents.find(
    (agent) => agent.agent_code === 'VALENTINA',
  )

  const companyName =
    company.empresa_commercial_name ??
    company.empresa_name

  const operatorName =
    company.display_name ??
    'Usuario Atlas'

  return (
    <>
      <div className="shrink-0 px-5 pb-7 pt-6">
        <AtlasMark />
      </div>

      <div className="mx-3 mb-5 shrink-0 rounded-2xl border border-white/[0.07] bg-white/[0.045] p-3">
        <p className="mb-2 px-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
          Empresa activa
        </p>

        <button
          aria-label="Selector de empresa disponible próximamente"
          className="flex w-full cursor-not-allowed items-center gap-3 rounded-xl p-1 text-left"
          disabled
          title="Disponible próximamente"
          type="button"
        >
          <span className="grid size-9 place-items-center rounded-xl bg-amber-300 text-xs font-bold text-slate-950">
            {getInitials(companyName)}
          </span>

          <span className="min-w-0 flex-1">
            <span className="block truncate text-sm font-semibold text-slate-100">
              {companyName}
            </span>
            <span className="block text-xs text-slate-500">
              {company.empresa_status === 'active'
                ? 'Empresa verificada'
                : company.empresa_status}
            </span>
          </span>

          <ChevronDown className="size-4 text-slate-500" />
        </button>
      </div>

      <nav
        className="min-h-0 flex-1 space-y-1 overflow-y-auto px-3"
        aria-label="Navegación principal"
      >
        {navigation.map((item) => {
          const Icon = item.icon

          if (item.to) {
            return (
              <NavLink
                key={item.label}
                to={item.to}
                onClick={onNavigate}
                className={({ isActive }) =>
                  cn(
                    'flex items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium transition',
                    isActive
                      ? 'bg-indigo-500/15 text-indigo-200 ring-1 ring-inset ring-indigo-400/15'
                      : 'text-slate-400 hover:bg-white/[0.05] hover:text-white',
                  )
                }
              >
                <Icon className="size-[18px]" />
                {item.label}
              </NavLink>
            )
          }

          return (
            <div
              key={item.label}
              className="flex cursor-not-allowed items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium text-slate-600"
              title="Disponible próximamente"
            >
              <Icon className="size-[18px]" />
              <span className="min-w-0 flex-1 truncate">{item.label}</span>
              <span className="rounded-full border border-white/[0.06] bg-white/[0.03] px-1.5 py-0.5 text-[8px] font-semibold uppercase tracking-wide text-slate-600">
                Próx.
              </span>
            </div>
          )
        })}
      </nav>

      <div className="shrink-0 border-t border-white/[0.06] p-3">
        <button
          className="flex w-full cursor-not-allowed items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium text-slate-600"
          title="Disponible próximamente"
          type="button"
        >
          <Settings2 className="size-[18px]" />
          <span className="min-w-0 flex-1 text-left">Configuración</span>
          <span className="rounded-full border border-white/[0.06] bg-white/[0.03] px-1.5 py-0.5 text-[8px] font-semibold uppercase tracking-wide text-slate-600">
            Próx.
          </span>
        </button>

        <div className="mt-2 rounded-xl bg-black/15 p-3">
          <div className="flex items-center gap-3">
            <span className="grid size-9 place-items-center rounded-full bg-gradient-to-br from-indigo-400 to-blue-600 text-xs font-bold text-white">
              {getInitials(operatorName)}
            </span>

            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-medium text-slate-200">
                {operatorName}
              </span>
              <span className="block text-xs text-slate-500">
                {company.role_name}
                {valentina?.status === 'ACTIVE'
                  ? ' · Valentina activa'
                  : ''}
              </span>
            </span>
          </div>

          <button
            className="mt-3 flex w-full items-center justify-center gap-2 rounded-lg border border-white/[0.08] px-3 py-2 text-xs font-medium text-slate-400 transition hover:bg-white/[0.06] hover:text-white"
            onClick={() => void onSignOut()}
            type="button"
          >
            <LogOut className="size-3.5" />
            Cerrar sesión
          </button>
        </div>
      </div>
    </>
  )
}

export function AtlasShell() {
  const [mobileOpen, setMobileOpen] = useState(false)
  const { bootstrap, signOut } = useAuth()

  useEffect(() => {
    if (!mobileOpen) return

    const previousOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === 'Escape') {
        setMobileOpen(false)
      }
    }

    window.addEventListener('keydown', closeOnEscape)

    return () => {
      document.body.style.overflow = previousOverflow
      window.removeEventListener('keydown', closeOnEscape)
    }
  }, [mobileOpen])

  if (!bootstrap) {
    return null
  }

  const activeCompany =
    bootstrap.companies.find(
      (company) =>
        company.empresa_id === bootstrap.default_empresa_id,
    ) ??
    bootstrap.companies[0]

  if (!activeCompany) {
    return null
  }

  const companyName =
    activeCompany.empresa_commercial_name ??
    activeCompany.empresa_name

  return (
    <div className="min-h-screen bg-[#f5f7fb] text-slate-950">
      <aside className="fixed inset-y-0 left-0 z-40 hidden w-[248px] flex-col border-r border-white/[0.06] bg-[#0a1020] lg:flex">
        <SidebarContent
          company={activeCompany}
          onSignOut={signOut}
        />
      </aside>

      {mobileOpen ? (
        <div className="fixed inset-0 z-50 lg:hidden">
          <button
            className="absolute inset-0 bg-slate-950/60 backdrop-blur-sm"
            aria-label="Cerrar menú"
            onClick={() => setMobileOpen(false)}
            type="button"
          />

          <aside
            aria-label="Menú principal"
            aria-modal="true"
            className="relative flex h-[100dvh] w-[min(82vw,320px)] flex-col overflow-hidden bg-[#0a1020] pb-[env(safe-area-inset-bottom)] shadow-2xl"
            role="dialog"
          >
            <button
              className="absolute right-4 top-5 rounded-lg p-2 text-slate-400 hover:bg-white/10 hover:text-white"
              aria-label="Cerrar menú"
              onClick={() => setMobileOpen(false)}
              type="button"
            >
              <X className="size-5" />
            </button>

            <SidebarContent
              company={activeCompany}
              onNavigate={() => setMobileOpen(false)}
              onSignOut={async () => {
                setMobileOpen(false)
                await signOut()
              }}
            />
          </aside>
        </div>
      ) : null}

      <div className="lg:pl-[248px]">
        <header className="sticky top-0 z-30 flex h-16 items-center border-b border-slate-200/80 bg-white/85 px-4 backdrop-blur-xl sm:px-6">
          <button
            className="mr-3 rounded-xl p-2 text-slate-600 hover:bg-slate-100 lg:hidden"
            aria-label="Abrir menú"
            onClick={() => setMobileOpen(true)}
            type="button"
          >
            <Menu className="size-5" />
          </button>

          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-semibold tracking-[-0.01em] text-slate-900">
              Espacio de trabajo
            </p>
            <p className="hidden text-xs text-slate-500 sm:block">
              {companyName} · Valentina Internal Operator
            </p>
          </div>

          <div className="flex items-center gap-1 sm:gap-2">
            <span className="mr-2 hidden items-center gap-2 rounded-full border border-emerald-200 bg-emerald-50 px-3 py-1.5 text-[11px] font-semibold text-emerald-800 md:flex">
              <span className="size-1.5 rounded-full bg-emerald-500" />
              Contexto verificado
            </span>

            <button
              className="cursor-not-allowed rounded-xl p-2.5 text-slate-300"
              aria-label="Buscar (disponible próximamente)"
              disabled
              title="Disponible próximamente"
              type="button"
            >
              <Search className="size-[18px]" />
            </button>

            <button
              className="relative cursor-not-allowed rounded-xl p-2.5 text-slate-300"
              aria-label="Notificaciones (disponible próximamente)"
              disabled
              title="Disponible próximamente"
              type="button"
            >
              <Bell className="size-[18px]" />
            </button>
          </div>
        </header>

        <main>
          <Outlet />
        </main>
      </div>
    </div>
  )
}