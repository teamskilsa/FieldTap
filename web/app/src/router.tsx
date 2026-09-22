// The route tree, written out by hand. The app has three pages, so there is no need for a code generator or the
// file-route plugin, and nothing here runs on a server.
import {
  createRootRoute,
  createRoute,
  createRouter,
  Link,
  Outlet,
  useRouter,
} from '@tanstack/react-router';

import { Header } from '@/components/Header';
import { Button } from '@/components/ui/button';
import { CaptureProvider } from '@/state/capture';
import { CapturePage, validateCaptureSearch } from '@/routes/capture';
import { GuidePage } from '@/routes/guide';
import { HomePage } from '@/routes/index';

function RootLayout() {
  return (
    <CaptureProvider>
      <Header />
      <main id="app-main" className="min-w-0">
        <Outlet />
      </main>
    </CaptureProvider>
  );
}

function NotFound() {
  return (
    <div className="grid min-h-[60vh] place-items-center px-4">
      <div className="max-w-md text-center">
        <h1 className="text-[20px] font-semibold leading-7">Page not found</h1>
        <p className="mt-2 text-sm text-[var(--text-3)]">That address isn't part of the analyzer.</p>
        <Button asChild className="mt-6">
          <Link to="/">Open a log</Link>
        </Button>
      </div>
    </div>
  );
}

function RouteError({ error, reset }: { error: Error; reset: () => void }) {
  const router = useRouter();
  // Logged to this browser's console only: the app reports nothing outward.
  console.error(error);
  return (
    <div className="grid min-h-[60vh] place-items-center px-4">
      <div className="max-w-md text-center">
        <h1 className="text-[20px] font-semibold leading-7">This page didn't load</h1>
        <p className="mt-2 text-sm text-[var(--text-3)]">{error.message}</p>
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <Button
            onClick={() => {
              void router.invalidate();
              reset();
            }}
          >
            Try again
          </Button>
          <Button variant="outline" asChild>
            <Link to="/">Go to the opener</Link>
          </Button>
        </div>
      </div>
    </div>
  );
}

const rootRoute = createRootRoute({
  component: RootLayout,
  notFoundComponent: NotFound,
  errorComponent: RouteError,
});

const indexRoute = createRoute({ getParentRoute: () => rootRoute, path: '/', component: HomePage });
const guideRoute = createRoute({ getParentRoute: () => rootRoute, path: '/guide', component: GuidePage });
const captureRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: '/capture',
  validateSearch: validateCaptureSearch,
  component: CapturePage,
});

export const router = createRouter({
  routeTree: rootRoute.addChildren([indexRoute, guideRoute, captureRoute]),
  scrollRestoration: true,
  defaultPreloadStaleTime: 0,
});

declare module '@tanstack/react-router' {
  interface Register {
    router: typeof router;
  }
}
