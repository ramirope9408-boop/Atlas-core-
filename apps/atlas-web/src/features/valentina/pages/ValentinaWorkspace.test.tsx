import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { ValentinaWorkspace } from './ValentinaWorkspace'

const listMock = vi.fn()
const messagesMock = vi.fn()

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
})
