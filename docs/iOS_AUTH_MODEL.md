# Spool iOS — Auth Model

The iOS client at `ios/Spool/` uses the **same Supabase project** as the web app (`lib/supabase.ts`). It is a third client alongside web, no privileged access. All existing RLS policies apply unchanged.

## Stack

- `supabase-swift` (Postgrest, Auth, Realtime, Storage) via SPM
- Anon key + project URL, injected via `Info.plist` entries `SUPABASE_URL` and `SUPABASE_ANON_KEY`
- Session persistence: handled by the SDK; tokens land in the iOS Keychain automatically, no manual work

Do **not** ship the service role key in the iOS binary. Anon key only. Anything that needs elevated privilege must go through an edge function.

## Sign in / sign up

### Email + password

1. `auth.signUp(email, password)` creates the `auth.users` row.
2. Postgres trigger `on_auth_user_created` fires and inserts the `profiles` row via `handle_new_user()` (auto-generated unique username + avatar from metadata).
3. Client polls `profileService.getProfileByUserId` up to **10 × 250 ms** (mirror the web flow in `contexts/AuthContext.tsx`) to wait for the row to land.
4. Once the profile exists, check `onboarding_completed`. If false, route to `ProfileOnboardingView` → `MovieOnboardingView` → main tab. If true, go straight to the tab view.

### Google OAuth

1. Call `auth.signInWithOAuth(provider: .google, redirectTo: "com.spool.app://auth/callback")`.
2. The SDK opens `ASWebAuthenticationSession` (built-in, nothing to add). User completes the Google flow.
3. Google redirects to `https://<project>.supabase.co/auth/v1/callback`, which redirects to `com.spool.app://auth/callback` with the session fragment.
4. iOS receives the callback via `onOpenURL`, hands it back to the SDK which parses the fragment and stores the session in Keychain.
5. `AuthContext` observes the session change and polls for the profile (same as email).

**Xcode setup** — register `com.spool.app` as a URL scheme in `Info.plist` under `CFBundleURLTypes`. Add it to Supabase Auth → URL Configuration → Redirect URLs.

## Session lifecycle

- The SDK handles auto-refresh; no timer or hook needed.
- On `onAppear` of the root view, check `auth.session` — if present, user is signed in.
- On sign out, call `auth.signOut()` and clear any app-level caches.

## RLS contract (unchanged from web)

The iOS client has the same read/write capabilities as the web client. Nothing is special about mobile:

- **Profiles** — anyone can SELECT. INSERT/UPDATE scoped to `auth.uid() = id`.
- **Rankings (user, tv, book)** — owner or follower can SELECT; owner can write.
- **Journal entries** — three-state visibility (public / friends / private / NULL = friends); owner can write.
- **Activity events, reactions, comments** — visible based on follow graph + event type; owner can write.
- **Notifications** — owner can SELECT; authenticated users can INSERT as long as target profile exists.
- **Storage `avatars` and `journal-photos`** — public read; write scoped to `{user_id}/{filename}` prefix.

If an iOS query returns an empty list, that is not an error. It means either the row doesn't exist OR the current user doesn't have SELECT access. Surface the distinction in the UI where it matters.

## Keychain considerations

`supabase-swift` persists the session via `KeychainLocalStorage`. The Keychain service identifier is derived from the Supabase URL's host — specifically `sb-{project-ref}-auth-token`, where `project-ref` is the subdomain portion of the project URL. For a project at `https://xyzcompany.supabase.co` the Keychain service is `sb-xyzcompany-auth-token`.

`KeychainLocalStorage` accepts a `service` parameter in its initializer, so an integrator can override the default (e.g., for sharing a session across an app group, or for test isolation). We use the default today — if we ever need to customize it (e.g., to move the session into a shared keychain for a share extension), pass a custom `KeychainLocalStorage(service:)` into the `SupabaseClientOptions.auth` builder.

On app uninstall + reinstall the session is gone — that is correct behavior. If the user deletes Keychain items manually the next launch will require re-auth.

## Things this doc explicitly does NOT cover yet

- Push notifications (APNs device token → Supabase user → edge function sender). Not in scope for Phase A.
- Biometric gating (Face ID / Touch ID) as a re-auth step. Not in scope.
- Offline mode. Not in scope.

Add those docs when those features land.
