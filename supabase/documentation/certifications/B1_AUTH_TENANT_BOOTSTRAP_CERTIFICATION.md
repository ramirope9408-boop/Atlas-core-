# Atlas Web B1 — Authentication and Tenant Bootstrap Certification

Certification date: 2026-08-23

## Scope

This certification covers:

- B1A — Canonical authenticated tenant bootstrap.
- B1B — Atlas Web authentication, protected routes and real tenant binding.

It does not modify or recertify Valentina Q1–Q8.

## B1A — Backend bootstrap

Canonical RPC:

`public.atlas_web_bootstrap_context()`

Runtime contract:

`ATLAS_WEB_BOOTSTRAP_V1`

Migration:

`20260823195000_atlas_web_bootstrap_context_v1.sql`

Verified behavior:

- Resolves the authenticated user through `auth.uid()`.
- Uses active internal Atlas memberships.
- Returns authorized companies, roles and permissions.
- Returns active agent relationships.
- Does not require direct browser access to protected company tables.
- Rejects anonymous execution.
- Runs as `SECURITY DEFINER`.
- Grants execution only to authenticated and service roles.

Certified OWNER context:

- User: `fa8e19fa-b983-4e25-b3fa-53a3ffdf250b`
- Default company: `bf55a6aa-2e3f-4749-b2b8-135537a7c7bf`
- Company: FingerFood
- Role: OWNER
- Active agent: VALENTINA
- Effective permissions: 17
- Bootstrap status: READY
- Safe to continue: true

Migration history synchronization:

- Local version present: true
- Remote version present: true
- Version synchronized: true

## B1B — Frontend authentication

Verified implementation:

- Supabase browser client uses only URL and publishable key.
- No secret or service-role key is bundled into the frontend.
- `.env.local` is ignored by Git.
- Session persistence is enabled.
- Automatic token refresh is enabled.
- Protected routes require a valid authenticated session.
- The bootstrap contract is validated before rendering Atlas.
- Authenticated identity must match bootstrap `user_id`.
- Missing or invalid business context produces a governed stop.
- Logout removes the active session and returns to `/login`.

## Real tenant binding

Atlas Shell reads the canonical bootstrap and renders:

- Default authorized company.
- Verified company status.
- Authenticated operator display name.
- Effective role.
- Active Valentina relationship.
- Verified-context indicator.

No company, operator or role displayed by the shell is trusted from public request input.

## Runtime evidence

Manually verified in the browser:

1. OWNER login succeeded with email and password.
2. Protected `/valentina` route opened.
3. FingerFood rendered as the verified default company.
4. Ramiro Pereira rendered as OWNER.
5. Valentina rendered as active.
6. Logout redirected to `/login`.
7. A new login succeeded.
8. Session persisted after a full browser refresh.
9. Responsive sidebar preserved access to logout controls.

## Automated evidence

- Lint: passed with zero warnings and zero errors.
- TypeScript type-check: passed.
- Vitest suite: passed.
- Production build: passed.
- Encoding damage scan: zero matches.
- Responsive sidebar assertions: passed.

## Security boundary

Frontend environment permits only:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

The following are forbidden from frontend source and Git history:

- `service_role`
- `sb_secret_*`
- database passwords
- user passwords
- access or refresh tokens

## Certification result

`B1_AUTH_TENANT_BOOTSTRAP_CERTIFIED`

B1A and B1B are certified for the FingerFood OWNER pilot.