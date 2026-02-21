# Friend Features Review (Phase 1 Profiles)

## Goals

- Let users discover people by username.
- Follow/unfollow users.
- See followers/following lists.
- Let friends view each other's profiles.
- Include avatar, username, follow graph, and recent ranking activity.

## Frontend Design (Implemented in root app)

- New Friends tab in `/app` (`/Users/mac/Documents/Movie_List_MVP/pages/RankingAppPage.tsx`).
- New dedicated profile route `/profile/:profileId` (`/Users/mac/Documents/Movie_List_MVP/pages/ProfilePage.tsx`).
- New social UI component (`/Users/mac/Documents/Movie_List_MVP/components/FriendsView.tsx`) with:
  - User search + follow/unfollow actions
  - Link to user profiles
  - Following and Followers lists
  - Friend ranking activity feed
- New Supabase service layer (`/Users/mac/Documents/Movie_List_MVP/services/friendsService.ts`) with:
  - `searchUsers`
  - `getProfileSummary`
  - `getFollowingProfiles`
  - `getFollowerProfiles`
  - `getRecentProfileActivity`
  - `updateProfileAvatar`
  - `followUser`
  - `unfollowUser`
  - `getFriendFeed`

## Supabase Data Design (Schema updated for review)

File: `/Users/mac/Documents/Movie_List_MVP/supabase_schema.sql`

- Added `friend_follows` table:
  - `follower_id -> profiles.id`
  - `following_id -> profiles.id`
  - unique follow pair
  - no self-follow check
- Updated `profiles` select policy for authenticated profile discovery.
- Added profile picture support via `profiles.avatar_url`.
- Added `user_rankings` select policy so users can read rankings from accounts they follow.
- Updated `friend_follows` select policy so authenticated users can view follow graph data for profile pages.
- Added migration helper for existing projects:
  - `/Users/mac/Documents/Movie_List_MVP/supabase_phase1_profile_patch.sql`

## Backend Design (FastAPI social APIs implemented)

Files:
- `/Users/mac/Documents/Movie_List_MVP/backend/app/api/social.py`
- `/Users/mac/Documents/Movie_List_MVP/backend/app/services/social_service.py`
- `/Users/mac/Documents/Movie_List_MVP/backend/app/schemas/social.py`

Endpoints:
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

Added backend API contract tests:
- `/Users/mac/Documents/Movie_List_MVP/backend/tests/test_social_api.py`

Coverage includes:
- Auth requirement
- Follow/unfollow success and errors
- Feed/users/leaderboard response shapes
- Profile summary and profile followers response shape
