"""
Ranking Math Service
────────────────────
Pure-Python fallback math for the fractional indexing system.

The PRIMARY implementation lives in the Postgres functions:
  • insert_ranking_between(p_user_id, p_media_item_id, p_tier, p_prev_id, p_next_id)
  • rebalance_tier_positions(p_user_id, p_tier)

These Python methods are used for:
  1. Unit testing the math without a DB connection.
  2. Application-level validation before calling the DB function.
  3. Fallback if raw SQL call is not feasible in a particular context.

Day 3: Full unit test suite for calculate_position and interpolate_score.
"""
from decimal import Decimal, getcontext

# High-precision arithmetic to avoid float drift after many insertions
getcontext().prec = 28

REBALANCE_THRESHOLD = Decimal("1e-9")   # Minimum acceptable gap
DEFAULT_START_POSITION = Decimal("1000.0")
APPEND_STEP = Decimal("1000.0")         # Gap when appending to end


# ── Tier score ranges ─────────────────────────────────────────────────────────
# Must match the CHECK constraint in user_rankings DDL.

TIER_SCORE_RANGES: dict[str, tuple[Decimal, Decimal]] = {
    "S": (Decimal("9.0"), Decimal("10.0")),
    "A": (Decimal("8.0"), Decimal("8.9")),
    "B": (Decimal("7.0"), Decimal("7.9")),
    "C": (Decimal("6.0"), Decimal("6.9")),
    "D": (Decimal("0.0"), Decimal("5.9")),
}


class RankingMath:
    """
    Stateless helper class for fractional index calculations.
    All methods are @staticmethod — instantiation is optional.
    """

    @staticmethod
    def calculate_position(
        prev_rank: float | None,
        next_rank: float | None,
    ) -> float:
        """
        Return a rank_position value that slots between prev_rank and next_rank.

        Cases:
          (None, None)  → First item ever — default start position.
          (prev, None)  → Append to end of list.
          (None, next)  → Prepend to top of list.
          (prev, next)  → Insert between two existing items.

        Raises:
            ValueError: If the gap between prev and next is below the precision
                        threshold. The caller must trigger a rebalance first.
        """
        if prev_rank is None and next_rank is None:
            return float(DEFAULT_START_POSITION)

        if prev_rank is None:
            # Insert above the current top item
            next_d = Decimal(str(next_rank))
            return float(next_d - APPEND_STEP)

        if next_rank is None:
            # Append below the last item
            prev_d = Decimal(str(prev_rank))
            return float(prev_d + APPEND_STEP)

        # Insert between two items
        prev_d = Decimal(str(prev_rank))
        next_d = Decimal(str(next_rank))

        if prev_d >= next_d:
            raise ValueError(
                f"prev_rank ({prev_rank}) must be less than next_rank ({next_rank})"
            )

        gap = next_d - prev_d
        if gap < REBALANCE_THRESHOLD:
            raise ValueError(
                "Gap too small — trigger rebalance_tier_positions() before inserting. "
                f"gap={gap}"
            )

        mid = (prev_d + next_d) / Decimal("2")
        return float(mid)

    @staticmethod
    def interpolate_score(
        tier: str,
        prev_score: float | None,
        next_score: float | None,
    ) -> float:
        """
        Return a visual_score interpolated between two neighboring scores,
        clamped to the tier's valid range.

        Args:
            tier: One of 'S', 'A', 'B', 'C', 'D'.
            prev_score: Score of the item directly above (None if inserting at top).
            next_score: Score of the item directly below (None if inserting at bottom).

        Returns:
            Rounded float (1 decimal place) within the tier's valid range.
        """
        tier_min, tier_max = TIER_SCORE_RANGES[tier.upper()]

        if prev_score is None and next_score is None:
            # First item in tier — use midpoint of tier range
            raw = (tier_min + tier_max) / Decimal("2")
        elif prev_score is None:
            # At the very top — average of tier max and next score
            raw = (tier_max + Decimal(str(next_score))) / Decimal("2")
        elif next_score is None:
            # At the very bottom — average of prev score and tier min
            raw = (Decimal(str(prev_score)) + tier_min) / Decimal("2")
        else:
            raw = (Decimal(str(prev_score)) + Decimal(str(next_score))) / Decimal("2")

        # Clamp to tier bounds and round to 1 decimal place
        clamped = max(tier_min, min(tier_max, raw))
        return float(round(clamped, 1))

    @staticmethod
    def needs_rebalance(prev_rank: float, next_rank: float) -> bool:
        """Return True if the gap is too small for another safe insertion."""
        gap = Decimal(str(next_rank)) - Decimal(str(prev_rank))
        return gap < REBALANCE_THRESHOLD
