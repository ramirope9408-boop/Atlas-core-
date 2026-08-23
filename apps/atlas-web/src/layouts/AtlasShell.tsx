import { useState } from 'react'
import {
  Activity,
  Bell,
  BookOpen,
  CalendarDays,
  ChevronDown,
  FileText,
  LayoutDashboard,
  Menu,
  MessageSquareText,
  Search,
  Settings2,
  Sparkles,
  UsersRound,
  X,
} from 'lucide-react'
import { NavLink, Outlet } from 'react-router-dom'
import { AtlasMark } from '../shared/brand/AtlasMark'
import { cn } from '../shared/lib/cn'

const navigation = [
  { label: 'Inicio', icon: LayoutDashboard, disabled: true },
  { label: 'Valentina', icon: Sparkles, to: '/valentina' },
  { label: 'Conversaciones', icon: MessageSquareText, disabled: true },
  { label: 'Cotizaciones', icon: FileText, disabled: true },
  { label: 'Clientes', icon: UsersRound, disabled: true },
  { label: 'Agenda y eventos', icon: CalendarDays, disabled: true },
  { label: 'Catálogo', icon: BookOpen, disabled: true },
  { label: 'Actividad', icon: Activity, disabled: true },
]

function SidebarContent({ onNavigate }: { onNavigate?: () => void }) {
  return (
    <>
      <div className="px-5 pb-7 pt-6">
        <AtlasMark />
      </div>

      <div className="mx-3 mb-5 rounded-2xl border border-white/[0.07] bg-white/[0.045] p-3">
        <p className="mb-2 px-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-500">
          Empresa activa
        </p>
        <button className="flex w-full items-center gap-3 rounded-xl p-1 text-left">
          <span className="grid size-9 place-items-center rounded-xl bg-amber-300 text-xs font-bold text-slate-950">
            FF
          </span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-sm font-semibold text-slate-100">FingerFood</span>
            <span className="block text-xs text-slate-500">Tenant piloto</span>
          </span>
          <ChevronDown className="size-4 text-slate-500" />
        </button>
      </div>

      <nav className="flex-1 space-y-1 px-3" aria-label="Navegación principal">
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
              {item.label}
            </div>
          )
        })}
      </nav>

      <div className="border-t border-white/[0.06] p-3">
        <button className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-medium text-slate-400 transition hover:bg-white/[0.05] hover:text-white">
          <Settings2 className="size-[18px]" />
          Configuración
        </button>
        <div className="mt-2 flex items-center gap-3 rounded-xl bg-black/15 p-3">
          <span className="grid size-9 place-items-center rounded-full bg-gradient-to-br from-indigo-400 to-blue-600 text-xs font-bold text-white">
            RP
          </span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-sm font-medium text-slate-200">Ramiro Pereira</span>
            <span className="block text-xs text-slate-500">Owner</span>
          </span>
        </div>
      </div>
    </>
  )
}

export function AtlasShell() {
  const [mobileOpen, setMobileOpen] = useState(false)

  return (
    <div className="min-h-screen bg-[#f5f7fb] text-slate-950">
      <aside className="fixed inset-y-0 left-0 z-40 hidden w-[248px] flex-col border-r border-white/[0.06] bg-[#0a1020] lg:flex">
        <SidebarContent />
      </aside>

      {mobileOpen && (
        <div className="fixed inset-0 z-50 lg:hidden">
          <button
            className="absolute inset-0 bg-slate-950/60 backdrop-blur-sm"
            aria-label="Cerrar menú"
            onClick={() => setMobileOpen(false)}
          />
          <aside className="relative flex h-full w-[280px] flex-col bg-[#0a1020] shadow-2xl">
            <button
              className="absolute right-4 top-5 rounded-lg p-2 text-slate-400 hover:bg-white/10 hover:text-white"
              aria-label="Cerrar menú"
              onClick={() => setMobileOpen(false)}
            >
              <X className="size-5" />
            </button>
            <SidebarContent onNavigate={() => setMobileOpen(false)} />
          </aside>
        </div>
      )}

      <div className="lg:pl-[248px]">
        <header className="sticky top-0 z-30 flex h-16 items-center border-b border-slate-200/80 bg-white/85 px-4 backdrop-blur-xl sm:px-6">
          <button
            className="mr-3 rounded-xl p-2 text-slate-600 hover:bg-slate-100 lg:hidden"
            aria-label="Abrir menú"
            onClick={() => setMobileOpen(true)}
          >
            <Menu className="size-5" />
          </button>

          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-semibold tracking-[-0.01em] text-slate-900">
              Espacio de trabajo
            </p>
            <p className="hidden text-xs text-slate-500 sm:block">
              FingerFood · Valentina Internal Operator
            </p>
          </div>

          <div className="flex items-center gap-1 sm:gap-2">
            <span className="mr-2 hidden items-center gap-2 rounded-full border border-amber-200 bg-amber-50 px-3 py-1.5 text-[11px] font-semibold text-amber-800 md:flex">
              <span className="size-1.5 rounded-full bg-amber-500" />
              Entorno de diseño B1
            </span>
            <button className="rounded-xl p-2.5 text-slate-500 hover:bg-slate-100" aria-label="Buscar">
              <Search className="size-[18px]" />
            </button>
            <button className="relative rounded-xl p-2.5 text-slate-500 hover:bg-slate-100" aria-label="Notificaciones">
              <Bell className="size-[18px]" />
              <span className="absolute right-2 top-2 size-2 rounded-full border-2 border-white bg-indigo-500" />
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
