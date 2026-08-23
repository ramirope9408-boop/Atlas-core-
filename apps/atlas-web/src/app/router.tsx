import { Navigate, RouterProvider, createBrowserRouter } from 'react-router-dom'
import { ValentinaWorkspace } from '../features/valentina/pages/ValentinaWorkspace'
import { AtlasShell } from '../layouts/AtlasShell'

const router = createBrowserRouter([
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
])

export function AppRouter() {
  return <RouterProvider router={router} />
}
