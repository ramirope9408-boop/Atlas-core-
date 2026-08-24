import { createClient } from '@supabase/supabase-js'
import { z } from 'zod'

const environmentSchema = z.object({
  VITE_SUPABASE_URL: z.string().url(),
  VITE_SUPABASE_PUBLISHABLE_KEY: z
    .string()
    .min(40)
    .refine(
      (key) => key.startsWith('sb_publishable_'),
      'A Supabase publishable key is required',
    ),
})

const environment = environmentSchema.safeParse(import.meta.env)

if (!environment.success) {
  throw new Error('Atlas Web Supabase environment is invalid')
}

export const supabase = createClient(
  environment.data.VITE_SUPABASE_URL,
  environment.data.VITE_SUPABASE_PUBLISHABLE_KEY,
  {
    auth: {
      autoRefreshToken: true,
      detectSessionInUrl: true,
      persistSession: true,
    },
  },
)