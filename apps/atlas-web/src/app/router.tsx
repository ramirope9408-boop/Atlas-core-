import {
  Navigate,
  RouterProvider,
  createBrowserRouter,
} from 'react-router-dom'
import { ProtectedRoute } from '../features/auth/components/ProtectedRoute'
import { LoginPage } from '../features/auth/pages/LoginPage'
import { ValentinaWorkspace } from '../features/valentina/pages/ValentinaWorkspace'
import { AtlasShell } from '../layouts/AtlasShell'

const router = createBrowserRouter([
  {
    path: '/login',
    element: <LoginPage />,
  },
  {
    element: <ProtectedRoute />,
    children: [
      {
        element: <AtlasShell />,
        children: [
          {
            index: true,
            element: <Navigate to="/valentina" replace />,
          },
          {
            path: '/valentina',
            element: <ValentinaWorkspace />,
          },
        ],
      },
    ],
  },
  {
    path: '*',
    element: <Navigate to="/valentina" replace />,
  },
])

export function AppRouter() {
  return <RouterProvider router={router} />
}