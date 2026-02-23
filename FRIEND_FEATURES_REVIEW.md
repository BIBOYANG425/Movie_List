# Friend Features Review (Phase 1 Profiles)

## Goals

- Let users discover people by username.
- Follow/unfollow users.
- See followers/following lists.
- Let friends view each other's profiles.
- Include avatar, username, follow graph, and recent ranking activity.
- Enforce profile entry after signup, with ongoing edit support after sign-in.

## Frontend Design (Implemented in root app)

- Friends tab in `/app` (`/Users/mac/Documents/Movie_List_MVP/pages/RankingAppPage.tsx`).
- Dedicated profile route `/profile/:profileId` (`/Users/mac/Documents/Movie_List_MVP/pages/ProfilePage.tsx`).
- New onboarding route `/onboarding/profile` (`/Users/mac/Documents/Movie_List_MVP/pages/ProfileOnboardingPage.tsx`).
- Auth route guards now require onboarding completion before entering `/app`.
- Social UI component (`/Users/mac/Documents/Movie_List_MVP/components/FriendsView.tsx`) with:
  - User search + follow/unfollow actions
  - Link to user profiles
  - Following and Followers lists
  - Friend ranking activity feed
- Supabase service layer (`/Users/mac/Documents/Movie_List_MVP/services/friendsService.ts`) now includes:
  - `searchUsers`
  - `getProfileSummary`
  - `getFollowingProfiles`
  - `getFollowerProfiles`
  - `getRecentProfileActivity`
  - `uploadAvatarPhoto`
  - `updateMyProfile`
  - `followUser`
  - `unfollowUser`
  - `getFriendFeed`
  - `rankActivityMovie`
  - `saveActivityMovieToWatchlist`

### Profile onboarding + edit UX

- Avatar photo upload (Supabase Storage `avatars`, JPG/PNG/WEBP/GIF, max 5MB).
- Display name and bio capture at onboarding.
- Existing users can edit avatar/display name/bio on their own profile page.
- Recent activity cards now include: like, comment placeholder, share, rank, save.

## Supabase Data Design

File: `/Users/mac/Documents/Movie_List_MVP/supabase_schema.sql`

- Added `friend_follows` table and policies for follow graph visibility/actions.
- Extended `profiles` with:
  - `display_name`
  - `bio`
  - `avatar_path`
  - `onboarding_completed`
  - `updated_at`
- Added profile update timestamp trigger.
- Added avatar storage bucket + RLS policies on `storage.objects` scoped to `auth.uid()/*`.
- Added migration helper for existing projects:
  - `/Users/mac/Documents/Movie_List_MVP/supabase_phase1_profile_patch.sql`

## Backend Design (FastAPI social APIs)

Files:
- `/Users/mac/Documents/Movie_List_MVP/backend/app/api/social.py`
- `/Users/mac/Documents/Movie_List_MVP/backend/app/services/social_service.py`
- `/Users/mac/Documents/Movie_List_MVP/backend/app/schemas/social.py`
- `/Users/mac/Documents/Movie_List_MVP/backend/alembic/versions/0003_add_user_profile_fields.py`

Endpoints:
- `GET /social/me/profile` current user's editable profile
- `PATCH /social/me/profile` update profile fields
- `GET /social/profile/{user_id}` profile summary (counts + follow state)
- `GET /social/profile/{user_id}/followers` profile followers list
- `GET /social/profile/{user_id}/following` profile following list
- `GET /social/users?q=&limit=` search users with follow-state
- `POST /social/follow/{user_id}` follow a user
- `DELETE /social/follow/{user_id}` unfollow
- `GET /social/following` list followed users
- `GET /social/followers` list followers
- `GET /social/feed` ranking events from followed users
- `GET /social/leaderboard` global S-tier leaderboard

Error handling:
- Duplicate follow -> `409 ALREADY_FOLLOWING`
- Self follow -> `400 SELF_FOLLOW`
- Missing user -> `404 USER_NOT_FOUND`
- Unfollow missing relation -> `404 NOT_FOLLOWING`

## Tests

Updated backend API contract tests:
- `/Users/mac/Documents/Movie_List_MVP/backend/tests/test_social_api.py`

Coverage includes:
- Auth requirement
- Follow/unfollow success and errors
- Feed/users/leaderboard response shapes
- Me-profile read/update shapes
- Profile summary and profile followers response shape
