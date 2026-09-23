// The browser entry. A client-only SPA: no SSR, no hydration, no server routes.
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { RouterProvider } from '@tanstack/react-router';

import './styles.css';
import { router } from './router';

const host = document.getElementById('root');
if (!host) throw new Error('index.html is missing #root');

createRoot(host).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
);
