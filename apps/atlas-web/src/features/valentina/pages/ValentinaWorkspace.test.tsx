import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { ValentinaWorkspace } from './ValentinaWorkspace'

describe('ValentinaWorkspace', () => {
  it('renders the governed quote execution evidence', () => {
    render(<ValentinaWorkspace />)

    expect(screen.getByRole('heading', { name: 'Valentina' })).toBeInTheDocument()
    expect(screen.getByText('Q1–Q8 certificados')).toBeInTheDocument()
    expect(screen.getByText(/Resultado canónico verificado/)).toBeInTheDocument()
  })
})
