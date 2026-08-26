import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ValentinaWorkspace } from './ValentinaWorkspace'

const listMock = vi.fn()
const messagesMock = vi.fn()
const scrollToMock = vi.fn()

vi.mock('../../auth/auth-context', () => ({
  useAuth: () => ({
    bootstrap: {
      default_empresa_id: 'bf55a6aa-2e3f-4749-b2b8-135537a7c7bf',
      companies: [
        {
          empresa_id: 'bf55a6aa-2e3f-4749-b2b8-135537a7c7bf',
          empresa_name: 'FingerFood',
          empresa_commercial_name: 'FingerFood',
          empresa_city: 'Cartagena',
        },
      ],
    },
  }),
}))

vi.mock('../api/valentina-conversations', () => ({
  listValentinaConversations: (...args: unknown[]) => listMock(...args),
  getValentinaMessages: (...args: unknown[]) => messagesMock(...args),
  openValentinaConversation: vi.fn(),
  sendValentinaMessage: vi.fn(),
}))

describe('ValentinaWorkspace', () => {
  beforeEach(() => {
    scrollToMock.mockReset()
    Object.defineProperty(HTMLElement.prototype, 'scrollTo', {
      configurable: true,
      value: scrollToMock,
    })
    listMock.mockResolvedValue({
      conversations: [
        {
          id: '7bd35521-f994-4afa-be5c-7ab1447c1185',
          empresa_id: 'bf55a6aa-2e3f-4749-b2b8-135537a7c7bf',
          agent_code: 'VALENTINA',
          mode: 'INTERNAL_OPERATOR',
          title: 'Operación real',
          status: 'OPEN',
          created_at: '2026-08-24T02:52:35.51992+00:00',
          updated_at: '2026-08-24T02:52:35.51992+00:00',
          last_activity_at: '2026-08-24T02:52:35.51992+00:00',
          last_message: null,
          message_count: 1,
        },
      ],
    })
    messagesMock.mockResolvedValue({
      messages: [
        {
          id: 'ec37a73e-85f7-4943-9965-99118b362c17',
          actor_type: 'AGENT',
          agent_code: 'VALENTINA',
          direction: 'OUTBOUND',
          message_type: 'TEXT',
          text_content: 'Respuesta canónica de Valentina.',
          created_at: '2026-08-24T02:53:35.51992+00:00',
        },
      ],
    })
  })

  it('renders governed real conversation data', async () => {
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })

    render(
      <QueryClientProvider client={client}>
        <ValentinaWorkspace />
      </QueryClientProvider>,
    )

    expect(screen.getByText('Valentina')).toBeInTheDocument()

    await waitFor(() => {
      expect(screen.getAllByText('Operación real').length).toBeGreaterThan(0)
    })

    expect(
      await screen.findByText('Respuesta canónica de Valentina.'),
    ).toBeInTheDocument()
    expect(screen.getByText('FingerFood')).toBeInTheDocument()
  })

  it('keeps automatic message scrolling inside the conversation viewport', async () => {
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })

    render(
      <QueryClientProvider client={client}>
        <ValentinaWorkspace />
      </QueryClientProvider>,
    )

    await screen.findByText('Respuesta canónica de Valentina.')

    expect(screen.getByTestId('messages-viewport')).toBeInTheDocument()
    expect(scrollToMock).toHaveBeenCalledWith({
      top: 0,
      behavior: 'smooth',
    })
  })

  it('opens and closes the internal conversation picker on mobile', async () => {
    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })

    render(
      <QueryClientProvider client={client}>
        <ValentinaWorkspace />
      </QueryClientProvider>,
    )

    await screen.findByText('Respuesta canónica de Valentina.')

    fireEvent.click(
      screen.getByRole('button', {
        name: 'Abrir conversaciones de Valentina',
      }),
    )

    expect(
      screen.getByRole('dialog', { name: 'Conversaciones de Valentina' }),
    ).toBeInTheDocument()
    expect(document.body.style.overflow).toBe('hidden')

    fireEvent.keyDown(window, { key: 'Escape' })

    await waitFor(() => {
      expect(
        screen.queryByRole('dialog', { name: 'Conversaciones de Valentina' }),
      ).not.toBeInTheDocument()
    })
  })

  it('recovers message loading without resending content', async () => {
    messagesMock
      .mockRejectedValueOnce(new Error('Temporal test error.'))
      .mockResolvedValue({
        messages: [
          {
            id: '90fbeaf0-b012-46f5-b021-95ecbf6d0cf2',
            actor_type: 'AGENT',
            agent_code: 'VALENTINA',
            direction: 'OUTBOUND',
            message_type: 'TEXT',
            text_content: 'Respuesta recuperada.',
            created_at: '2026-08-25T17:59:00.000000+00:00',
          },
        ],
      })

    const client = new QueryClient({
      defaultOptions: { queries: { retry: false } },
    })

    render(
      <QueryClientProvider client={client}>
        <ValentinaWorkspace />
      </QueryClientProvider>,
    )

    expect(
      await screen.findByText('Temporal test error.'),
    ).toBeInTheDocument()

    fireEvent.click(
      screen.getByRole('button', { name: 'Actualizar' }),
    )

    expect(
      await screen.findByText('Respuesta recuperada.'),
    ).toBeInTheDocument()
  })
})
