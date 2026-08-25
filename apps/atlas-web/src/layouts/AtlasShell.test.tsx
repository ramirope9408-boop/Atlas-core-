import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { AtlasShell } from './AtlasShell'

const signOutMock = vi.fn()

vi.mock('../features/auth/auth-context', () => ({
  useAuth: () => ({
    bootstrap: {
      default_empresa_id: 'bf55a6aa-2e3f-4749-b2b8-135537a7c7bf',
      companies: [
        {
          empresa_id: 'bf55a6aa-2e3f-4749-b2b8-135537a7c7bf',
          empresa_name: 'FingerFood',
          empresa_commercial_name: 'FingerFood',
          empresa_status: 'active',
          display_name: 'Ramiro Pereira',
          role_name: 'Owner',
          agents: [
            { agent_code: 'VALENTINA', status: 'ACTIVE' },
          ],
        },
      ],
    },
    signOut: signOutMock,
  }),
}))

function renderShell() {
  return render(
    <MemoryRouter initialEntries={['/valentina']}>
      <Routes>
        <Route element={<AtlasShell />}>
          <Route
            path="/valentina"
            element={<div>Contenido de Valentina</div>}
          />
        </Route>
      </Routes>
    </MemoryRouter>,
  )
}

describe('AtlasShell', () => {
  beforeEach(() => {
    signOutMock.mockReset()
    document.body.style.overflow = ''
  })

  it('communicates which navigation actions are not available yet', () => {
    renderShell()

    expect(
      screen.getByRole('button', {
        name: 'Selector de empresa disponible próximamente',
      }),
    ).toBeDisabled()
    expect(
      screen.getByRole('button', {
        name: 'Buscar (disponible próximamente)',
      }),
    ).toBeDisabled()
    expect(
      screen.getByRole('button', {
        name: 'Notificaciones (disponible próximamente)',
      }),
    ).toBeDisabled()
  })

  it('locks background scrolling and closes the mobile menu with Escape', async () => {
    renderShell()

    fireEvent.click(screen.getByRole('button', { name: 'Abrir menú' }))

    expect(
      screen.getByRole('dialog', { name: 'Menú principal' }),
    ).toBeInTheDocument()
    expect(document.body.style.overflow).toBe('hidden')

    fireEvent.keyDown(window, { key: 'Escape' })

    await waitFor(() => {
      expect(
        screen.queryByRole('dialog', { name: 'Menú principal' }),
      ).not.toBeInTheDocument()
    })
    expect(document.body.style.overflow).toBe('')
  })
})
